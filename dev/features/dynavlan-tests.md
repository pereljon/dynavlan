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

### 1e. (removed) trunk-selection hysteresis

Removed in the all-trunks redesign: there is no longer a single selected trunk, so `select_trunk` and its hysteresis margin do not exist. Every carrier-up iface with a non-empty detected tag set is provisioned; stability across rescans falls out of the per-iface detection itself (no cross-iface contest to flap). Section number kept retired rather than reused, so historical references to "1e" in commit messages and review notes stay unambiguous.

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

### 1g. `assign_route_metrics` + `map_filter` + `metric_conflict` (FR-37 routed mode, `iface.id` token keys)

`VLAN_ROUTE_METRIC_MODE`/`id` mode was removed in the all-trunks redesign (a stateless START+id scheme has no coherent per-trunk meaning once ids are no longer globally unique); discovery order across the whole box is the only mode.

| assign: kept_map / additions / start | Expected |
|---|---|
| "" / "enp1s0.21 enp1s0.22" / 100 | enp1s0.21:100 enp1s0.22:101 (fresh, ascending) |
| "enp1s0.21:100 enp1s0.22:101" / "enp1s0.18" / 100 | enp1s0.18:102 enp1s0.21:100 enp1s0.22:101 (new token continues; kept verbatim, never renumbered) |
| "enp1s0.21:100" / "enp1s0.18 enp1s0.30" / 100 | enp1s0.18:101 enp1s0.21:100 enp1s0.30:102 (batch ascending) |
| "enp1s0.21:100" / "enp1s0.25" / 200 | enp1s0.21:100 enp1s0.25:200 (raised START wins for new) |
| "enp1s0.21:250" / "enp1s0.25" / 200 | enp1s0.21:250 enp1s0.25:251 (highest kept wins over START) |
| "enp1s0.21:100" / "enp2s0.21" / 100 | enp1s0.21:100 enp2s0.21:101 (same VLAN id on a different trunk is a distinct token, not a collision) |

| metric_conflict: uplink_metric / map | Expected |
|---|---|
| "" / "enp1s0.21:100" | OK (no pre-apply default) |
| 10 / "enp1s0.21:100 enp1s0.22:101" | OK (uplink below all) |
| 100 / "enp1s0.21:100 ..." | CONFLICT (tie counts) |
| 300 / "enp1s0.21:100 ..." | CONFLICT |

`map_filter` keeps only listed tokens' entries (drops removed VLANs' metrics before reassignment).

`plan_route_metrics` (added 2026-07-25) is the single decision point callers must use; these cases pin the migration defect it fixes:

| owned map / target / additions / start | Expected |
|---|---|
| `""` / `enp1s0.1 enp1s0.18 enp1s0.21` / `""` / 100 | `enp1s0.1:100 enp1s0.18:101 enp1s0.21:102` - **the defect**: isolated -> routed, every owned token lacks a metric while additions is empty |
| `""` / `enp1s0.1 enp1s0.18 enp1s0.21 enp1s0.22` / `enp1s0.22` / 100 | `enp1s0.1:100 enp1s0.18:101 enp1s0.21:102 enp1s0.22:103` - migration plus a real addition in one run |
| `enp1s0.1:100 enp1s0.18:101` / `enp1s0.1 enp1s0.18 enp1s0.22` / `enp1s0.22` / 100 | `enp1s0.1:100 enp1s0.18:101 enp1s0.22:102` - steady state unchanged by the fix |
| `enp1s0.1:100 enp1s0.18:101` / `enp1s0.1 enp1s0.18` / `""` / 100 | `enp1s0.1:100 enp1s0.18:101` - zero churn must NOT renumber (the `--reapply` case) |
| `enp1s0.1:100 enp1s0.18:101 enp1s0.21:102` / `enp1s0.1 enp1s0.18` / `""` / 100 | `enp1s0.1:100 enp1s0.18:101` - removed VLAN's metric dropped, survivors verbatim |
| `""` / `enp1s0.18 enp2s0.18` / `""` / 100 | `enp1s0.18:100 enp2s0.18:101` - same VLAN id on two trunks gets two distinct metrics, one shared sequence |

