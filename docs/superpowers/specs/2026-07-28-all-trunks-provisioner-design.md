# dynavlan: all-trunks provisioner - design (rev 2)

Status: DRAFT for review (2026-07-28, rev 2 after architect review). Supersedes the single-trunk selection model.
Owner: operator. Companion to `dev/features/dynavlan.md` (to be updated on implementation).

Rev 2 folds in the architect review of rev 1: the `iface.id` universal-token requirement (was an
under-stated open question), the corrected non-empty-detection removal rule, the two-pass carrier
authority rule, per-interface managed-elsewhere, stanza-header parsing, and two operator decisions
(stale interfaces on a vacated trunk; multi-uplink health-check posture). See section 12 for the
finding-by-finding disposition.

## 1. Purpose

dynavlan today discovers **one** trunk (most tagged VLANs, hysteresis, lexicographic tiebreak) and provisions VLANs only on it - an artifact of its monitoring-appliance origin. The project is repositioned as a **general dynamic-VLAN provisioner**: given a box on one or more trunk ports, bring up every discovered VLAN on every trunk. This removes the single-trunk limit and, as a direct consequence, removes the "which interface wins" heuristic - there is no contest when every trunk is provisioned.

Isolation stays the default (address-only, route/DNS/NTP/RA declined); routed mode stays opt-in and first-class. This changes how many interfaces those modes apply to, not the defaults.

## 2. Locked decisions

1. **All trunks.** Configure detected VLANs on every trunk-carrying interface, processed in sorted interface-name order (deterministic; order does not affect the result).
2. **A "trunk" is** any carrier-up physical NIC with >= 1 detected tagged VLAN. An untagged-only NIC (0 tags) is not a trunk and gets nothing - it is the box's plain uplink, left alone (uplinks live in the base netplan config, which dynavlan never touches).
3. **Overlapping VLAN IDs across trunks -> configure on both.** VLAN 100 on `enp1s0` and on `enp3s0` become two independent interfaces (`enp1s0.100`, `enp3s0.100`), each with its own lease. No dedupe.
4. **Trunk goes dark -> preserve.** Removal fires for an owned VLAN only when its trunk has carrier AND detects a **non-empty** tag set in **both** boot passes AND the id is absent from both. A trunk with no carrier, or one that detects zero tags (carrier up but gone quiet), **preserves everything** - an empty detection is the least-trustworthy signal (this is the per-trunk lift of the existing zero-detection guard).
5. **Scope: isolated + discovery-mode routed together.** `id` metric mode is dropped entirely (`VLAN_ROUTE_METRIC_MODE` removed). Discovery becomes the sole metric behavior.
6. **Routed metrics: discovery-order, keyed by full interface name** (`enp1s0.100`), never renumbered.
7. **Unified single apply.** All trunks' VLANs live in the one owned netplan file, applied in ONE `netplan try` with ONE health check and ONE revert - the existing atomic-apply model, box-wide.
8. **Stale interfaces on a vacated trunk: accept + document** (operator decision). When a cable moves off a trunk, that port goes carrier-down and its VLANs are PRESERVED (decision 4); the dead sub-interfaces linger (no lease, no route - harmless) until the port regains carrier with tags that exclude them, or indefinitely. No cleanup path, no remove-on-carrier-loss heuristic.
9. **Health-check posture for multi-uplink: document + accept** (operator decision). The check still watches the single lowest-metric default route, and this is correct for the never-strand guarantee: losing a *secondary* uplink does not strand the box, so watching only the lowest-metric (primary) uplink is sufficient. **Multi-uplink is the NORMAL case for a multi-trunk box, not a rare edge** - each trunk's native VLAN is an untagged uplink that leases its own default route (hardware-observed 2026-07-28: two trunks -> `enp1s0` default metric 10 + `enp2s0` default metric 20). dynavlan never creates a competing lower default (isolated installs none; routed guards every VLAN metric above the uplink), and adding isolated VLAN children does not disturb a parent's default (hardware-validated). The only genuinely untested edge is **co-equal-metric** uplinks (two defaults at the same metric, where iteration-order could flip which is "lowest"); distinct metrics (the normal DHCP case) have no such issue. No health-check change.

## 3. THE CANONICAL KEY (load-bearing - read first)

**`iface.id` (the full interface name, e.g. `enp1s0.100`) is the universal token for every VLAN set in the pipeline.** Not the bare VLAN id. This is mandatory, not stylistic: decision 3 lets the same id exist on two trunks, so a bare id aliases across parents and the owned set cannot represent the box.

Every set that today holds bare ids becomes a set of `iface.id` tokens:
- `owned`, `additions`, `removals`, `target`
- the count-gate input
- the routed metric map (`iface.id:metric`)
- the lease-wait set
- the apply-evidence probe

