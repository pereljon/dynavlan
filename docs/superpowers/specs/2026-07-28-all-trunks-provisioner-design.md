# dynavlan: all-trunks provisioner - design

Status: DRAFT for review (2026-07-28). Supersedes the single-trunk selection model.
Owner: operator. Companion to `dev/features/dynavlan.md` (to be updated on implementation).

## 1. Purpose and the decision behind it

dynavlan today discovers **one** trunk (the interface carrying the most tagged VLANs, with hysteresis and a lexicographic tiebreak) and provisions VLANs only on it. That was an artifact of its monitoring-appliance origin, where a box has a single uplink trunk.

The project is being repositioned as a **general dynamic-VLAN provisioner**: given a box on one or more trunk ports, bring up every discovered VLAN on every trunk. This removes the single-trunk limitation and, as a direct consequence, removes the "which interface wins" heuristic that made behavior feel unpredictable - there is no contest when every trunk is provisioned.

Isolation stays the default (address-only, route/DNS/NTP/RA declined); routed mode stays opt-in and first-class. Nothing here changes those defaults; it changes how many interfaces they apply to.

## 2. Locked decisions (from brainstorming 2026-07-27/28)

1. **All trunks.** Configure detected VLANs on every trunk-carrying interface, processed in sorted interface-name order (deterministic; order does not affect the result).
2. **A "trunk" is** any carrier-up physical NIC with >= 1 detected tagged VLAN. An untagged-only NIC (0 tags) is not a trunk and gets nothing - it is the box's plain uplink, left alone.
3. **Overlapping VLAN IDs across trunks -> configure on both.** VLAN 100 on `enp1s0` and on `enp3s0` become two independent interfaces (`enp1s0.100`, `enp3s0.100`), each with its own lease. No dedupe; do not assume the same ID on two trunks is the same L2 network.
4. **Trunk goes dark -> preserve.** A trunk with no carrier keeps its owned VLANs untouched (unplugged != reconfigured). Removal fires only for a trunk that HAS carrier but no longer carries a VLAN (absent in both boot passes). Per-trunk version of the existing zero-detection guard.
5. **Scope: isolated + discovery-mode routed together.** `id` metric mode is dropped entirely (`VLAN_ROUTE_METRIC_MODE` removed). Discovery becomes the sole metric behavior.
6. **Routed metrics: discovery-order, keyed by full interface name** (`enp1s0.100`), never renumbered. This is already how the metric is stored (per-stanza `route-metric:`); multi-trunk just makes the key explicit.
7. **Unified single apply.** All trunks' VLANs live in the one owned netplan file and are applied in ONE `netplan try` with ONE health check and ONE revert - the existing atomic-apply safety model, box-wide.

## 3. Architecture: what changes, what does not

### Unchanged (the safety-critical core stays intact)
- **Apply/rollback state machine** (`apply_change` -> backup -> generate -> validate -> `netplan try` + health check -> ACCEPT/revert). One apply for the whole box.
- **Health check** (`snapshot_default_route` / `health_check_eval`): still snapshots the lowest-metric default route's interface and reverts if it moves. In isolated mode no VLAN on any trunk installs a default route, so more trunks does not change the uplink model at all. In routed mode the conflict guard already checks every assigned metric against the uplink; that generalizes unchanged.
- **Backups** (FR-19), **change-gated restarts** (FR-27/28), **deletes-only-after-ACCEPT** (FR-24), **flock/FR-30**, **atomic write** (FR-16).
- **Detection primitives**: `run_detection` already preps all NICs, uses one shared carrier deadline, and sniffs/LLDPs every carrier-up interface concurrently. That machinery is reused as-is; only the selection step changes.

### Changed
- **Detection selection.** `select_trunk` (most-tags + hysteresis + tiebreak) and the associated `TRUNK_IFACE` single value are REMOVED. `run_detection` instead yields a per-trunk map: `{ iface -> detected VLAN-id set }` for every carrier-up interface with >= 1 tag.
- **Candidate computation, per trunk.** For each trunk: `candidates_iface = detected_iface INTERSECT [VLAN_MIN,VLAN_MAX] - VLAN_IGNORE - managed-elsewhere - already-owned-on-that-iface`. `compute_candidates` stays a pure helper but is called per interface. Ownership and managed-elsewhere become interface-aware.
- **State model: multi-parent.** The owned YAML already supports stanzas under different `link:` parents. `owned_parent` (single) becomes `owned_parents` (set). `backend_owned_vlans` returns `(iface, id)` pairs (equivalently, the set of owned interface names). `backend_owned_metrics` is keyed by full interface name (`enp1s0.100`) - a faithful read of the per-stanza `route-metric:`.
- **Boot reconcile, per trunk.** `do_boot`: for each trunk WITH carrier, run the two-pass detection and compute removals as `owned-on-iface absent from both passes on that iface`. Trunks WITHOUT carrier contribute NO removals (preserve). Aggregate additions and removals across all trunks into one target set, then one `apply_change`. The **relocation branch is removed** - a trunk physically moving is now just an add on the new interface and (carrier permitting) a remove on the old one, handled by normal reconcile.
- **Zero-detection guard, generalized.** Per-trunk: a trunk contributes removals only when it had carrier and non-empty detection across the passes. Box-wide backstop: if NO interface has carrier or any tags at all, abort and change nothing (unchanged spirit).
- **Rescan.** `do_rescan`: add-only across all trunks (union of per-trunk candidates), pinned to the owned interfaces, never removes/relocates.
- **Generation, multi-parent.** `backend_generate_config` takes a description of `{ iface -> id set }` (or a flat `iface.id` list) and emits one stanza per `(iface, id)` with `link: <iface>`. Isolated stanza and routed stanza are otherwise unchanged (incl. `accept-ra: false`).
- **Metric assignment.** `plan_route_metrics` keyed by full interface name; discovery-order across the union of all trunks' VLANs; existing interfaces keep their metric verbatim; new ones append ascending. The `mode` parameter and the `id`-mode branch of `assign_route_metrics` are removed.
- **Config surface.** Remove `VLAN_ROUTE_METRIC_MODE`. (`VLAN_ROUTES`, `VLAN_ROUTE_METRIC_START`, `VLAN_MIN/MAX`, `VLAN_IGNORE`, count gate, restart targets all unchanged.)

