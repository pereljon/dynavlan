# Design: remove a carrier-down trunk's VLANs

Date: 2026-07-30
Status: approved (brainstorm), pending implementation plan

## Problem

On the test box, two NICs were plugged into trunks carrying overlapping VLANs (a
"duplicate link"). Under the all-trunks design each trunk is provisioned
independently (`enp1s0.100` and `enp2s0.100` are distinct netdevs). One link was
unplugged during operation; its subinterfaces lost carrier but stayed:

1. in the owned netplan file (nothing rewrote it), and
2. as kernel links (networkd does not tear down a virtual device when its parent
   loses carrier).

Nothing removed them, because the current invariant treats carrier-down as a
reason to **preserve**, not remove. In the duplicate case those interfaces are
pure cruft: the same VLANs remain live on the still-plugged link.

## Why the current invariant over-applies

The preservation invariant (`dev/SKELETON.md`, Key Invariants) exists to protect
against **detection** uncertainty: a VLAN silent during the sniff window produces
a false "not detected." It applies that same caution to **carrier** loss, which
carries no such ambiguity. Carrier state is an authoritative kernel signal
(`/sys/class/net/<iface>/carrier`); a port with no link cannot pass frames, so
its VLANs cannot function. Carrier-down is categorically more reliable evidence
than a sniff miss, and is safe to act on where a sniff miss is not.

## Decisions (all confirmed with the operator, 2026-07-30)

1. **Fire point: boot + timer.** Reboot cleans up an unplugged trunk, and the
   periodic rescan removes a trunk that goes carrier-down during operation. This
   gives the (currently add-only) rescan a removal path.
2. **Trigger scope: carrier-down only.** Remove only when the physical link is
   down. A trunk with carrier but zero detected tags stays preserved (that is the
   detection-miss risk the preservation design protects, or a genuinely
   reconfigured trunk dynavlan cannot distinguish from a silent one).
3. **Debounce: minimal in-run two-pass.** The link must be carrier-down across two
   samples within a single run (a settle window apart). Reuses the two-pass
   pattern boot removal already uses. No new persistent state.
4. **Config: `REMOVE_ON_CARRIER_LOSS`, default true.** Master switch for the whole
   behavior in both modes; `false` restores today's preserve-always behavior.
   Independent of `RESET_ON_BOOT`.

Deferred alternative (recorded, not built): a **grace timer** debounce that tracks
first-seen carrier-down time per trunk in `/run` and removes only after the link
has been continuously down for a configurable grace (~2 rescan cycles). It avoids
remove-then-re-add churn when a switch reboots or a cable is re-patched
(tens of seconds to a few minutes of outage), at the cost of one ephemeral `/run`
tracker, a grace config knob, and ~10 min slower cleanup of a genuine unplug. The
minimal choice accepts a self-healing monitoring-agent restart in those transient
cases; revisit if switch-maintenance churn proves real in the field.

## The rule

When an **owned** trunk's link is carrier-down across both debounce samples, and
the box **still has routing**, remove **all** owned VLANs on that trunk. The port
is dead, so everything on it is dead; this is a full removal of the trunk's owned
set, not a detection diff.

## Components

### Pure helper: `carrier_removals OWNED_ON_TRUNK C1 C2`

Returns the full owned set when both carrier samples are `down`, else empty.
Isolates the debounce decision as a side-effect-free, unit-testable function
(mirrors `boot_removals`). TDD: write section asserts RED first, then implement.

```
carrier_removals() {  # OWNED_ON_TRUNK C1 C2 -> owned set if both down, else ""
  [ "$2" = down ] && [ "$3" = down ] && emit_set $1
}
```

### Routing gate: `have_routing()`

True iff `snapshot_default_route` is non-empty **and** that iface has carrier.
Faithful implementation of "and we still have routing." If false (no default
route, or the only default egresses a dead iface), **preserve**: never remove.
Also protects the case where the lost link was the uplink with no redundant path.
`snapshot_default_route()` already returns the lowest-metric default's dev (`""`
if none); `has_carrier()` already exists.

The `apply_change` health check remains the post-condition backstop (a removal
that somehow broke routing would revert). `have_routing()` is a pre-condition that
avoids *attempting* a doomed removal (and its netplan-try churn + agent restart)
when routing is already broken.

## Integration

### `do_boot` (currently ~1268-1292)

Record per-trunk carrier at pass 1 (new; store alongside the existing `_p1_<trunk>`
detection stash). Keep the existing pass-2 carrier check. Replace the current
`else` branch (no carrier at pass 2 -> "skipping removals (preserving)"):

- pass-2 carrier **up**: existing `boot_removals` detection diff (unchanged).
- pass-2 **down** + pass-1 **down** + `have_routing` + `REMOVE_ON_CARRIER_LOSS`:
  `carrier_removals` = remove all owned on trunk.
- pass-2 **down** + pass-1 **up** (flapped): preserve.
- `have_routing` false, or knob off: preserve (log the reason).

