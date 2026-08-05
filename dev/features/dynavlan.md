# dynavlan - Technical Design Doc

Bridges `docs/dynavlan-PRD.md` (v3.1, what/why) to implementation (how). The PRD's FR/NFR/AC IDs are the source of truth for behavior; this doc defines structure, sequencing, and the seams. Companion test plan: `dev/features/dynavlan-tests.md` (to be written before code).

## 1. Implementation decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Language | **bash** | Zero runtime dependency, portable across distros at the shell level (no interpreter-version coupling), natural fit for orchestrating `netplan`/`ip`/`tcpdump`/`lldpctl`. Concurrency footguns (flock/fifo) are contained in a few functions (§7, §9). |
| Timer interval | **static systemd timer + config-synced drop-in** | systemd timers are static files. `RESCAN_MINUTES` is materialized into `/etc/systemd/system/dynavlan.timer.d/interval.conf` by `dynavlan --reconfigure` (also run at install), followed by `systemctl daemon-reload`. Runtime edits to `RESCAN_MINUTES` require re-running `--reconfigure`. Avoids a self-rescheduling loop or a long-running daemon (PRD chose oneshot+timer). |
| Two-pass boot removal state | **in-process, within the single `--boot` run** | FR-23: detect, sleep `BOOT_SETTLE_SECONDS`, detect again, remove only VLANs absent from both. Held in shell variables; no persistence, no cross-invocation state (rescan stays strictly add-only per FR-21). |
| Network backend | **abstracted seam, netplan the only implementation** | See §4. Structure for portability without building multiple backends (that would be speculative). |
| Config format | **declaratively-parsed `/etc/dynavlan.conf`** | Commented KEY=value, parsed line-by-line against an allowlist of the documented keys - NEVER `source`d (H2, 2026-08-04). A config line can only set a documented key; an unknown/protected key or non-assignment line refuses to run, and values are inert literals (`printf -v`), so config can neither execute code nor override an internal/safety variable. Matches the PRD schema (§8 there). |

## 2. Architecture: two layers

```
+-------------------------------------------------------------+
|  CORE (distro-agnostic)                                     |
|  config parse/validate · interface discovery · sniff/lldp  |
|  detection · filter/exclude/candidates · reconcile logic · |
|  health-check evaluation · logging · flock · entrypoints   |
+-------------------------------------------------------------+
                         | calls (never touches netplan directly)
                         v
+-------------------------------------------------------------+
|  BACKEND SEAM (six operations) - netplan implementation     |
|  list_managed_vlans · generate_config · validate ·          |
|  apply_with_revert · remove_vlan · owned_vlans              |
+-------------------------------------------------------------+
```

The core contains all the intelligence and is portable. The backend seam is the only netplan-coupled code. A future port (NetworkManager, systemd-networkd-direct, ifupdown) implements the six operations; the core is untouched.

## 3. Ownership model (stated abstractly)

dynavlan owns a **namespace** of VLAN definitions and never modifies definitions outside it. Netplan instantiates this as "own `/etc/netplan/90-dynavlan.yaml`, exclude every other file" (FR-13). Future backends: NM = "own `dynavlan-*` connections"; networkd-direct = "own `90-dynavlan.*` unit files". The exclusion logic (FR-10) is "every VLAN managed outside our namespace," queried via the backend.

## 4. Backend seam - the six operations

Each is a bash function `backend_<op>`; the netplan implementation is the initial (only) one. Contract is capability-level, not netplan-specific.

| Operation | Contract | netplan impl | NM impl (future) | networkd-direct (future) |
|-----------|----------|--------------|------------------|--------------------------|
| `list_managed_vlans` | Bare VLAN IDs managed **outside** our namespace on ONE given trunk (exclusion source; per-trunk, since IDs are scoped to their trunk) | `netplan get network.vlans` ∪ `ip -d link show type vlan`, filtered to that iface, minus our own tokens on it | `nmcli -g … con show` VLANs ∪ `ip link` | parse other `*.netdev` ∪ `ip link` |
| `owned_vlans` | `iface.id` tokens currently in **our** namespace, across every trunk (known-set) | parse `90-dynavlan.yaml` stanza headers | our `dynavlan-*` connections | our `90-dynavlan.*.netdev` |
| `generate_config` | Write our namespace to define exactly the given VLAN set (atomic) | atomic write `90-dynavlan.yaml` (FR-16) | `nmcli con add/mod` | write `.netdev`/`.network` |
| `validate` | Dry validate the pending config; distinguish our-error vs base-error | `netplan generate` (FR-17) | `nmcli con … --check` | `networkctl` verify / `systemd-analyze` |
| `apply_with_revert` | Apply, run caller's health check, keep if pass else auto-revert | `netplan try` + fifo-drive (FR-18, §9) | **native** `nmcli` checkpoint + rollback timeout | hand-rolled snapshot/apply/timer/revert |
| `remove_vlan` | Remove a VLAN from our namespace AND tear down the live interface | file edit + `ip link delete` (FR-24) | `nmcli con delete` | rm units + `ip link delete` |