### Removed
- `select_trunk`, the hysteresis logic, `TRUNK_IFACE` as a single global.
- The AC-3 relocation branch in `do_boot`.
- `VLAN_ROUTE_METRIC_MODE` and `assign_route_metrics`' `id` branch.

## 4. Data flow (boot)

```
run_detection (pass 1)
  -> { enp1s0: {10,20,100}, enp3s0: {100,200} }   # every carrier-up iface with tags
settle
run_detection (pass 2)  -> same shape
for each trunk iface with carrier in BOTH passes:
  additions_iface = compute_candidates(detected_iface, MIN, MAX, IGNORE, managed, owned_iface)
  removals_iface  = owned_iface ids ABSENT FROM BOTH pass1_iface AND pass2_iface   # FR-23: kept if present in either pass
trunk without carrier: additions_iface = {} ; removals_iface = {}   # preserve
target = union over trunks of (owned_iface - removals_iface) + additions_iface   # as (iface,id) pairs
count gate on |target| (box-wide)
[routed] plan_route_metrics over target (keyed iface.id) + conflict guard vs uplink
apply_change(target, additions, removals)   # ONE netplan try, ONE health check
  ACCEPT: prune backups -> delete removed (iface,id) links -> wait leases (added ifaces) -> restart targets
  FAIL:   converge disk to prior, no deletes, no restarts
```

## 5. Error handling / edge cases

- **No trunks at all** (no carrier or no tags anywhere): abort, change nothing (box-wide zero-detection guard).
- **A trunk loses carrier mid-life**: its VLANs preserved; no churn.
- **Same VLAN ID on two trunks**: two interfaces, two leases, two metrics (routed). No collision - interface names differ.
- **Native/PVID VLAN per trunk**: excluded per-trunk by the existing FR-7a `lldp_tagged_vlans` (detection is already per-interface).
- **Managed-elsewhere**: a VLAN ID defined in another netplan file is excluded on the interface(s) where that collision would occur; matched by ID per the existing FR-10 rule, applied per interface.
- **Count gate**: box-wide total across all trunks (the DHCP-burst and try-window concerns are whole-box). Removals-only always allowed.
- **Routed metric conflict**: any assigned metric <= uplink's metric -> refuse before disk, naming the interface and metric.
- **Health FAIL on the unified apply**: whole-box revert via `netplan try`; disk converges to prior; no deletes, no restarts (validated 2026-07-27).

## 6. Testing

- **Unit (pure helpers):** `compute_candidates` per-interface cases; `boot_removals` per-trunk (carrier-up vs carrier-down); `plan_route_metrics` keyed by iface.id across a multi-trunk union incl. overlapping IDs getting distinct metrics; removal of the `id`-mode cases. Multi-parent owned-set parsing.
- **Dry-run:** two-trunk fixture; confirm per-trunk additions/removals and the multi-parent target, and (routed) the iface.id:metric map.
- **Hardware (the box has enp1s0 + enp2s0):** plug a second trunk into enp2s0; confirm VLANs come up on both; confirm overlapping-ID case; pull one trunk cable and confirm the OTHER trunk's VLANs are untouched and the pulled trunk's VLANs are preserved (not removed); routed-mode multi-trunk metric assignment; unified revert still works.

## 7. Version / compatibility

This changes core behavior (single -> multi trunk) and removes a config key (`VLAN_ROUTE_METRIC_MODE`). Since 0.1.0 is unreleased, options: fold into 0.1.0, or bump to 0.2.0 to mark the model change. Recommend **0.2.0** for a clean behavioral boundary. On-disk single-trunk owned files remain readable (a single-parent file is just the degenerate multi-parent case), so existing boxes upgrade without a wipe.

## 8. Out of scope (deferred, not now)

- Interface allow/deny list (provision only named trunks, or exclude a mgmt NIC that carries tags). YAGNI until a concrete need; note as a likely future config.
- Per-VLAN gateway reachability testing (the "test routing on each VLAN" capability) - a separate feature, not this.
- Any replacement for `id`-mode fleet-uniform metrics - re-add only if a real fleet need appears.
- Routed-mode cross-trunk uplink semantics beyond the existing metric-conflict guard (e.g. deliberately routing via a specific trunk).

## 9. Open questions for the architect review

1. Is the per-trunk removal / carrier-gating correct against the "never strand, never churn" invariant, and does aggregating removals across trunks into one apply create any ordering hazard with the delete-after-ACCEPT rule?
2. Is keying owned-state and metrics by full interface name the right representation, or is an explicit `(iface, id)` tuple cleaner in the reconcile logic?
3. Does removing the relocation branch lose any safety property, or is "add on new + remove on old (carrier-gated)" strictly equivalent and safer?
4. Any hazard in the unified apply when trunks differ in carrier/lease timing (one trunk's VLANs lease fast, another slow) within the single health-check window?
5. Count gate box-wide vs per-trunk: any scenario where box-wide is wrong?