**Independent of `RESET_ON_BOOT`.** `RESET_ON_BOOT` governs *detection*-based
removal only (the sniff diff). Carrier-down removal is governed solely by
`REMOVE_ON_CARRIER_LOSS`, so a `RESET_ON_BOOT=false` box still prunes a dead trunk
at boot. Consequence: when `RESET_ON_BOOT=false` there is no existing pass-2 settle
to supply the second carrier sample, so the carrier-down path must run its own
minimal settle + carrier re-sample when the knob is on and any owned trunk is down
at pass 1. When `RESET_ON_BOOT=true` the existing pass-2 settle already provides
the second sample; reuse it.

### `do_rescan` (currently strictly add-only, loops `DETECTED_TRUNKS`)

- Loop the **union** of owned and detected trunks (as `do_boot` does), not just
  `DETECTED_TRUNKS`.
- Detected (carrier-up) trunks: compute additions, exactly as today.
- Owned trunks with **no carrier** (and `REMOVE_ON_CARRIER_LOSS`): two-pass carrier
  check (sample, `sleep BOOT_SETTLE_SECONDS`, re-sample); if down in both and
  `have_routing`, mark all owned-on-trunk for removal.
- **Fast path preserved:** incur the settle sleep only when at least one owned
  trunk is actually carrier-down. Steady state (all trunks up) is unchanged, no
  new latency, still effectively add-only.
- Feed removals + additions through one unified `apply_change` (removals-only and
  mixed changes already pass the count gate and are handled by the accept
  primitive).

`BOOT_SETTLE_SECONDS` is reused as the rescan debounce interval; its meaning
("interval between the two samples") matches, so no new knob.

### `do_dryrun`

Preview would-be carrier-down removals alongside the existing per-trunk breakdown.
Critical for the attended first run: the operator must see a proposed teardown
before `--boot`.

### `do_status`

Flag owned trunks that are currently carrier-down.

## Safety properties (unchanged guarantees)

- **Never strand the box.** Removal runs through the full `apply_change` chain:
  snapshot -> backup -> generate -> validate -> `netplan try` + health gate ->
  ACCEPT-only deletes. A removal that broke routing reverts; deletes happen only
  after ACCEPT.
- **Routing-gated twice.** `have_routing()` pre-condition + health-check
  post-condition.
- **Authoritative signal.** Carrier from the kernel, not a passive sniff.
- **Debounced.** Two samples a settle apart; a short flap is preserved.
- **Reversible by config.** `REMOVE_ON_CARRIER_LOSS=false` restores prior behavior.
- **Self-healing.** A spurious removal (transient outage longer than the settle)
  is re-added on the next cycle; the cost is a monitoring blip, never a stranding.

## Edge cases

- **Lost link is the uplink, no redundancy:** `have_routing()` false -> preserve.
  (Removal would also fail the health check and revert.)
- **Lost link is the uplink, redundant default exists:** `have_routing()` true ->
  the dead uplink's VLANs are removed safely.
- **Routed mode (`VLAN_ROUTES=true`):** a removed VLAN's route is already dead
  (carrier down), so removal withdraws nothing live.
- **Flap during the settle:** down-then-up across the two samples -> preserve.
- **Whole box has no default route:** `have_routing()` false -> preserve
  everything (fail toward no change).

## Change checklist (files to touch)

- `dynavlan`: `carrier_removals`, `have_routing`, `do_boot`/`do_rescan`/`do_dryrun`/
  `do_status` edits, new config key + validation, `ver=` **minor** bump.
- `dynavlan.conf`: `REMOVE_ON_CARRIER_LOSS` commented at its default.
- `docs/dynavlan-PRD.md`: new FR (carrier-down removal, boot + timer, routing-gated,
  two-pass debounced) + AC; note the narrowed preservation scope.
- `dev/features/dynavlan.md`: reconcile-policy and apply-path updates.
- `dev/SKELETON.md`: narrow the "carrier-down preserves" invariant to
  "carrier-down removes (gated); carrier-up-no-tags preserves"; update the
  reconcile-policy prose for boot and rescan.
- `dev/CODEMAP.md`: rows for `carrier_removals`, `have_routing`; updated
  `do_boot`/`do_rescan`/`do_dryrun`/`do_status` one-liners.
- `tests/unit.sh`: new section for `carrier_removals` (RED first).
- `README.md`: behavior note + new config key.
- `CHANGELOG.md`: new behavior + config key.
- `context/`: decision (this change + the deferred grace-timer alternative),
  todo, resolve/annotate the relevant open question.

## Testing

- **Layer 1 (unit):** `carrier_removals` truth table (both down / one up / both up
  / empty owned). Config accept/reject for `REMOVE_ON_CARRIER_LOSS`.
- **Layer 2 (--dry-run):** carrier-down trunk shows a proposed full-removal;
  `have_routing`-false shows preserve; knob off shows preserve.
- **Layer 3 (hardware, console-backed):** the reproducing case (unplug the
  duplicate link, confirm removal on the timer within two cycles + settle, and at
  boot); flap shorter than the settle preserves; uplink-loss preserves; re-plug
  re-adds. Never exercised only over SSH (a bad apply drops the link).

Cannot claim this works until it has run on the box.
