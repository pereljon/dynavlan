# dynavlan - Test Plan

Companion to `dev/features/dynavlan.md`. Scope is deliberately right-sized for a single-file bash tool one maintainer deploys on appliances: no test framework, no mock backend, no CI, no coverage target. Confidence comes from three cheap layers plus the `netplan try` auto-revert safety net (already validated).

## Philosophy

- Test the pure logic where silent bugs hide and are trivial to isolate.
- Use the tool's own `--dry-run` as the primary decision-path verification on real inputs.
- Exercise the apply/rollback safety cases by hand on the actual appliance with console access, since they cannot be safely triggered over SSH (a bad apply drops the uplink) and are not worth simulating; the real Meraki trunk is what exercises detection.
- Add heavier machinery (mock backend, namespace trunk, CI) only if dynavlan grows more maintainers or broader use. The §4 backend seam in the design doc makes that a later, contained addition.

## Layer 1 - Unit assert script (pure functions)

A plain bash script (`tests/unit.sh`) with asserts, run manually or in a pre-commit. Covers only the three side-effect-free functions where an edge-input bug would silently mis-configure a VLAN and would not be obvious from running the tool.

### 1a. `parse_vlan_ignore`
| Input | Expected |
|-------|----------|
| `"1,5,20-25,80"` | {1,5,20,21,22,23,24,25,80} |
| `"1 5 80"` (spaces) | {1,5,80} |
| `"20-25,22"` (overlap) | {20,21,22,23,24,25} |
| `""` | {} (empty) |
| `"25-20"` | error (low>high) → refuse to run |
| `"5-"` / `"abc"` / `"1,,3"` | error → refuse to run |
| `"1,5000"` | error (>4094) → refuse to run |
| `"0"` | error (VLAN 0 reserved) → refuse to run |
| `"4094"` | {4094} (upper edge valid) |
| `"4095"` | error (VLAN 4095 reserved) → refuse to run |

### 1b. `compute_candidates`
`candidates = detected ∩ [MIN,MAX] − IGNORE − managed − owned`. Feed the five sets directly.
| detected / MIN-MAX / ignore / managed / owned | Expected candidates |
|---|---|
| {1,18,21} / 2-1000 / {} / {} / {} | {18,21} (1 below MIN) |
| {18,21} / 2-1000 / {21} / {} / {} | {18} (ignore wins) |
| {18,21} / 2-1000 / {} / {21} / {} | {18} (managed excluded) |
| {18,21} / 2-1000 / {} / {} / {21} | {18} (owned not re-added) |
| {5000,18} / 2-1000 / {} / {} / {} | {18} (out of range dropped) |
| {18,21} / 2-1000 / {} / {21} / {21} | {18} (21 in BOTH managed and owned; pins order-independence) |
| {} / 2-1000 / {} / {} / {} | {} (empty detection; feeds the FR-22 zero-detection guard) |

### 1c. `health_check` evaluator (snapshot vs post-apply, no live apply)
| Snapshot | Post-apply default route | Expected |
|----------|--------------------------|----------|
| (enp1s0, gw, 10) | via enp1s0 | PASS |
| (enp1s0, gw, 10) | via enp2s0 (different iface) | FAIL → revert |
| (enp1s0, gw, 10) | none | FAIL → revert |
| empty (no default) | none | PASS (empty→empty, AC-12) |
| empty (no default) | via enp1s0 (uplink finally leased) | PASS (change added no default) |
| (enp1s0, gw, 10) | via enp1s0, **metric 20** (metric changed) | PASS (FR-18 compares iface only; guards against a false-revert if someone tightens to compare metric) |
| (enp1s0, gw1, 10) | via enp1s0, **gw2** (gateway changed) | PASS (iface unchanged; ARP is non-fatal, guards against it silently becoming fatal) |
| (enp1s0, gw, 10) | two defaults: enp1s0 m10 AND enp2s0 **m5** | FAIL → revert (lowest-metric default moved off the snapshot iface; see design §8) |

Run: `bash tests/unit.sh` → all asserts pass. No framework dependency.

### 1d. `reconcile_boot` removal-set helper (FR-23, pure inner function)
The two-pass removal math is high-consequence (a bug tears down a real VLAN or leaves a stale one), so `reconcile_boot`'s pass-combination is factored into a side-effect-free helper `boot_removals(owned, pass1, pass2)` that Layer 1 tests directly.
| owned / pass1 / pass2 | Expected removals |
|---|---|
| {18,21,22} / {18,21} / {18,21} | {22} (absent from both) |
| {18,21,22} / {18} / {18,21} | {22} (21 present in pass2 so kept; 22 absent from both passes so removed) |
| {18,21,22} / {18,21,22} / {18,21,22} | {} (all present) |
| {18,21} / {} / {} | {18,21} (both absent both passes) but gated by FR-22: if BOTH passes empty → zero-detection abort, remove nothing |