`compute_candidates` and `boot_removals` stay pure, but operate **per interface** and their outputs are re-tagged with the iface before entering any box-wide set operation. `set_minus`/`set_union`/`count_ids` operate on `iface.id` tokens unchanged (they are string-set ops). The VLAN id is recovered from a token by suffix (`${tok##*.}`) and the iface by prefix (`${tok%.*}`) only where a bare id or bare iface is genuinely needed (e.g. the `id:` field in a stanza, or `backend_remove_vlan`'s two args).

If any set in the pipeline holds bare ids, cross-parent aliasing returns. This is the single thing most likely to be gotten wrong in implementation.

## 4. Detection contract (rewritten)

`run_detection` currently sets singular `TRUNK_IFACE`/`DETECTED_VLANS` and returns 1 on "no trunk". It is rewritten to yield a **per-trunk map**: for every carrier-up interface with >= 1 detected tag, `{ iface -> detected VLAN-id set }`. Its internals (prep-all, one shared carrier deadline, concurrent per-iface sniff+LLDP, `iface_tags`) are reused as-is; only the selection step is removed.

- `select_trunk`, the hysteresis logic, and `TRUNK_IFACE` as a single global are **removed**.
- Return / empty contract: the map is empty when no interface has carrier-with-tags. The box-wide zero-detection abort reads "map empty" as "detected nothing anywhere -> change nothing".
- All callers (`do_boot`, `do_rescan`, `do_dryrun`, `do_status`) are converted from the singular globals to the per-trunk map.

**Two-pass carrier authority (boot):** `run_detection` runs twice (pass 1, settle, pass 2). For each interface:
- **Removals** require carrier-up **and** non-empty detection in **both** passes on that iface; the removed set is `owned_iface` ids absent from both passes (per `boot_removals`, which already returns nothing when both passes are empty).
- A mid-window carrier flap (up in one pass, down in the other) yields **no removal evidence** for that iface -> preserve.
- **Additions** for an iface ride its **pass-1** carrier+detection. An iface that darkens after pass 1 still gets its additions applied (they create dead netdevs that never lease until the next reconcile) - benign, noted in edge cases.

## 5. Reconcile and generation

- **State model: multi-parent.** `owned_parent` (single) -> `owned_parents` (set). `backend_owned_vlans` returns `iface.id` tokens. `backend_owned_metrics` is keyed by `iface.id`. Both are rebuilt off the **stanza header line** (`    <iface>.<id>:`, anchored on leading-space + `\.` + `:` to avoid catching `dhcp4-overrides:` etc.) rather than correlating `id:` with `link:` by position - the header unambiguously carries both fields and drops the `head -1` single-parent assumption.
- **Managed-elsewhere is per interface.** `backend_list_managed_vlans` (box-wide id set today) is evaluated per parent: an id managed elsewhere excludes it only on the interface(s) where the collision occurs, not globally.
- **Generation, multi-parent.** `backend_generate_config` takes `{ iface -> id set }` (or a flat `iface.id` list) and emits one stanza per `(iface, id)` with `link: <iface>`. Isolated and routed stanzas otherwise unchanged (incl. `accept-ra: false`). The routed metric lookup matches on `iface.id`, not bare id.
- **Metric assignment.** `plan_route_metrics` keyed by `iface.id`; discovery-order across the union of all trunks' VLANs; existing interfaces keep their metric verbatim; new ones append ascending. The `mode` parameter and the `id`-mode branch of `assign_route_metrics` are removed. `metric_conflict` checks every assigned metric against the uplink, unchanged in spirit.
- **Boot reconcile.** Iterate trunks (owned-or-detected). Per section 4, compute per-iface additions/removals, re-tag to `iface.id`, aggregate into one target. **Relocation branch removed** (see section 6). Count gate box-wide on `|target|`. Then one `apply_change`.
- **Rescan.** Add-only across all trunks (union of per-trunk candidates), pinned to owned interfaces, never removes/relocates.
- **Apply.** `apply_change` unchanged in structure; target/additions/removals are `iface.id` tokens. Probe = first added `iface.id`. Deletes use each token's own parent (`backend_remove_vlan "${tok%.*}" "${tok##*.}"`) - **not** a single global `OLD_TRUNK`. Delete order is irrelevant (independent interfaces); delete-after-ACCEPT holds.

## 6. Relocation removal (H1) and its honest consequence

The AC-3 relocation branch is **removed**. Its original job - move VLANs off a stranded pin when the trunk physically moved - is obsolete: there is no single pin in an all-trunks model. A cable moving `enp1s0 -> enp3s0` is now: additions appear on `enp3s0`; `enp1s0` goes carrier-down and its VLANs are **preserved** (decision 4/8).

This is **safer** (no strand) but **not equivalent** to AC-3, which explicitly removed the old set in one reconcile. Consequences, accepted and documented (decision 8):
- **AC-3 is rewritten**, not kept. FR-4 (single-trunk selection) is **removed**. FR-35 (`--status` "selected trunk") reports **all** trunks.
- Dead sub-interfaces linger on the vacated carrierless port until it regains carrier with excluding tags, or indefinitely. Harmless (no lease/route) but visible to an interface-enumerating agent.
- The one case that still removes: the old port keeps carrier but loses the tags (re-patched to a live access port) -> carrier-up + id absent from both passes -> removed. Behavior bifurcates on old-port carrier; documented.

## 7. Health check (H2) - unchanged, with a stated assumption

No change to `health_check_eval` / `snapshot_default_route`. It watches the single lowest-metric default route; that is sufficient for never-strand, because losing a *secondary* uplink does not strand the box - only the lowest-metric (primary) uplink must survive.

**Multi-uplink is normal here, not a rare edge.** A multi-trunk box where trunks have native VLANs gets one untagged uplink (and one DHCP default route) per trunk. Hardware-observed 2026-07-28 with two active trunks:

```
default via 192.168.101.1 dev enp1s0 metric 10   # enp1s0 native = VLAN 101
default via 192.168.100.1 dev enp2s0 metric 20   # enp2s0 native = VLAN 100
```

The check watches the lowest (enp1s0, metric 10). This stays correct because: uplinks are base-config (dynavlan never defines them); dynavlan never creates a competing lower default (isolated installs none; routed's metric-conflict guard keeps every VLAN metric above the uplink); and adding isolated VLAN children does not disturb a parent's default (hardware-validated). Distinct DHCP metrics (10 vs 20 here) mean no tie-break ambiguity.

**Stated assumption (documented limitation):** the only untested edge is **co-equal-metric** uplinks - two defaults at the *same* metric, where `ip route show` iteration order could flip which is "lowest" and trip a spurious (safe) revert. Not observed on real hardware (DHCP hands out distinct metrics); not engineered for now.

## 8. Data flow (boot)

```
run_detection (pass 1) -> { enp1s0: {10,20,100}, enp3s0: {100,200} }   # carrier-up ifaces with tags
settle
run_detection (pass 2) -> same shape
for each trunk iface (owned or detected):
  if carrier-up + non-empty in BOTH passes:
     additions_iface = compute_candidates(detected1_iface, MIN, MAX, IGNORE, managed_iface, owned_iface)
     removals_iface  = owned_iface ids ABSENT FROM BOTH pass1_iface AND pass2_iface   # boot_removals
  else (no carrier / empty / flapped):
     additions_iface = compute_candidates(pass1_iface, ...) if pass-1 carrier+tags else {}
     removals_iface  = {}                                                              # preserve
  re-tag additions_iface, removals_iface, owned_iface to iface.id tokens
target = union over trunks of (owned_iface - removals_iface) + additions_iface   # iface.id tokens
count gate on |target| (box-wide)
[routed] plan_route_metrics over target (keyed iface.id) + conflict guard vs uplink
apply_change(target, additions, removals)   # ONE netplan try, ONE health check
  ACCEPT: prune -> delete removed iface.id links (each with its own parent) -> wait leases (added) -> restart
  FAIL:   converge disk to prior, no deletes, no restarts
```

## 9. Error handling / edge cases

- **No trunks anywhere** (map empty): abort, change nothing.
- **A trunk loses carrier**: its VLANs preserved; no churn; dead netdevs linger (decision 8).
- **Same VLAN ID on two trunks**: two interfaces, two leases, two metrics (routed). No collision.
- **Native/PVID VLAN per trunk**: excluded per-trunk by existing FR-7a `lldp_tagged_vlans` (detection already per-iface).
- **Managed-elsewhere**: per-interface exclusion by id (section 5).
- **`warn_overlap` / FR-11**: made parent-aware, else it false-warns on legitimate multi-parent same-id (it counts merged-netplan id occurrences >= 2).
- **Count gate**: box-wide total. Fill-mode ordering becomes lowest-`(iface,id)` with a defined sort; the fleet-uniformity rationale weakens (different trunk wiring -> different subsets) and is dropped from the fill claim. In `refuse` mode one over-limit trunk aborts the whole apply (owned preserved, nothing stranded) - an operator-visible surprise, documented.
- **Additions on a since-darkened trunk**: created but never lease until next reconcile; benign.
- **Health FAIL on the unified apply**: whole-box revert; disk converges to prior; no deletes, no restarts.

## 10. Testing

- **Unit:** `compute_candidates` per-interface; `boot_removals` per-trunk (carrier-up-non-empty vs carrier-down vs zero-tags-preserve vs flap); `plan_route_metrics` keyed by `iface.id` across a multi-trunk union incl. overlapping ids getting distinct metrics; removal of `id`-mode cases; multi-parent owned-set parse off the stanza header; `iface.id` token round-trip (prefix/suffix extraction).
- **Dry-run:** two-trunk fixture; per-trunk additions/removals; multi-parent target; routed `iface.id:metric` map; `--status` reporting all trunks.
- **Hardware (box has enp1s0 + enp2s0):** plug a second trunk into enp2s0; VLANs up on both; overlapping-id case; pull one trunk cable -> other trunk untouched, pulled trunk's VLANs preserved (dead netdevs linger, not removed); routed multi-trunk metrics; unified revert still works. **Migration fixture:** an existing single-parent owned file (from the current single-trunk build) upgraded in place - confirm it reads back correctly (single-parent is the degenerate multi-parent case), including routed-mode metric read-back keyed by the new `iface.id`.

  **Concrete L3 fixture (validated live 2026-07-28, both trunks active):**
  ```
  enp1s0 tagged: 1 18 20 21 22 100 200   native/untagged: 101 (192.168.101.x uplink, default metric 10)
  enp2s0 tagged: 1 18 20 21 22 101 200   native/untagged: 100 (192.168.100.x uplink, default metric 20)
  ```
  Expected all-trunks result: both trunks get `{1,18,20,21,22,200}`, plus `enp1s0.100` and `enp2s0.101`. VLAN 100 is configured on enp1s0 (tagged) but NOT enp2s0 (native there); 101 is the reverse. 14 interfaces total. This is the overlapping-id + per-trunk-native case in one fixture.

  **Pre-implementation validations already done (2026-07-28, before any code):**
  - netplan 0.107 `generate --root-dir` ACCEPTS multi-parent + overlapping VLAN id: `enp1s0.100` and `enp2s0.100` emit distinct netdevs (`Name=<iface>.100 Id=100`). The core feasibility assumption holds.
  - Per-trunk detection reads each trunk's distinct tagged set on the wire (concurrent inbound sniff).
  - Per-trunk native handled for free: each trunk's native VLAN is untagged, so the sniff never sees it and the design never configures it on that trunk - no LLDP needed (LLDP is empty on the UniFi). Validated by the cross case: 100 tagged-on-enp1s0 / native-on-enp2s0.

## 11. Version / compatibility

Changes core behavior (single -> multi trunk) and removes a config key. 0.1.0 is unreleased. Recommend **0.2.0** for a clean behavioral boundary. Existing single-trunk owned files remain readable (single-parent = degenerate multi-parent), so boxes upgrade without a wipe.

## 12. Architect-review disposition (rev 1 -> rev 2)

- **B1 (iface.id must be universal, not optional):** ACCEPTED -> section 3 (canonical key), threaded through 4/5/8/10.
- **B2 (which pass's carrier set is authoritative):** ACCEPTED -> section 4 (two-pass carrier authority + flap semantics).
- **B3 (zero-detection contradicts decision-4 wording):** ACCEPTED -> decision 4 corrected (non-empty detection required; zero-tags preserves).
- **H1 (relocation removal not equivalent; stale interfaces):** ACCEPTED as accept+document -> decision 8, section 6.
- **H2 (multi-uplink health-check weakness):** ACCEPTED as document+accept, reframed -> decision 9, section 7. NO health-check change: dynavlan never creates a competing lower default, and watching the lowest (primary) uplink is sufficient for never-strand. CORRECTED 2026-07-28 with live two-trunk data: multi-uplink is the NORMAL case (two natives -> two defaults, metrics 10/20), not a rare edge; the actual untested edge is narrower - co-equal-metric uplinks only.
- **M1 (parse stanza header):** ACCEPTED -> section 5.
- **M2 (fill determinism, one-trunk-blocks-all):** ACCEPTED -> section 9.
- **M3 (additions on since-darkened trunk):** ACCEPTED -> sections 4, 9.
- **Missed items** (run_detection contract, per-iface managed-elsewhere, warn_overlap/FR-11, FR-4/AC-3/FR-35 revisions, migration test): ACCEPTED -> sections 4, 5, 6, 10.

## 13. Out of scope (deferred)

- Interface allow/deny list (provision only named trunks; exclude a tag-carrying mgmt NIC). YAGNI; likely future config.
- Per-VLAN gateway reachability testing.
- Any replacement for `id`-mode fleet-uniform metrics.
- Extending the health check to multiple co-equal uplinks (H2) - revisit only if a real multi-uplink deployment appears.
- A cleanup path for stale interfaces on a long-vacated trunk (H1) - revisit only if the lingering netdevs prove a real problem.