**Revert capability varies by backend** (the one genuinely hard portability item): netplan has `try`; NetworkManager has native checkpoints (cleaner); networkd-direct and ifupdown have none and must hand-roll. The core's `apply_with_revert` contract is "apply with a health-gated auto-revert," so the core is agnostic to which.

A startup `backend_detect` (reads `/etc/os-release`, probes for `netplan`) is described here as the seam's entry point but is NOT in the script today: the backend is hardcoded to netplan, since it is the only implementation. The stub lands only when a second backend does. No backend-selection config until then.

## 5. Module / function decomposition (feeds dev/CODEMAP.md when code lands)

| Function | Purpose (one line) |
|----------|--------------------|
| `main` | Parse mode flag (`--boot`/`--rescan`/`--dry-run`/`--status`/`--reconfigure`), acquire flock, dispatch |
| `load_config` | Apply defaults, then parse `/etc/dynavlan.conf` via `config_load_file` (allowlist-only, never sourced - H2), validate all values (refuse-to-run on bad) |
| `parse_vlan_ignore` | Expand `VLAN_IGNORE` comma/space list with `low-high` ranges into a set |
| `check_preconditions` | FR-0: root, netplan>=min + `netplan try` capability probe (non-mutating), deps for method |
| `discover_phys_ifaces` | Live physical NICs from `/sys/class/net` (device symlink, type==1, exclude lo/wifi/vlan) |
| `prep_iface` / `has_carrier` | Set iface up + promisc on (all NICs first); then ONE shared carrier deadline (`CARRIER_WAIT_SECONDS` total, not per port). Detection runs ONLY on carrier-up ifaces, and the per-iface sniffs run CONCURRENTLY (one `SNIFF_SECONDS` window total) so detection cost does not scale with port count |
| `vlan_guard` / `limit_fill` / `gate_vlan_count` | FR-12/FR-36 count gate: pure `vlan_guard(n,warn,limit)` → OK/WARN/OVER and `limit_fill(adds,slots)` → lowest-N subset (tests 1f); `gate_vlan_count` orchestrates warn / refuse / fill per `VLAN_LIMIT_MODE`, over the box-wide combined additions |
| `plan_route_metrics` / `map_ids` / `assign_route_metrics` / `map_filter` / `metric_conflict` | FR-37 routed mode (tests 1g): `plan_route_metrics` is the single assignment decision point every caller must use (owned map + target + additions -> full map; assigns for target tokens LACKING a metric, not additions); pure metric assignment (kept `iface.id` tokens verbatim + next-free ascending metric for new tokens, discovery order across the whole box - the only mode, `VLAN_ROUTE_METRIC_MODE`/`id` mode was dropped), map filtering to surviving tokens, and the uplink-metric conflict guard (CONFLICT if any assigned metric <= uplink metric) |
| `backend_owned_metrics` / `snapshot_default_metric` | FR-37 state: read the persisted "token:metric" map back from our own YAML; capture the pre-apply uplink default's metric for the conflict guard |
| `detect_sniff` | Passive 802.1Q capture (`tcpdump`, minimal snaplen, no disk) → VLAN IDs per iface |
| `detect_lldp` | `lldpctl` advertised VLANs per iface |
| `detect_iface` / `run_detection` | `detect_iface` unions the enabled methods for one iface; `run_detection` runs it concurrently over every carrier-up iface and sets `DETECTED_TRUNKS` to every iface with a non-empty tag set - all of them, not a single selected trunk. No trunk-selection contest, no hysteresis, no `select_trunk` |
| `drop_iface_tokens` | Token set minus every token on any listed iface (tests 1w). Discards additions on a trunk confirmed carrier-down: detection filters carrier once and then sniffs for `SNIFF_SECONDS`, so a trunk that dies mid-sniff keeps its tags and would otherwise have new VLANs created on it in the same apply that tears its old ones down |
| `emit_tokens` / `tok_iface` / `tok_id` / `tag_tokens` / `untag_tokens` / `tokens_for_iface` / `distinct_ifaces` | Pure `iface.id` token helpers (tests via the mode functions that use them): convert between the token domain (every set downstream of detection) and the per-trunk bare-id domain `compute_candidates`/`boot_removals` operate in; `distinct_ifaces` drives the per-trunk loop in every mode |
| `compute_candidates` | Per-trunk: `detected ∩ [MIN,MAX] − VLAN_IGNORE − backend_list_managed_vlans(iface) − owned-ids-on-that-iface`; caller tags the result to `iface.id` |
| `carrier_removals` | Pure (FR-41, tests 1r): `OWNED_ON_TRUNK C1 C2 -> owned set if BOTH carrier samples are "down", else empty`. Full-teardown decision for a dead trunk, mirrors `boot_removals`' shape |
| `have_routing` | FR-41 pre-condition (tests 1s): true iff a lowest-metric default route exists, its egress iface has carrier, AND at least one physical NIC has carrier. False → callers preserve rather than attempt a doomed removal (composes `snapshot_default_route` + `has_carrier` + `discover_phys_ifaces`). The physical-NIC clause is load-bearing: tun/wireguard netdevs report `carrier=1` whenever merely configured up, so a tunnel default would otherwise make an all-dark box look routable. Testing the egress dev against a physical whitelist instead would wrongly reject a VLAN-egress default and would disable FR-41 outright on a genuinely VPN-routed box |
| `do_boot` | Loops every owned-or-detected trunk; per-trunk two-pass math (additions single-pass, detection-diff removals need absence in both passes on a carrier-UP trunk; `run_detection`'s rc is ignored - it means "saw nothing", not "failed" - so a zero detection blocks additions without blocking FR-41 pruning). Removal-set combination per trunk factored into a pure helper `boot_removals(owned,pass1,pass2)` for unit testing (tests 1d). A second settle+resample (`need_pass2`) also fires when FR-41 carrier-down removal is armed and an owned trunk was already down at pass 1 (independent of `RESET_ON_BOOT`); on sustained two-sample carrier loss with healthy routing (`have_routing`), `carrier_removals` prunes the whole owned set on that trunk. Combines every trunk's tagged additions/removals into one token set, then ONE unified `apply_change` for the whole box |
| `do_rescan` | Per-trunk additions over `DETECTED_TRUNKS` (was strictly add-only through v0.3.0). FR-41 (v0.4.0) adds removals: checks carrier on every OWNED iface, and on a fast path incurs the settle sleep only when an owned trunk is actually down, prunes via `carrier_removals` on a sustained loss with healthy routing. Combines into one token set, one unified apply |
| `apply_change` | Orchestrate the safety sequence (§7) over a token set spanning however many trunks: generate → validate → apply_with_revert → deletes → restarts. Optional 4th arg overrides the lease-wait set (FR-39 reapply waits on the full owned set, having no additions) |
| `do_reapply` / `config_body_differs` | FR-39: regenerate the owned token set with the running build and apply only if the body differs (line 1, the version/build header, excluded positionally). No detection - pinned to `distinct_ifaces` of the owned tokens, since detecting could silently change which trunks are in scope. Count gate bypassed; blocking lock |
| `snapshot_default_route` | Capture iface/gw/metric of lowest-metric default route (health-check reference) |
| `health_check` | PASS iff post-apply default route egresses snapshot iface (or empty→empty); ARP non-fatal |
| `wait_leases` | Bounded `LEASE_SETTLE_SECONDS` wait for new-VLAN leases; non-blocking on failure |
| `restart_targets` | Restart `RESTART_SNAPS` (snap) then `RESTART_SERVICES` (systemctl); skip missing/failed |
| `prune_backups` | Keep newest `BACKUP_KEEP` |
| `log` | Leveled journal logging (identifier `dynavlan`), start/end lines |
| `do_status` / `do_dryrun` / `do_reconfigure` | Operator entrypoints; both `do_status` and `do_dryrun` report per-owned-trunk carrier state (FR-41), and `do_dryrun` previews a would-be carrier-down removal |
| `backend_*` (×6) | The seam of §4 |

## 6. Control flow per mode

**`--boot`** (FR-22/23/41, all-trunks): preconditions → discover/prep every physical iface → detect pass 1 → **`run_detection`'s rc is deliberately ignored.** It has exactly one non-zero return, fired precisely when `DETECTED_TRUNKS` is empty, so it cannot tell a probe failure from a quiet wire; an rc-based abort would fire on the very case FR-41 exists for (every owned trunk unplugged, nothing left to detect) and would log "detection failed" for an ordinary quiet trunk. Boot branches on `DETECTED_TRUNKS` instead: a zero detection makes additions impossible, but a carrier-down owned trunk remains eligible for FR-41 pruning when `REMOVE_ON_CARRIER_LOSS=true` → loop over the UNION of every owned trunk and every newly-detected trunk; per trunk, additions = detected ∩ range − ignore − managed-elsewhere − owned-on-that-trunk, tagged to `iface.id`, AND stash each trunk's pass-1 carrier sample (`_c1_<trunk>`) → **`need_pass2`** = `RESET_ON_BOOT=true` (detection-diff needs it) OR (`REMOVE_ON_CARRIER_LOSS=true` AND some owned trunk already down at pass 1, supplying half the carrier debounce); if neither, boot stays single-pass → when `need_pass2`: sleep `BOOT_SETTLE_SECONDS` once, re-detect ONLY if `RESET_ON_BOOT=true` (a carrier-only resample reads `/sys` + the owned set, never detection, so a fresh sniff here would be pure latency) → per trunk at pass 2: **carrier UP** → detection-diff removal exactly as before, `RESET_ON_BOOT` only (`boot_removals`: owned ids on that trunk absent from BOTH passes; empty detection in either pass preserves). **Carrier DOWN** → FR-41: preserve if the knob is off, or if pass-1 carrier was up (a flap, not sustained), or if `have_routing` is false (no healthy default route - the dead trunk may double as the box's own uplink; this pre-condition is the ONLY gate on that case, since an already-missing uplink makes the pre-apply route snapshot empty and an empty snapshot is a deliberate unconditional health-check PASS); otherwise `carrier_removals` returns the trunk's full owned set → combine every trunk's tagged additions/removals into one token set → count gate (`gate_vlan_count`: FR-12 warn / FR-36 refuse-or-fill, over the combined total; a removals-only change always passes) → if change: ONE unified `apply_change` for the whole box → done. **No relocation branch**: a trunk with no tags but carrier UP is preserved (genuine detection uncertainty); a trunk that goes carrier-DOWN is pruned by FR-41 once routing is confirmed healthy, not preserved - there is still nothing to relocate to, since every other tagged trunk is already independently provisioned on its own merits.

**`--rescan`** (FR-21/41, all-trunks): preconditions → discover/prep → detect (single pass) → loop every `DETECTED_TRUNKS` iface, per-trunk additions only, tagged and combined. Was strictly add-only through v0.3.0; FR-41 (v0.4.0) adds removals: if `REMOVE_ON_CARRIER_LOSS=true`, check carrier on every OWNED iface (not just `DETECTED_TRUNKS` - a carrier-down owned trunk reports zero tags and is absent from it entirely). **Fast path preserved**: the settle sleep runs only when at least one owned trunk is actually carrier-down AND `have_routing` is true; an all-up steady state (or a down trunk with no healthy routing, which just logs a preserve warning) costs nothing extra. When triggered: sleep `BOOT_SETTLE_SECONDS` once for every down trunk together, then re-evaluate `have_routing` (the pre-settle check gates whether to sleep at all; this one gates whether to remove, and without it an uplink dropped during the settle - a switch reboot taking both ports - yields a removal applied and ACCEPTED on a box with no routing, since the empty pre-apply snapshot makes the health check an unconditional PASS), re-sample carrier on those trunks, prune (`carrier_removals`) any still down - one recovered during the settle is preserved. Additions and removals combine into one token set → count gate → one unified `apply_change`.

**`--dry-run`** (FR-34/41, all-trunks): detect + per-trunk candidate math over the union of owned and detected trunks (single pass, boot-mode math), plus a would-be FR-41 removal per trunk (single advisory carrier sample, no debounce since nothing applies; gated on `have_routing` computed once) + `backend_validate` against a throwaway tree → print the combined intended add/remove plus a per-trunk breakdown (now including carrier state) and, when routing is unhealthy, a note that a carrier-down teardown is being suppressed; **never apply, never restart**. The throwaway tree is a copy of the real `/etc/netplan/` (base files included) with the candidate `90-dynavlan.yaml` overlaid, so `netplan generate` sees base files too and dry-run surfaces an FR-17 base-file-freeze (R-5) rather than hiding it. Lock interaction (round-4): dry-run TRIES the FR-30 flock non-blocking - if free it holds it for the preview (a timer rescan landing mid-preview skips normally and retries next cycle); if already held it does NOT block the operator, warns the preview may reflect mid-change state, and proceeds read-only.

**`--status`** (FR-35/41, all-trunks): print owned vs detected-now vs excluded/ignored for every owned trunk plus every currently-detected trunk, last-run result; also prints carrier up/down per owned trunk.

**`--reconfigure`**: render `dynavlan.timer` drop-in from `RESCAN_MINUTES`, `daemon-reload`.

## 7. Apply/rollback state machine (the safety-critical chain)

Runs under the flock (§ FR-30). Pseudocode with every failure branch:

```
apply_change(target_set):
  snap = snapshot_default_route()                 # may be empty
  backend_generate_config(target_set)             # atomic temp+fsync+rename (FR-16)
  if not backend_validate():                      # FR-17
     log err (distinguish our-YAML vs base-file); restore prior file; return NO_CHANGE
  backup_current(); prune_backups()

  accepted = backend_apply_with_revert(health_check_fn = -> health_check(snap))   # FR-18
     # netplan impl: netplan try --timeout N + fifo drive (§9);
     # health_check runs inside the try window; N > max_check + margin; wall-clock guard

  if not accepted:                                # REVERT path (FR-27, H-3)
     log err apply-rollback
     return NO_CHANGE                             # NO deletes, NO lease-settle, NO restarts

  # ACCEPTED path only:
  for vlan in removals: backend_remove_vlan(vlan) # FR-24: ip link delete ONLY here, after accept
  wait_leases(additions)                          # bounded, non-fatal (FR-27)
  restart_targets()                               # snaps then services (FR-27/28)
  log notice (summary)
```

Every failure path lands on "no net change, uplink intact, logged." A death anywhere releases the flock (kernel, fd-held) and `netplan try` reverts (timer). See §9 for the accept/revert primitive.

FR-41 (carrier-down removal, §11b) adds one PRE-condition in front of this chain, never inside it: `have_routing()` gates whether a carrier-down trunk's VLANs are even proposed for removal (`all_removals`) before `apply_change` is called at all. The chain itself is unchanged. Do NOT, however, read the health-check POST-condition as a backstop for this particular pre-condition: it reverts a removal that BREAKS routing, but the case `have_routing` guards is one where routing is ALREADY broken before the apply. There the pre-apply snapshot is empty, and an empty snapshot is a deliberate unconditional PASS (AC-12, "never revert on an independently-missing uplink"), so the health check passes such a removal straight through. The two layers cover adjacent cases, not the same case twice; `have_routing` is load-bearing on its own, which is why it is evaluated immediately before the removal set is built rather than once at the top of the mode.

`restore_prior` (disk convergence on any failure/revert path) checks its copy-back and logs `err` on failure naming the surviving backup path (round-4): a failed restore means disk holds the reverted config while live state is the prior one - the next run's owned-set would be wrong - and being loud with the manual-recovery pointer is the only safe remedy at that point.

## 8. Health check (FR-18)

- `snapshot_default_route`: `ip route show default` → lowest-metric route's `dev`, `via`, `metric`. May be empty.
- Post-apply PASS iff: a default route exists AND the **lowest-metric** default route's `dev` equals the snapshot `dev`. Comparison is on `dev` (interface) only, never metric or gateway (a metric or gateway change on the same iface is a normal DHCP event and must not revert). If a spurious lower-metric default appears on a *different* iface post-apply, the lowest-metric default has moved off the base uplink → FAIL/revert. **Empty-snapshot rule (AC-12):** if the snapshot was empty, PASS iff post-apply is also empty or the only new default is one the change did not add (VLANs add none, per FR-14) — never revert solely because the box independently had no uplink.
- ARP reachability of the gateway is optional, secondary, **strictly non-fatal**: a silent gateway must not fail the check. Never ICMP.
- Dependency: valid only because FR-14 gives generated VLANs no default route, so snapshot/post-apply reflect the base uplink alone. A change to FR-14 isolation keys must revisit this.

## 9. `netplan try` accept/revert primitive (netplan `apply_with_revert`)

The concurrency-sensitive part (IR-2), hardened after the round-2 review found the fifo-ACCEPT race. TIMING MODEL: `netplan try --timeout N` APPLIES the config first and only then reads stdin; its revert timer starts after the apply. A newline written early sits in the pipe buffer and is consumed unconditionally post-apply - accepting a change the health check never saw applied. The primitive therefore runs a poll loop:

- Start `netplan try` with stdin from a fifo we hold open for writing (the write-open unblocks its read-open).
- Poll every `POLL_INTERVAL` seconds, bounded by an independent wall-clock guard (`TRY_TIMEOUT * 3`), gating the ACCEPT on all of:
  1. **Apply evidence + settle floor**: the probe interface (first added VLAN's `<iface>.<id>`) exists - proof the apply has BEGUN (netdev creation is async after the networkd restart; it does not prove completion), which is why health sampling additionally waits for the `APPLY_FALLBACK_SETTLE` floor. No-addition changes (removal-only, `--reapply`) have no probe and NO in-kernel signal at all (netplan try does not delete removed netdevs, and a rerender changes no kernel state), so they anchor at t=0 and use the LARGER `APPLY_NOEVIDENCE_SETTLE` floor (`apply_settle_floor`), sized so the first health sample lands post-apply instead of on pre-apply routing (C2, 2026-08-04). That floor is bounded above by the confirmation window (round 0) so a no-addition change can still accept; there is no positive completion signal for these changes by design (prompt-parsing was rejected as version-fragile). netplan try's exit is logged on both paths for audit, but cannot un-accept.
  0. **Confirmation-window bound (round 3)**: accepting is forbidden once `waited - seen_at >= TRY_TIMEOUT - 2*POLL_INTERVAL` (seen_at = first apply evidence). netplan try's revert timer starts at its apply completion, at or before seen_at; past the bound a still-alive try may be mid-REVERT, the revert restores routing (health PASSes!), and a buffered newline would false-ACCEPT a rolled-back change. Past-bound = FAIL path.
  2. **Liveness**: `netplan try` still alive, re-checked at the accept instant. Dead try = reverted or failed = never accept (a false accept would run FR-24 deletes + restarts for a change never applied - e.g. "another netplan process is running" exits early with routing untouched and health trivially PASSing).
  3. **Health**: `HEALTH_CONSEC` consecutive PASS samples.
- PASS(all) → write `\n`, close, reap. FAIL → **write nothing and keep the fifo write-end OPEN until `netplan try` exits**, so revert rides netplan's own validated timeout path; stdin-EOF on early close is NOT hardware-validated behavior and is deliberately never exercised. Bounded wait, then log-and-proceed if wedged (flock releases on our exit).
- The accept-write tolerates `netplan try` having already exited (`SIGPIPE`/`EPIPE` ignored).
- `N` (`TRY_TIMEOUT`) is set explicitly, never left to netplan's 120s default.

## 10. Data representation

- VLAN sets: space-separated sorted `iface.id` TOKEN lists in shell vars downstream of detection (never bare VLAN ids - two trunks can share an id, so the token is the only collision-free key); per-trunk bare-id lists only inside the per-trunk loop (`compute_candidates`/`boot_removals`), tagged to tokens immediately after. Set ops via `comm`/`grep -F` or the pure token helpers (`tag_tokens`/`untag_tokens`/`tokens_for_iface`/`distinct_ifaces`).
- Known-set (`backend_owned_vlans`): parsed from `90-dynavlan.yaml` stanza headers as `iface.id` tokens (`netplan get network.vlans` is authoritative for IDs, but the token comes from our own file since that is what disambiguates a shared id across trunks).
- `VLAN_IGNORE`: parsed once into an associative-array set for O(1) membership (bare ids; it filters within a trunk's own candidate math, before tagging).
- Generated VLAN stanza per token (FR-14): `<iface>.<id>` with `dhcp4: true` + `use-routes/use-dns/use-ntp/use-domains: false` + `accept-ra: false` (FR-14a). The four `use-*` keys sit under `dhcp4-overrides` and bind DHCPv4 alone; IPv6 RA is a separate unsolicited channel networkd accepts by default on a non-router link, and an RA-installed default route would be invisible to the IPv4-only health check. `accept-ra: false` is emitted in routed mode too, since FR-37's metric guard only reasons about metrics dynavlan assigns.
- Routed mode (FR-37, `VLAN_ROUTES=true`, default off): the stanza becomes `use-routes: true` + `route-metric: <assigned>`; DNS/NTP/domains stay declined. The "token:metric" map is computed by the pure `plan_route_metrics` (the single choke point, so boot/rescan/dry-run - and `--reapply` - all agree; every caller MUST use it rather than composing `map_filter`/`assign_route_metrics` itself): kept tokens keep their metric read back from our own YAML (`backend_owned_metrics` - the owned file doubles as the assignment store, no extra state file); the tokens given a NEW metric are the target tokens lacking one, next-free ascending in discovery order across the whole box (one shared metric sequence over every trunk, not one per trunk). `VLAN_ROUTE_METRIC_MODE`/`id` mode was dropped in the all-trunks redesign - discovery order is the only mode, since a stateless START+id scheme has no natural per-trunk meaning once ids are no longer globally unique. Assigning for `additions` instead of "target tokens lacking a metric" was a defect (fixed 2026-07-25): on an isolated -> routed migration every owned token lacks a metric while additions is empty or partial, so generation refused permanently. Before any disk change, `metric_conflict` refuses loudly if an assigned metric would match or beat the uplink default's metric (that VLAN's default would win, guaranteeing an FR-18 health-FAIL revert loop - refuse up front instead of revert-looping). Empty pre-apply snapshot with routes on: a VLAN default may become the uplink; documented as intended failover (PRD FR-37).

## 11. systemd units & install layout

- `/usr/local/sbin/dynavlan` (0755), the script.
- `/etc/dynavlan.conf` (commented defaults).
- `/etc/netplan/90-dynavlan.yaml` (0600, generated).
- `dynavlan.service`: `Type=oneshot`, `After=systemd-networkd.service`, NOT `Wants/After=network-online.target`, `ExecStart=/usr/local/sbin/dynavlan --boot`, `WantedBy=multi-user.target`, `TimeoutStartSec=600` (boot can take CARRIER_WAIT + 2*SNIFF + BOOT_SETTLE + lease settle).
- `dynavlan-rescan.service`: `Type=oneshot`, `ExecStart=/usr/local/sbin/dynavlan --rescan`, no `[Install]` (activated only by the timer). SEPARATE from dynavlan.service because a `.timer` activates a service with a fixed `ExecStart` mode, and boot (reconcile, with removals) vs rescan (add-only) are different modes. This is one more unit than the original "two units" wording.
- `dynavlan.timer`: `OnBootSec`/`OnUnitActiveSec` (monotonic), `Unit=dynavlan-rescan.service`, `WantedBy=timers.target`; interval via `.d/interval.conf` from `RESCAN_MINUTES` (rendered by `--reconfigure`).
- Persistent journald guaranteed at install (`/var/log/journal` + `Storage=persistent` drop-in). dynavlan logs to the journal via stderr (identifier `dynavlan`); the optional `/var/log/dynavlan.log` file branch was not built - the install guarantees the journald branch instead (FR-31 requires one branch, not both).
- `install.sh`: require root; install script (0755) + config (0644, never clobber existing) + all three units; ensure `tcpdump` and `lldpd` present; write the journald persistence drop-in; `--reconfigure`; `enable dynavlan.service` + `enable dynavlan.timer` (both armed for NEXT boot - deliberately NOT `--now`: a monotonic timer whose `OnBootSec` is already past fires immediately, which would run a rescan apply before the operator's `--dry-run` preview). Install never triggers any network change; first apply is the operator's `--boot` or the next reboot (which also starts the timer).
- Known limitation (FR-11): if an external netplan file reuses dynavlan's exact stanza key (`<iface>.<id>`), `netplan get` merges the two entries into one and the overlap warning cannot fire (detecting it would require reading base files by name, which crosses the never-read-base-config line). Accepted; different-key/same-id overlaps are detected and warned.

## 11a. Restart-on-new-subnet (FR-40)

FR-27's restart trigger fires only on a tagged-VLAN change, so two real cases are missed: an access port or native-only trunk that gets a lease after boot (dynavlan detects no *tagged* VLAN on it, so nothing changes), and the monitoring agent starting before base-interface DHCP completes (FR-29 deliberately does not block boot on `network-online.target`). Both are really the same problem: the agent cares about IPv4 subnets it can scan, not about VLAN tags.

**The seen-set.** `maybe_restart_on_new_subnet` samples `current_subnets` - sorted `iface:network/prefix` tokens from every global-scope IPv4 address on the box (link-local and loopback excluded) - and compares against a stored seen-set at `SEEN_FILE` (`/run/dynavlan/seen`). The token is keyed on the network (via `ipv4_network`), never the host address, so a same-pool DHCP renewal produces an identical token and does not restart. The seen-set is monotonic: it only ever grows (`seen ∪ current`, via `set_union`), so a link flap back onto an already-seen subnet does not re-trigger. Ordering throughout uses `emit_tokens` (lexical `sort -u`), the string-token counterpart of `emit_set`, never `emit_set` (numeric, bare-VLAN-id only).

**Why `/run`, not the owned YAML.** Two independent reasons, not one: (1) lifetime - `/run` is tmpfs, wiped on reboot, which is exactly the seen-set's required semantics (on reboot the agent relaunches and must re-enumerate, so the baseline has to reset to empty); the owned YAML persists across reboots, so storing `seen` there would leave it populated after reboot and defeat the boot-race fix. (2) keeping the safety-critical file off this path - the owned YAML is written only inside `apply_change`'s generate → validate → `netplan try` → accept/rollback chain (FR-16/17/18), and `seen` updates as often as every rescan; routing that traffic through the one file that must never end up partially written on a headless box buys nothing and adds risk for free.

**Empty-seen-at-boot.** There is no boot-specific branch. `read_seen` returns empty when `SEEN_FILE` is absent (first run of an uptime), so on boot `current − seen == current`: if any real subnet is present, the growth-check fires and restarts once after settle, whether the agent started before or after DHCP. The unified rule (`new = current − seen`; if non-empty, restart once; `seen = seen ∪ current`) runs identically on every boot and rescan.

**Dedup against the VLAN restart.** `apply_change` is untouched: its own `wait_leases → restart_targets` on ACCEPT still fires on every VLAN change, in every mode. `restart_targets` sets a per-run `RESTARTED_THIS_RUN` flag whenever it runs (whether called from `apply_change` or from the growth-check itself), so at most one restart happens per run - a VLAN-driven restart suppresses a redundant subnet-driven one, and vice versa.

**Hook point.** `main` calls `maybe_restart_on_new_subnet` once, after `do_boot`/`do_rescan` returns, on the `--boot | --rescan` dispatch arm - unconditionally, regardless of the mode's own return code, so it also runs after a health-FAILed/reverted apply or a `VLAN_LIMIT`-refused apply (subnet appearance is independent of VLAN provisioning outcome). It is NOT called from `--dry-run`, `--status`, or `--reapply`: those report the would-restart delta (`current_subnets − read_seen`) for visibility but never call `restart_targets` and never call `write_seen`, keeping them side-effect-free per FR-34/FR-35.

## 11b. Carrier-down VLAN removal (FR-41)

Through v0.3.0, a trunk going carrier-down was treated identically to a tagless-but-carrier-up trunk: preserved unconditionally, on the theory that absence of evidence (a sniff miss) is not evidence of absence. That reasoning does not hold for carrier: `/sys/class/net/<iface>/carrier` is an authoritative kernel signal, not a passive/lossy one, and a carrier-down port categorically cannot pass frames - there is no "genuinely down but the switch still has it configured" case to protect against, unlike a silent-but-live VLAN.

**The rule.** When an OWNED trunk's link is carrier-down across a two-sample debounce (reusing the boot pass-2 settle where one already runs - note that reuse is what makes the interval `BOOT_SETTLE + CARRIER_WAIT + SNIFF` ≈ 110s on a `RESET_ON_BOOT=true` boot, since the pass-2 re-detect sits between the two carrier samples, versus a plain `BOOT_SETTLE_SECONDS` on rescan and on `RESET_ON_BOOT=false`; longer is preserve-biased, so this is documented rather than "fixed" - sampling carrier before the re-detect would leave the two signals reflecting different instants) AND the box still has a healthy default route (`have_routing`), remove ALL owned VLANs on that trunk - a full teardown of the trunk's set, not a per-VLAN detection diff, since a dead port kills every VLAN riding it equally.

**Two pure helpers carry the decision**, both side-effect-free and unit-tested:
- `carrier_removals(owned_on_trunk, c1, c2)` - the debounce: returns the full owned set iff both samples are `down`, else empty (mirrors `boot_removals`'s shape; tests 1r).
- `have_routing()` - the routing pre-condition: composes existing `snapshot_default_route` + `has_carrier` (tests 1s). False means either no default route exists, or the only default egresses a now carrier-down iface (the dead trunk doubles as the box's own uplink, no redundancy) - in both cases, preserve. Note this is NOT redundant with the post-apply health check: that check reverts a removal which breaks routing, whereas this guards the case where routing is already gone, and there the empty route snapshot makes the health check an unconditional PASS. Both `do_boot` and `do_rescan` therefore evaluate it immediately before building the removal set, after any settle sleep - a pre-settle-only check would let an uplink lost during the settle through.

**Fire points and their settle mechanics differ, deliberately:**
- `do_boot`: piggybacks on the existing `RESET_ON_BOOT=true` pass-2 settle when one is already running (dual-purpose: same sleep serves the detection-diff AND the carrier resample). When `RESET_ON_BOOT=false`, there is no free pass-2 to reuse, so boot runs its OWN minimal settle+resample, but only if some owned trunk was already down at pass 1 (`need_pass2`, §6) - an all-up `RESET_ON_BOOT=false` boot stays single-pass, unchanged.
- `do_rescan`: gains its first removal path ever. Fast-path-preserved by construction: the settle sleep fires only when at least one OWNED trunk (not just `DETECTED_TRUNKS`) is actually carrier-down, so steady-state rescans (all trunks up) incur zero added latency.

**Independent of `RESET_ON_BOOT`.** `RESET_ON_BOOT` continues to govern only the sniff-based detection-diff removal (FR-23); `REMOVE_ON_CARRIER_LOSS` (default `true`) is the sole gate for carrier-down removal in both modes, so a `RESET_ON_BOOT=false` box (add-only across boots) still self-heals a dead trunk.

**Deferred alternative (recorded, not built): a grace-timer debounce.** Instead of the minimal two-in-run-pass check, a persistent tracker in `/run` could record first-seen-carrier-down time per trunk and require continuous down-ness for a configurable grace period (~2 rescan cycles) before pruning. This would avoid remove-then-re-add churn across a brief switch reboot or cable re-patch (tens of seconds to a few minutes), at the cost of an ephemeral `/run` tracker and a new grace config knob, and roughly 10 minutes slower cleanup of a genuine unplug. Rejected for v1: the minimal two-sample debounce accepts a self-healing monitoring-agent restart in the transient case, with no new persistent state; revisit if field data shows real churn from switch maintenance. See `docs/superpowers/specs/2026-07-30-carrier-down-vlan-removal-design.md`.

## 12. Portability plan (what to build now vs later)

**Now (cheap, structural):** the §4 backend seam as six functions; the abstract ownership model (§3); the `apply_with_revert` capability contract. The core never calls `netplan` directly. (`backend_detect` is deferred with the second backend - not built while netplan is the only one.)

**Later (only when a second backend is real):** NM/networkd/ifupdown implementations; a real `backend_detect`; any backend-selection config. Each future backend's hardest piece is the revert (NM native / networkd-direct hand-rolled).

**Not planned:** non-systemd init (OpenRC/runit) — systemd assumed for service/timer/journald; revisit only if it comes up.

## 13. Deferred open items (see context/open_questions.md)

- IR-1: exact minimum netplan version (pinned conservatively at 0.106; possible later relaxation).
- G-4: per-VLAN MAC derivation function (only needed if `PER_VLAN_MAC` is enabled; default off).