### 1e. `detect_union` trunk-selection hysteresis (FR-4, pure inner function)
Trunk selection stability underwrites AC-7/NFR-2; a flapping choice causes repeated applies. Factor the decision into `select_trunk(candidates, previous)` and test:
| candidates (iface→tag-count) / previous | Expected trunk |
|---|---|
| {enp1s0:5, enp2s0:1} / none | enp1s0 (most tags) |
| {enp1s0:3, enp2s0:3} / enp1s0 | enp1s0 (tie → stick with previous) |
| {enp1s0:2, enp2s0:5} / enp1s0 | enp2s0 (clear supersede) |
| {enp1s0:3, enp2s0:4} / enp1s0 | enp1s0 (marginal lead does not flip; hysteresis margin) |

### 1f. `vlan_guard` + `limit_fill` (FR-12/FR-36 count gate)
| n / warn / limit | Expected |
|---|---|
| 10 / 32 / 64 | OK |
| 32 / 32 / 64 | OK (at warn, not above) |
| 40 / 32 / 64 | WARN |
| 64 / 32 / 64 | WARN (at limit, not over) |
| 70 / 32 / 64 | OVER |
| 70 / 32 / 0 | WARN (0 = unlimited, never OVER) |
| 20 / 32 / 10 | OVER (limit below warn still fires) |

| limit_fill: additions / slots | Expected |
|---|---|
| "1 5 9 20" / 2 | {1,5} (lowest-N, deterministic) |
| "9 1 5" / 2 | {1,5} (sorts before cutting) |
| "1 5 9" / 0 | {} |
| "1 5" / 10 | {1,5} |

### 1g. `assign_route_metrics` + `map_filter` + `metric_conflict` (FR-37 routed mode)
| assign: kept_map / additions / start / mode | Expected |
|---|---|
| "" / "21 22" / 100 / discovery | 21:100 22:101 (fresh, ascending) |
| "21:100 22:101" / "18" / 100 / discovery | 18:102 21:100 22:101 (new id continues; kept verbatim, never renumbered) |
| "21:100" / "18 30" / 100 / discovery | 18:101 21:100 30:102 (batch ascending) |
| "21:100" / "25" / 200 / discovery | 21:100 25:200 (raised START wins for new) |
| "21:250" / "25" / 200 / discovery | 21:250 25:251 (highest kept wins over START) |
| "21:999" / "18 22" / 100 / id | 18:118 21:121 22:122 (stateless START+id, kept ignored) |

| metric_conflict: uplink_metric / map | Expected |
|---|---|
| "" / "21:100" | OK (no pre-apply default) |
| 10 / "21:100 22:101" | OK (uplink below all) |
| 100 / "21:100 ..." | CONFLICT (tie counts) |
| 300 / "21:100 ..." | CONFLICT |

`map_filter` keeps only listed ids' tokens (drops removed VLANs' metrics before reassignment).

Note: 1d/1e require `reconcile_boot` and `detect_union` to expose these as pure helpers. This is a deliberate testability constraint on the implementation (see design §5). 1f's helpers feed `gate_vlan_count` (refuse vs fill per `VLAN_LIMIT_MODE`). 1g's helpers feed `apply_change`'s FR-37 branch (assignment + up-front uplink-conflict refusal).

## Layer 2 - `--dry-run` decision-path verification (real inputs)

`dynavlan --dry-run` exercises discovery → detection → filtering → candidate computation → `backend_validate` (throwaway tree) and prints the intended add/remove diff, with zero side effects. Use it as:

- **The decision-path smoke test** on any real box: run it, confirm the diff matches what the box's trunk actually carries (compare against `--status` and a manual `tcpdump ... vlan`).
- **The driver for the manual checklist below** (dry-run first, confirm the plan, then apply).
- **A per-site sanity check on the intended diff** before trusting the timer. Note: this confirms the *decision and that the config validates*, NOT that the config *applies safely* — apply safety (health check, revert, fifo accept) is Layer 3 only.

Verifies on real inputs: interface discovery, trunk selection, sniff+lldp detection, range/ignore/exclusion filtering, and that the generated config validates. The dry-run validation tree includes the real base netplan files (see design §6), so it DOES surface an FR-17 base-file-freeze condition. Does NOT cover the apply/rollback path (by design) — that is Layer 3.