Pre-fix, `apply_change` passed `additions` as the set needing metrics. Those sets differ whenever an owned VLAN has no persisted metric, so enabling `VLAN_ROUTES=true` on a box that already owned VLANs made `backend_generate_config` refuse (`internal: no route metric assigned for TOKEN`) on every run thereafter, blocking new VLANs too. Pinned as one function rather than a call sequence because `--reapply` and any later drift check must compute the map the same way `apply_change` does; two call sites recomposing it is how they silently diverge.

### 1h. `parse_version` + `version_ge` (FR-0 netplan version probe)
| parse_version input | Expected |
|---|---|
| "netplan   1.0" | 1.0 (netplan >= 1.0 `--version` output) |
| "0.107.1-3ubuntu0.22.04.4" | 0.107.1 (dpkg revision suffix must not leak in) |
| "1:0.107.1-3ubuntu0.22.04.4" | 0.107.1 (dpkg epoch prefix skipped) |
| "0.106" | 0.106 (bare two-component) |
| "usage: /usr/sbin/netplan  [-h] [--debug]" | "" (help text is not a version) |
| "" | "" |

| version_ge: A / B | Expected |
|---|---|
| 1.0 / 0.106 | true (sort -V; a string compare gets this backwards) |
| 0.107.1 / 0.106 | true |
| 0.106 / 0.106 | true (floor is inclusive) |
| 0.105 / 0.106 | false |

`netplan_version` itself is impure (shells out) and is exercised in Layer 3, not here: the parse is what is unit-testable. The source order it must honor is `netplan --version` (netplan >= 1.0 only) then `dpkg-query -W netplan.io` (the 0.10x fleet), stdout only, never stderr.

### 1i. `lldp_tagged_vlans` (FR-7a native/pvid exclusion)
Input is `lldpctl -f keyvalue` text. The key carries no per-VLAN index, so `vlan-id` and its `pvid` are correlated by adjacency; these cases pin that the parse stays stateful.

| Input shape | Expected |
|---|---|
| `vlan-id=100` + `pvid=yes` (the validated Meraki trunk) | "" (sole advertised VLAN is the native one) |
| `vlan-id=100 pvid=yes`, `vlan-id=21 pvid=no`, `vlan-id=22 pvid=no` | "21 22" (native dropped, tagged kept, sorted) |
| named blocks (`vlan=Voice` / `vlan=Native`) around the id/pvid pairs | "30" (a `vlan=` name line must not be read as an id) |
| `vlan-id=100`, `vlan-id=21`, no `pvid` key at all | "21 100" (absent flag is not evidence of native) |
| non-VLAN keyvalue text (`chassis.name=sw1`) | "" |
| "" | "" |


Key-shape isolation (added after the 2026-07-25 review round):

| Input shape | Expected | Why |
|---|---|---|
| a foreign `.mgmt.vlan-id=999` line between a VLAN's `vlan-id=100` and its `pvid=yes` | `` (empty) | loose matching flushes 100 as tagged before the pvid arrives, rebuilding the dead native interface FR-7a exists to prevent |
| a foreign `.med.policy.vlan-id=200` line among real VLAN blocks | `30` | the foreign key's VALUE must not leak in as a VLAN candidate; pre-fix output was `30 200` |