Lock interaction (round-4): while a `--boot`/`--rescan` holds the FR-30 flock, a concurrent `--dry-run` warns "run in progress; preview may reflect mid-change state" and still completes read-only; conversely, while a dry-run's preview runs, a timer rescan logs "skipped, run in progress" and retries next cycle. Quick check: start `--dry-run` (its sniff window is long enough) and `systemctl start dynavlan-rescan.service` mid-window; confirm the skip line in the journal.

## Layer 3 - Manual hardware checklist (apply/rollback safety)

Run on the **actual Protectli/Ubuntu appliance plugged into the live Meraki trunk**, with **console access** (keyboard+monitor or serial) so a failed revert never strands the box. Testing on real hardware is deliberate: the Meraki trunk supplies real tagged frames, so sniff/LLDP detection is exercised for real rather than approximated by a synthetic bridge, and the igb NIC / netplan behaviors (promisc, rx-vlan-filter, try/revert) are the ones already hardware-validated. Console access is the one hard requirement: it is the recovery path independent of the box's own uplink. `netplan try` still auto-reverts on timeout, so most cases self-heal even with no intervention; the console is the backstop for the residual cases where the safety net itself is under test.

| # | Case | Steps | Expected | AC |
|---|------|-------|----------|----|
| L3-1 | Happy path add (+ exactly-once) | Trunk carries a new in-range VLAN; run `--boot`; fire a `--rescan` concurrently mid-apply | VLAN interface up with lease, no default route on it; the concurrent rescan is skipped (lock held); snap restarted **exactly once** | AC-1, AC-2, AC-8 |
| L3-2 | Isolation | Inspect the new VLAN's routes | Only the connected `/24`; no default, no DNS/NTP host routes | AC-8 |
| L3-3 | Steady state | Run `--rescan` repeatedly, no trunk change | No apply, no restart (check journal) | AC-7 |
| L3-4 | Zero-detection guard | Unplug trunk / no carrier; run `--boot` with `RESET_ON_BOOT=true` and known VLANs present | Aborts, changes nothing, known VLANs intact | AC-4 |
| L3-5 | Validate failure | Inject a bad generated stanza (test hook); apply | `netplan generate` fails, no apply, prior file preserved, err logged | AC-5, AC-6 |
| L3-6 | Health-check revert | Force a config that drops the uplink default route; apply | `netplan try` reverts on timeout, uplink restored, no deletes, no restarts, err logged. Also: the accept-write lands after the pipe closed (EPIPE) without crashing, and the apply-revert err line is still logged cleanly | AC-6, AC-11 |
| L3-7 | Removal after accept | Remove a VLAN via `--boot` two-pass; confirm | Stanza gone AND `ip link delete` ran (interface gone), only after accept | AC-3 |
| L3-8 | Relocation | Move the box to a trunk with a different VLAN set (replug to a different Meraki port profile, or change the port's allowed VLANs); `--boot` | Old VLANs removed, new ones added, single reconcile | AC-3 |
| L3-9 | Second untagged NIC | Ensure a second carrier-up untagged NIC exists | Never selected as trunk, gets no VLANs | AC-10 |
| L3-10 | Log durability | Reboot the box | Prior run's journal entries survive | AC-9 |
| L3-11 | flock death-release (FR-30) | While a `--boot` run holds the lock inside the `netplan try` window, `kill -9` it from the console | Kernel releases the fd-flock; `netplan try` reverts on timeout; uplink intact; a subsequent `--rescan` acquires the lock and runs (NOT permanently "skipped, run in progress") | AC-6 |
| L3-12 | Atomic write kill (FR-16) | `kill -9` during config generation (repeatedly, or via a temp/rename test hook) | `90-dynavlan.yaml` is always either the old complete file or the new complete file, never truncated; next run proceeds | AC-6 |
| L3-13 | No usable `netplan try` → refuse (FR-0) | Stub/mask `netplan try` capability or report an old netplan version | Refuse to run, `err` logged, NO fallback to bare `netplan apply`, no change | AC-5 |
| L3-14 | Empty-snapshot accept (AC-12) | Boot with trunk up but uplink DHCP delayed (no default route at snapshot); apply an isolated-VLAN add | Change is ACCEPTED (not reverted); isolated VLANs come up; box is not left a no-op | AC-12 |
| L3-15 | Slow-apply accept race (§9) | Add many VLANs at once (slow apply) with a change that breaks the uplink route (test hook), so health would PASS pre-apply and FAIL post-apply | ACCEPT is NOT written before the apply completes (probe-iface evidence); health samples post-apply state; change REVERTS. Verify in the journal that the accept loop waited for the probe | AC-6 |
| L3-16 | FAIL path rides netplan's own revert | Force a health FAIL; observe the fifo/write-end lifecycle and netplan try's exit | dynavlan writes nothing and holds the fifo open until netplan try exits on its own timer; revert occurs; no stdin-EOF early-close is exercised; clean err log | AC-6, AC-11 |
| L3-17 | Dead-try false-accept guard | Kill netplan try (or trigger "another netplan process running") after launch, before accept | dynavlan does NOT accept, does NOT delete interfaces, does NOT restart the agent; err logged | AC-6, AC-11 |
| L3-18 | Cross-NIC relocation (AC-3) | With owned VLANs on NIC A, move the trunk cable to NIC B; reboot | Both boot passes see A tagless and B tagged; relocation branch fires: A's VLANs removed (post-accept), B's set provisioned, single reconcile. Also verify the conservative case: single-pass-only evidence on B does NOT relocate | AC-3 |
| L3-19 | VLAN_LIMIT refuse and fill (FR-36/AC-13) | Set VLAN_LIMIT below the trunk's VLAN count; run --boot in refuse mode, then VLAN_LIMIT_MODE=fill | refuse: nothing new applied, owned set untouched, err names count/limit/remedies. fill: exactly VLAN_LIMIT VLANs (lowest ids), skipped ids named in the journal | AC-13 |
| L3-20 | Mid-revert false-accept guard (§9 window bound) | Force a health FAIL throughout the window (uplink-breaking change); let netplan try's timer fire and revert; watch the accept loop across the revert | dynavlan stops sampling at the confirmation-window bound BEFORE the revert restores routing; no accept is written even though post-revert health PASSes while try is still alive; err "confirmation window elapsed" logged; FAIL path holds the fifo open to try's exit | AC-6, AC-11 |
| L3-21 | Reverted-addition ghost netdev | After an L3-6/L3-20 revert of an ADD, run --rescan and inspect exclusion logs | Known residual: the revert does not delete the created netdev, so the id may classify as "managed elsewhere" (via ip link) and be excluded until reboot. Record actual behavior; decide if a cleanup pass is needed | AC-11 |
| L3-22 | Routed mode happy path (FR-37/AC-14) | VLAN_ROUTES=true, VLAN_ROUTE_METRIC_START above the uplink metric; run --boot; then a later --rescan that adds one more VLAN | Each VLAN's DHCP default route present at its assigned metric; uplink stays the lowest-metric default; health PASSes; on the rescan, prior VLANs keep their exact metrics (discovery mode), the new one takes the next | AC-14 |
| L3-23 | Routed-mode conflict refusal (FR-37) | VLAN_ROUTES=true with VLAN_ROUTE_METRIC_START at or below the uplink default's metric; run --boot | Refuses BEFORE any disk change: err names the uplink metric and the assigned map, nothing applied, owned set untouched | AC-14 |

Several of these (netplan-try accept/revert, promisc sniff of an unconfigured VLAN, isolation stanza, explicit `ip link delete`) were already validated once by hand on the lab box; this codifies them as repeatable.

## Acceptance-criteria traceability

| AC | Method |
|----|--------|
| AC-1 | L3-1 |
| AC-2 | L3-1 + concurrent-`--rescan` step (lock forces skip, snap restarts exactly once; ties to FR-26 + FR-30) |
| AC-3 | L3-7, L3-8 |
| AC-4 | L3-4 + Layer 1 1b empty-detected row |
| AC-5 | Layer 1 1a (invalid config value) + **L3-13 (missing/insufficient dependency, incl. no usable `netplan try`)** |
| AC-6 | L3-5 (validate fail), L3-6 (health fail), L3-11 (flock death), L3-12 (atomic write) |
| AC-7 | L3-3 + Layer 1 1e (trunk hysteresis stability) |
| AC-8 | L3-1, L3-2 |
| AC-9 | L3-10 |
| AC-10 | L3-9 |
| AC-11 | L3-6 |
| AC-12 | Layer 1 1c (evaluator) + **L3-14 (real empty-snapshot accept)** |
| AC-13 | Layer 1 1f (guard/fill math) + L3-19 (real refuse + fill) |
| AC-14 | Layer 1 1g (assignment + conflict math) + L3-22 (real routed apply + metric persistence) + L3-23 (real conflict refusal) |

Note: FR-23 removal-set math is covered by Layer 1 1d; FR-4 hysteresis by 1e; FR-16/FR-30 by L3-11/L3-12.

## Deliberately out of scope (add later if the tool graduates)

- A test framework (bats): the assert script suffices.
- A mock backend + state-machine suite: the manual checklist + `netplan try` safety net cover the branches at this scale.
- A synthetic/namespace virtual trunk or CI: not needed while testing runs on the real appliance plus live Meraki trunk; revisit if CI or multi-maintainer development starts.
- Coverage targets: not meaningful for a thin orchestration script.