These pin that the patterns anchor on `.vlan.vlan-id=` / `.vlan.pvid=yes` (the VLAN TLV's own subtree), so the parse does not depend on assuming what else lldpd emits.
### 1j. `render_timer_dropin` (FR-21a rescan timer actually elapses)
The assert is an exact whole-file match, which pins content AND ordering: the reset line must precede the re-assignments or it wipes them too.

| Case | Expected |
|---|---|
| `render_timer_dropin 7` | exact drop-in text: reset, then `OnActiveSec=2min`, then `OnUnitActiveSec=7min` |
| any interval | output always contains a first-fire trigger (`OnActiveSec=`) - the regression guard for the dead-timer bug |

The failure this pins is silent: a drop-in carrying only `OnUnitActiveSec` yields a timer that is `active` and `Result=success` but has no anchor to elapse from, so it never runs and never errors. Unit tests can only assert the rendered text; that the timer actually elapses is L3-24.

### 1k. `version_string` - build provenance (FR-38)

| Case | Expected |
|---|---|
| `version_string 0.1.0 source` | `0.1.0 (build source)` |
| `version_string 0.1.0 18a6ea2` | `0.1.0 (build 18a6ea2)` |
| `version_string 0.1.0 18a6ea2-dirty` | `0.1.0 (build 18a6ea2-dirty)` (dirty marker carried verbatim) |
| `version_string 0.1.0 ""` | `0.1.0 (build unknown)` - never `(build )` |

The format is pinned deliberately: this string is what `--version`, every `run start:` journal line, and the generated netplan header all print, so log-scraping and after-the-fact provenance depend on it. The empty case matters most - a failed install-time stamp must read as missing provenance, not pass for an identity.

The stamping itself is install-time, not runtime; `install.sh` self-verifies with a `grep` for the stamped line plus `bash -n` and refuses to install otherwise. L3-27 covers it on a box.

### 1m. `config_body_differs` (FR-39 reapply comparison)

| A vs B | Expected |
|---|---|
| identical | SAME |
| **header/build id differs ONLY** | **SAME** - the FR-38 apply-loop guard: the build stamp changes every rebuild, and comparing it would force a no-change apply on every upgrade |
| body differs (an added `accept-ra` line) | DIFFERENT |
| difference on line 2 | DIFFERENT - proves the skip is exactly one line, not "the header region" |
| live side empty (no file yet) | DIFFERENT |
| both empty | SAME |

The skip is positional, never a pattern match on header text: a pattern match would silently stop matching if the header format changed, and the resulting failure mode is an apply loop rather than an error.

### 1l. Build-stamp contract (FR-38) - a cross-file invariant, not a function

`install.sh` rewrites the `build=` line by matching `/^build=/`. That coupling is invisible from either file alone: rename the variable, indent it, compute it, or add a second `build=` line, and the stamp silently hits the wrong line or none. The installer still succeeds, and every box installed afterwards misreports which code it runs - FR-38's exact failure, reintroduced by a tidy-up. So these asserts pin the contract itself:

| Assertion | Why |
|---|---|
| exactly one `^build=` line, column 0 | what `install.sh` matches on |
| exactly one `^ver=` line | same, for the version bump gate |
| the installer's awk transform substitutes it | the real transform, not a paraphrase of it |
| exactly one line differs; line count preserved | catches a transform that mangles the rest |
| stamped script passes `bash -n` | a botched stamp must never run as root |
| stamped script's `--version` reports the stamp | end-to-end, not just textual |
| unstamped checkout reports `source` | the dev-box default stays honest |

Verified to FAIL when the contract is broken (indenting the line, or adding a second one) - a guard that cannot fail is decoration. If 1l fails, fix the script, never the test.

### 1n. Token helpers (`emit_tokens` / `tok_iface` / `tok_id` / `tag_tokens` / `untag_tokens` / `tokens_for_iface` / `distinct_ifaces`) - all-trunks canonical key

These convert between the token domain (`iface.id`, every set downstream of detection) and the per-trunk bare-id domain the per-trunk math operates in. A collision case is the load-bearing one: without the token, two trunks sharing a VLAN id would alias in every downstream set.

| Case | Expected |
|---|---|
| `tok_iface "enp1s0.100"` | `enp1s0` (split on the LAST dot) |
| `tok_id "enp1s0.100"` | `100` |
| `tag_tokens enp1s0 "18 21"` | `enp1s0.18 enp1s0.21` |
| `untag_tokens "enp1s0.18 enp2s0.18"` | `18` (dedup: same bare id from two trunks collapses to one when queried without iface scope - the reason bare ids are never used as a cross-trunk key) |
| `tokens_for_iface "enp1s0.18 enp2s0.18 enp1s0.21" enp1s0` | `enp1s0.18 enp1s0.21` |
| `distinct_ifaces "enp1s0.18 enp2s0.18 enp1s0.21"` | `enp1s0 enp2s0` (sorted, deduped) |
| `distinct_ifaces ""` | `` (empty; no owned/no trunks case) |
| `emit_tokens "enp1s0.18 enp1s0.5 enp1s0.18"` | `enp1s0.18 enp1s0.5` (sorted lexicographically as strings and de-duped; "5" sorts after "18" as text, so token sort is lexicographic, not numeric, unlike bare-id sets) |

### 1o. Multi-parent backend parsing (`backend_owned_vlans` / `backend_owned_metrics` / `backend_list_managed_vlans`)

The owned-file parse and the managed-elsewhere query both have to work when the generated YAML spans more than one parent link.

| Case | Expected |
|---|---|
| `backend_owned_vlans` against a file with stanzas `enp1s0.18:` and `enp2s0.21:` | `enp1s0.18 enp2s0.21` (both parents' tokens, sorted) |
| `backend_owned_metrics` against a file with `enp1s0.18:` / `route-metric: 100` and `enp2s0.21:` / `route-metric: 101` | `enp1s0.18:100 enp2s0.21:101` |
| `backend_list_managed_vlans enp1s0` when `netplan get network.vlans` shows a VLAN on `enp1s0` and a different one on `enp2s0` | only the `enp1s0` one, scoped to the given iface — VLAN ids managed elsewhere on a DIFFERENT trunk must not exclude a same-numbered id on the trunk being queried |
| `backend_list_managed_vlans enp1s0` where `enp1s0.18` is already owned AND VLAN 18 also exists on `enp2s0` managed elsewhere | `enp1s0`'s own token is excluded via `tokens_for_iface`/`untag_tokens` on that iface only; the `enp2s0` occurrence is irrelevant to this call |

### 1p. Multi-trunk pipeline integration (per-trunk candidates/removals → one combined token set)

Exercises the do_boot/do_rescan/do_dryrun loop-and-combine shape without a live apply: feed two trunks' detected/managed/owned sets through `compute_candidates` per trunk, tag each result, and confirm the combined set is what a unified `apply_change` would receive.

| Setup | Expected combined additions |
|---|---|
| enp1s0 detected={18,21} owned={} ; enp2s0 detected={18,22} owned={} | `enp1s0.18 enp1s0.21 enp2s0.18 enp2s0.22` — VLAN 18 tagged on both trunks yields TWO tokens, not one (the collision case the token design exists for) |
| enp1s0 detected={18} owned={enp1s0.18} ; enp2s0 detected={18} owned={} | `enp2s0.18` only — enp1s0's 18 is already owned on enp1s0, but that does NOT suppress enp2s0's independent 18 (bare-id "owned" must be scoped per trunk, not box-wide) |
| enp1s0 carrier-down (excluded from the detected-trunk loop), owned={enp1s0.18} ; enp2s0 detected={21} | additions = `enp2s0.21`; enp1s0's owned token is untouched (preserved, not evaluated for removal since it has no carrier this pass) |

Removal-combination case (do_boot only, mirrors 1d but across two trunks):

| owned / enp1s0 pass1,pass2 / enp2s0 pass1,pass2 | Expected combined removals |
|---|---|
| `enp1s0.22 enp2s0.30` / {18,21},{18,21} / {18},{18} | `enp1s0.22` (absent both passes on enp1s0; enp2s0.30 absent too but enp2s0's owned set here is empty so nothing to remove there in this fixture) |

Note: 1d requires `boot_removals` to be exposed as a pure helper (per-trunk; the mode functions call it once per trunk and combine). 1f's helpers feed `gate_vlan_count` (refuse vs fill per `VLAN_LIMIT_MODE`, over the combined total). 1g's helpers feed `apply_change`'s FR-37 branch (assignment + up-front uplink-conflict refusal, over the combined target). `detect_lldp` is impure (shells out to `lldpctl`) and stays a Layer 3 concern; `lldp_tagged_vlans` holds all the logic worth unit-testing. The exclusion must NOT reach the sniff's contribution: `detect_iface` unions the two sources, and a VLAN genuinely carried tagged must survive even when LLDP names it the PVID.

## Layer 2 - `--dry-run` decision-path verification (real inputs)

`dynavlan --dry-run` exercises discovery → detection → filtering → candidate computation → `backend_validate` (throwaway tree) and prints the intended add/remove diff, with zero side effects. Use it as:

- **The decision-path smoke test** on any real box: run it, confirm the diff matches what the box's trunk actually carries (compare against `--status` and a manual `tcpdump ... vlan`).
- **The driver for the manual checklist below** (dry-run first, confirm the plan, then apply).
- **A per-site sanity check on the intended diff** before trusting the timer. Note: this confirms the *decision and that the config validates*, NOT that the config *applies safely* — apply safety (health check, revert, fifo accept) is Layer 3 only.

Verifies on real inputs: interface discovery, all-trunks detection (every carrier-up iface with tags, not a single selected trunk), sniff+lldp detection, range/ignore/exclusion filtering per trunk, and that the generated config validates. The dry-run validation tree includes the real base netplan files (see design §6), so it DOES surface an FR-17 base-file-freeze condition. Does NOT cover the apply/rollback path (by design) — that is Layer 3.

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
| L3-6 [VALIDATED 2026-07-27] | Health-check revert | Force a config that drops the uplink default route; apply | `netplan try` reverts on timeout, uplink restored, no deletes, no restarts, err logged. Also: the accept-write lands after the pipe closed (EPIPE) without crashing, and the apply-revert err line is still logged cleanly | AC-6, AC-11 |
| L3-7 | Removal after accept | Remove a VLAN via `--boot` two-pass; confirm | Stanza gone AND `ip link delete` ran (interface gone), only after accept | AC-3 |
| L3-8 | VLAN set changes on a live trunk | Change the allowed VLANs on the trunk's switch port (same NIC, different set); `--boot` | Old VLANs removed, new ones added on that trunk, single reconcile, other owned trunks untouched | AC-3 |
| L3-9 | Second untagged NIC | Ensure a second carrier-up untagged NIC exists | Never selected as trunk, gets no VLANs | AC-10 |
| L3-10 | Log durability | Reboot the box | Prior run's journal entries survive | AC-9 |
| L3-11 | flock death-release (FR-30) | While a `--boot` run holds the lock inside the `netplan try` window, `kill -9` it from the console | Kernel releases the fd-flock; `netplan try` reverts on timeout; uplink intact; a subsequent `--rescan` acquires the lock and runs (NOT permanently "skipped, run in progress") | AC-6 |
| L3-12 | Atomic write kill (FR-16) | `kill -9` during config generation (repeatedly, or via a temp/rename test hook) | `90-dynavlan.yaml` is always either the old complete file or the new complete file, never truncated; next run proceeds | AC-6 |
| L3-13 | No usable `netplan try` → refuse (FR-0) | Stub/mask `netplan try` capability or report an old netplan version | Refuse to run, `err` logged, NO fallback to bare `netplan apply`, no change | AC-5 |
| L3-13a | Version probe resolves on the real box (FR-0) | On the target appliance run `dynavlan --dry-run` and confirm it gets past the version precondition; cross-check against `dpkg-query -W netplan.io` | Version is determined (0.10x boxes resolve via dpkg, since `netplan --version` does not exist there) and the run proceeds; a probe that cannot determine a version logs the distinct "cannot determine netplan version" refusal, not "required (found unknown)" | AC-5 |
| L3-13b | Native/pvid VLAN never provisioned (FR-7a) | On a trunk whose switch advertises the native VLAN via LLDP (`lldpctl -f keyvalue <iface>` shows `pvid=yes`), run `--dry-run`, then `--boot` | The pvid VLAN is absent from `detected` unless the sniff saw it tagged; no `<trunk>.<pvid>` interface is created; no "acquired no lease" warning for it. On a box that already owns one from a pre-fix run, `--boot` removes it after accept | AC-3, AC-8 |
| L3-14 | Empty-snapshot accept (AC-12) | Boot with trunk up but uplink DHCP delayed (no default route at snapshot); apply an isolated-VLAN add | Change is ACCEPTED (not reverted); isolated VLANs come up; box is not left a no-op | AC-12 |
| L3-15 | Slow-apply accept race (§9) | Add many VLANs at once (slow apply) with a change that breaks the uplink route (test hook), so health would PASS pre-apply and FAIL post-apply | ACCEPT is NOT written before the apply completes (probe-iface evidence); health samples post-apply state; change REVERTS. Verify in the journal that the accept loop waited for the probe | AC-6 |
| L3-16 | FAIL path rides netplan's own revert | Force a health FAIL; observe the fifo/write-end lifecycle and netplan try's exit | dynavlan writes nothing and holds the fifo open until netplan try exits on its own timer; revert occurs; no stdin-EOF early-close is exercised; clean err log | AC-6, AC-11 |
| L3-17 | Dead-try false-accept guard | Kill netplan try (or trigger "another netplan process running") after launch, before accept | dynavlan does NOT accept, does NOT delete interfaces, does NOT restart the agent; err logged | AC-6, AC-11 |
| L3-18 | Trunk goes dark, preserved not relocated (AC-3, all-trunks) | With owned VLANs on NIC A, unplug A (or move the cable to NIC B without ever un-owning A); `--boot` | A's owned VLANs are PRESERVED (no carrier / no tags on A in either pass = skip removals on A, per-trunk); if B now carries tags, B is independently provisioned as ADDITIONS on its own trunk, in the SAME reconcile, alongside A's untouched set - there is no relocation branch moving A's set onto B | AC-3 |
| L3-29 | Second live trunk: independent provisioning + dual leasing | With two carrier-up trunks each carrying tagged VLANs (incl. an overlapping VLAN id tagged on both), run `--boot` | Both trunks provisioned in ONE reconcile via a single `netplan try`; the overlapping id yields two distinct interfaces (`<trunkA>.<id>` and `<trunkB>.<id>`), both lease independently; `--status`/`--dry-run` show both trunks | AC-1, AC-3 |
| L3-30 | Carrier-pull preserve (two trunks) | With both trunks owned, pull carrier on ONE trunk only; `--boot` | The carrier-down trunk's owned VLANs are preserved (not removed, per the dark-trunk rule); the still-up trunk reconciles normally (adds/removes as its own detection dictates) | AC-3, AC-4 |
| L3-31 | Routed mode across two trunks (FR-37) | VLAN_ROUTES=true with an overlapping VLAN id tagged on both trunks; `--boot` | Each trunk's copy of the id gets a DISTINCT metric from one shared ascending sequence (not one sequence per trunk); no metric collision; uplink stays lowest | AC-14 |
| L3-32 | Unified revert across two trunks | Force a health FAIL while both trunks have pending changes | Single `netplan try` reverts BOTH trunks' changes together; neither trunk is left half-applied; no deletes/restarts on either | AC-6, AC-11 |
| L3-19 | VLAN_LIMIT refuse and fill (FR-36/AC-13) | Set VLAN_LIMIT below the trunk's VLAN count; run --boot in refuse mode, then VLAN_LIMIT_MODE=fill | refuse: nothing new applied, owned set untouched, err names count/limit/remedies. fill: exactly VLAN_LIMIT VLANs (lowest ids), skipped ids named in the journal | AC-13 |
| L3-20 [VALIDATED 2026-07-27] | Mid-revert false-accept guard (§9 window bound) | Force a health FAIL throughout the window (uplink-breaking change); let netplan try's timer fire and revert; watch the accept loop across the revert | dynavlan stops sampling at the confirmation-window bound BEFORE the revert restores routing; no accept is written even though post-revert health PASSes while try is still alive; err "confirmation window elapsed" logged; FAIL path holds the fifo open to try's exit | AC-6, AC-11 |
| L3-21 | Reverted-addition ghost netdev | After an L3-6/L3-20 revert of an ADD, run --rescan and inspect exclusion logs | Known residual: the revert does not delete the created netdev, so the id may classify as "managed elsewhere" (via ip link) and be excluded until reboot. Record actual behavior; decide if a cleanup pass is needed | AC-11 |
| L3-22 [VALIDATED 2026-07-27] | Routed mode happy path (FR-37/AC-14) | VLAN_ROUTES=true, VLAN_ROUTE_METRIC_START above the uplink metric; run --boot; then a later --rescan that adds one more VLAN | Each VLAN's DHCP default route present at its assigned metric; uplink stays the lowest-metric default; health PASSes; on the rescan, prior VLANs keep their exact metrics (discovery mode), the new one takes the next | AC-14 |
| L3-24 | Rescan timer actually elapses (FR-21a) | After install and after an upgrade-path install (timer running, so it is stopped/restarted), run `systemctl list-timers dynavlan.timer` and `systemctl show dynavlan.timer -p TimersMonotonic -p NextElapseUSecMonotonic -p LastTriggerUSec` | NEXT/LEFT show a real time, never `n/a`; `TimersMonotonic` lists a first-fire trigger AND the interval; `NextElapseUSecMonotonic` is finite. Then wait past the interval and confirm `--rescan` runs appear in `journalctl -t dynavlan`. A timer that is `active` with `Result=success` proves nothing: the dead-timer bug had both | AC-7 |
| L3-25 | Sniff ignores our own egress (FR-5a) | With VLANs owned and leased, run `sudo tcpdump -i <trunk> -e -nn -Q out vlan` and `-Q in` side by side; then remove a VLAN from the switch trunk and run `--boot` | Outbound shows our tagged DHCP for owned VLANs; `detected` must NOT include a VLAN whose only traffic is ours. The de-trunked VLAN is absent from both boot passes and IS removed. Pre-fix behavior to guard against: the VLAN stays detected forever on its own DHCP retries and removal never fires | AC-3 |
| L3-23 | Routed-mode conflict refusal (FR-37) | VLAN_ROUTES=true with VLAN_ROUTE_METRIC_START at or below the uplink default's metric; run --boot | Refuses BEFORE any disk change: err names the uplink metric and the assigned map, nothing applied, owned set untouched | AC-14 |
| L3-28 | `--reapply` closes a generated-config gap (FR-39/FR-14a) | On a box whose owned set equals detected (so no run rewrites the config), install a build whose generated stanza differs. Confirm `grep -c accept-ra /etc/netplan/90-dynavlan.yaml` is 0 and an RA default route exists. Run `sudo dynavlan --reapply`. Then re-run it a second time | First run: logs drift, applies via `netplan try`, ACCEPTS **from real health passes inside the confirmation window** (not from the try timing out - check timestamps), writes `accept-ra`. RUNTIME proof, which is the only proof that counts: `IPv6AcceptRA=no` present in `/run/systemd/network/10-netplan-<iface>.network`, `ip -6 route show default` no longer lists any owned VLAN, no global SLAAC address on them, `fe80` still present. EVERY pre-existing owned VLAN still holds its IPv4 lease afterwards (the lease-wait-the-full-set requirement). Second run: "already matches", nothing applied, rc 0. Also confirm `--reapply` never runs detection (no carrier wait, no sniff in the log) and completes in seconds | AC-4, AC-11 |
| L3-27 | Build provenance (FR-38) | `dynavlan --version` as a NON-root user and again with a deliberately invalid `/etc/dynavlan.conf`; `sudo bash install.sh` from a clean checkout, then from one with an uncommitted edit; then `journalctl -t dynavlan | grep 'run start'` | `--version` prints `dynavlan <ver> (build <id>)` and exits 0 in BOTH cases (no root needed, config never loaded). Installer echoes the build id; the dirty tree installs `<hash>-dirty` and prints the uncommitted-changes WARNING. Every run-start line carries the identity. Confirm the installed `/usr/local/sbin/dynavlan` differs from the source only in the `build=` line | AC-7 |
| L3-26 | IPv6 RA declined on VLANs (FR-14a) | On a trunk carrying at least one RA-sending VLAN (validated: VLAN 22), run `--dry-run` first (proves netplan accepts the key), then `--boot`. After apply: `ip -6 addr show dev <trunk>.<id>`, `ip -6 route show default`, `resolvectl dns <trunk>.<id>`, and `networkctl status <trunk>.<id>` | No global (SLAAC) IPv6 address on any owned VLAN; NO IPv6 default route via any owned VLAN; no RA-sourced (RDNSS) resolvers on them; `IPv6AcceptRA=no` in the rendered `.network`. The `fe80` link-local address REMAINS (link-local is deliberately untouched). Also record whether a pre-existing SLAAC address survives the apply: networkd did not clean up orphaned VLAN links, so it may need a one-time `ip -6 addr flush`. Re-run under VLAN_ROUTES=true and confirm the key is still emitted | AC-4, AC-11 |

Several of these (netplan-try accept/revert, promisc sniff of an unconfigured VLAN, isolation stanza, explicit `ip link delete`) were already validated once by hand on the lab box; this codifies them as repeatable.

**Hardware run 2026-07-27 (serial-driven):** L3-6, L3-20 (revert + confirmation-window bound) and L3-22 (routed apply, metrics 100-106) all passed on the box. The health-FAIL is injected as a competing lower-metric default on `enp2s0` (the unmanaged dead NIC) during the try window - injecting it on a dynavlan-managed VLAN iface does NOT work, the apply's reconfiguration flushes it before health samples. See `context/decisions.md` 2026-07-27.

## Acceptance-criteria traceability

| AC | Method |
|----|--------|
| AC-1 | L3-1 |
| AC-2 | L3-1 + concurrent-`--rescan` step (lock forces skip, snap restarts exactly once; ties to FR-26 + FR-30) |
| AC-3 | L3-7, L3-8, L3-18, L3-29, L3-30 |
| AC-4 | L3-4 + Layer 1 1b empty-detected row |
| AC-5 | Layer 1 1a (invalid config value) + **L3-13 (missing/insufficient dependency, incl. no usable `netplan try`)** |
| AC-6 | L3-5 (validate fail), L3-6 (health fail), L3-11 (flock death), L3-12 (atomic write), L3-32 (unified revert, two trunks) |
| AC-7 | L3-3 (steady-state idempotency; no per-trunk selection to flap now that all trunks are provisioned independently) |
| AC-8 | L3-1, L3-2 |
| AC-9 | L3-10 |
| AC-10 | L3-9 |
| AC-11 | L3-6 |
| AC-12 | Layer 1 1c (evaluator) + **L3-14 (real empty-snapshot accept)** |
| AC-13 | Layer 1 1f (guard/fill math) + L3-19 (real refuse + fill) |
| AC-14 | Layer 1 1g (assignment + conflict math, token-keyed) + L3-22 (real routed apply + metric persistence) + L3-23 (real conflict refusal) + L3-31 (two-trunk metric sequence, NOT yet run on hardware) |

Note: FR-23 removal-set math is covered by Layer 1 1d (per-trunk; combined across trunks by 1p); FR-16/FR-30 by L3-11/L3-12. There is no FR-4 hysteresis requirement in the all-trunks model (superseded; see 1e above).

## Deliberately out of scope (add later if the tool graduates)

- A test framework (bats): the assert script suffices.
- A mock backend + state-machine suite: the manual checklist + `netplan try` safety net cover the branches at this scale.
- A synthetic/namespace virtual trunk or CI: not needed while testing runs on the real appliance plus live Meraki trunk; revisit if CI or multi-maintainer development starts.
- Coverage targets: not meaningful for a thin orchestration script.
