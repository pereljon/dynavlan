# SKELETON: how dynavlan works

Owns: the logic flow and key invariants of the `dynavlan` script and its install lifecycle, as prose or pseudocode. Does NOT hold per-function purposes (dev/CODEMAP.md), requirements (docs/dynavlan-PRD.md), or dated history (context/decisions.md, docs/hardware-validation.md).
Maintain: update when control flow, call sequences, or invariants change. Describe current behavior only; record history in context/decisions.md.

Each invariant uses the same shape. **Rule** states what must hold. **Why** gives the reason. **Enforced by** names the functions and the `tests/unit.sh` sections that hold it in place. IDs in parentheses (H1, C2, FR-41) point to entries in docs/dynavlan-PRD.md, context/decisions.md, or the review records.

## Terms

- **Token**: an `iface.id` string, such as `enp1s0.100`. Every VLAN set after detection holds tokens, not bare VLAN ids.
- **Owned file**: `/etc/netplan/90-dynavlan.yaml`, the one netplan file dynavlan writes. The **owned set** is the tokens it defines.
- **Target**: the token set that the owned file must define after the run.
- **Candidate VLANs**: the VLAN ids or tokens that a run may add on a trunk (`compute_candidates`).
- **Candidate config**: the netplan YAML that dynavlan generates for the target.
- **Change**: the difference between the owned file and the candidate config. It is VLAN additions and removals, or for `--reapply` a changed config body.
- **Apply**: running the candidate config through `netplan try`.
- **Accepted**: dynavlan wrote the confirming newline to `netplan try`, so netplan keeps the candidate config. Any other outcome is a fail.
- **Revert**: `netplan try` restores the prior configuration because no confirmation arrived.
- **Health check**: the routing test that decides whether to accept (see "The accept primitive").
- **Trunk**: a physical interface that carries, or carried, owned or detected tagged VLANs. Carrier up or down is a separate state. A **dark trunk** is owned but no longer detected.
- **Run lock**: an `flock` held on an open file descriptor for `/run/dynavlan.lock`.

## Run lifecycle

Every invocation follows the same sequence. The mode decides how the target is computed.

```
main(mode)
  [--version: print "<ver> (build <id>)", exit 0; runs before config load and root check, on purpose]
  [-h/--help: usage, exit 0; also before config and root]
  load_config            # allowlist parse of /etc/dynavlan.conf, never sourced (H2); a bad value refuses the run
                         # --teardown only: an invalid config falls back to config_defaults, with a warning
  [--status/--reconfigure: root check, run, exit]
                         # --status gates its own detection on check_detect_deps (M8), not check_preconditions
  [--teardown: check_apply_prereqs instead of check_preconditions; run lock with the --reapply wait, held to exit]
  check_preconditions    # root; check_detect_deps; non-mutating `netplan try` probe (apply-only)
  [--dry-run: try the run lock non-blocking; hold it if free, else warn and continue read-only; preview; exit]
  [--reapply: take the run lock blocking (-w); busy past the timeout = err, rc 1, nothing applied]
  [--boot/--rescan: take the run lock non-blocking; busy = "skipped", rc 0; dispatch]
  [--boot/--rescan: maybe_restart_on_new_subnet on every exit path, except after a stop request (D2)]
```

`check_detect_deps` (M8) is the detection dependency gate. `check_preconditions` and `--status` share it.

- It checks netplan against `MIN_NETPLAN`. It reads the version from `netplan --version` on 1.x and from dpkg otherwise.
- An undeterminable netplan version is its own refusal.
- It checks the tools that `DETECT_METHOD` needs: tcpdump with `-Q in` support, and `lldpctl`.
- It is non-mutating. It does not check root or `netplan try`, because those gate an apply, not a report.

`check_apply_prereqs` is the `--teardown` gate. It checks root, `ip`, the netplan version, and a working `netplan try --help`, but not the detection tools.

**Rule:** Never unlink a lockfile on exit; hold the run lock only as an open file descriptor.

Why: The kernel releases the run lock when the process dies. So a dead run can never freeze the tool.

## Detection

```
run_detection
  discover_phys_ifaces   # /sys/class/net: device symlink, ARPHRD_ETHER, not wireless, name charset [A-Za-z0-9_-] (M1)
  prep_iface (all)       # admin-up and promisc on; promisc makes the NIC VLAN filter transparent; left on
  one shared carrier deadline (CARRIER_WAIT_SECONDS in total, not per port)
  concurrent sniff + LLDP per carrier-up iface, one SNIFF_SECONDS window in total; sniff is inbound only
  each method reports ok|fail; store_detection stashes TAGS_ (ids) and VALID_ (removal trust) per iface
  DETECTED_TRUNKS = every carrier-up iface with a non-empty tag set (no trunk selection)
  DETECT_INVALID  = every sampled iface whose detector failed, tagged or not (D5)
```

Detection time does not grow with the port count. Why: a box with 4 to 6 ports must finish inside the systemd start timeout. The sniff is the primary detector, because LLDP on Meraki advertises only the native VLAN. The default `DETECT_METHOD` is `both`.

### A failed capture is not an empty trunk (H1)

**Rule:** A sample from a failed detection method never authorizes a removal.

Why: A failed method returns an empty or truncated id set that looks exactly like a quiet trunk. A removal based on that set would drop VLANs that the switch still trunks.

- `detect_sniff` and `detect_lldp` return `"STATUS IDS"`, where `STATUS` is `ok` or `fail`.
- The sniff `STATUS` comes from tcpdump's own exit, captured before the grep pipeline. Otherwise `pipefail` and grep's exit 1 on no match would mask a real failure.
- `timeout` returns 124 when the capture window ends normally. So exit 0 and exit 124 are `ok`, and any other exit is `fail`.
- The LLDP `STATUS` also checks for the "unable to connect" diagnostic. lldpd 1.0.13's `lldpctl` exits 0 when its daemon is down (HV-41).
- `prep_iface` records a failure to bring the iface up or to set promiscuous mode.
- `store_detection` combines the three results through `detection_sample_valid` into a per-iface `VALID_` verdict. An empty or short detection line defaults to `invalid`.
- The verdict gates removals only. Additions still use any positive evidence.
- Under `both`, only the sniff must succeed. A failed sniff is the hazard. LLDP is a supplement, so a down `lldpd` does not block removals.

Enforced by: `detect_sniff`, `detect_lldp`, `prep_iface`, `detection_sample_valid`, `store_detection`; `tests/unit.sh` §1ab, §1ac, §1aw.

### Every detected trunk is provisioned

**Rule:** dynavlan provisions every carrier-up interface that has a non-empty detected tag set.

Why: There is no trunk contest, no hysteresis, and no `select_trunk`. Two trunks that carry the same VLAN id get two distinct interfaces, such as `enp1s0.100` and `enp2s0.100`. For this reason every set after detection holds tokens, never bare VLAN ids (see "Token representation").

Enforced by: `run_detection`, `tag_tokens`; `tests/unit.sh` §1n, §1p.

### The sniff counts inbound frames only (FR-5a)

**Rule:** The sniff must capture inbound frames only (`tcpdump -Q in`).

Why: tcpdump also captures egress, and each owned VLAN sends tagged DHCP on its parent until it leases and then on renewal. If those frames counted, an owned VLAN would stay detected on its own traffic. Then detection-diff removal (FR-23) could never fire (evidence: context/decisions.md, 2026-07-25).

- If tcpdump lacks `-Q` support, the run refuses as a failed precondition. dynavlan never falls back to bidirectional capture.
- The probe is `tcpdump -Q in -d vlan`. It compiles the filter without opening the device, so it is non-mutating and needs no root.

Enforced by: `detect_sniff`, `tcpdump_supports_inbound`, `check_detect_deps`; `tests/unit.sh` §1ag.

### LLDP never contributes the native VLAN (FR-7a)

**Rule:** LLDP must not contribute the native VLAN, which `lldpctl` flags `pvid=yes`.

Why: The native VLAN is untagged on the wire. An interface for its tag never receives a frame, so it comes up, never leases, and stays dead (evidence: context/decisions.md, 2026-07-25).

- `lldp_tagged_vlans` drops the native VLAN. The exclusion applies to the LLDP source only. If the sniff sees tagged frames for that id, it is a real tagged VLAN and stays a candidate VLAN.
- `lldpctl -f keyvalue` puts no index in the key. The parse therefore pairs each `vlan-id` with its `pvid` by adjacency, and it is stateful.
- A block with no `pvid` key counts as tagged.
- The patterns match only the VLAN TLV's own subtree: `.vlan.vlan-id=` and `.vlan.pvid=yes`. They never match any key that merely ends in `.vlan-id=`. Why: the full lldpd key set is not documented, so a loose match depends on guesses about other keys.
- A loose match fails in two ways. A foreign `.vlan-id=` key inside a block flushes the real id as tagged before its `pvid` arrives, which rebuilds the dead native interface. The foreign key's value also becomes a candidate VLAN that is not on the trunk.

Enforced by: `lldp_tagged_vlans`, `detect_lldp`; `tests/unit.sh` §1i.

## Token representation

Every set after detection is a space-separated set of `iface.id` tokens: candidate VLANs, additions, removals, owned, and target. A token splits on its last dot.

- `tag_tokens`, `untag_tokens`, `tokens_for_iface`, `tok_iface` and `tok_id` convert between tokens and per-trunk bare ids.
- `compute_candidates` and `boot_removals` work on per-trunk bare ids.
- `distinct_ifaces` lists the trunks in a token set. Every mode uses it to find the trunks to loop over, including dark trunks.

### Interface-name contract (H6, M1)

**Rule:** A generated VLAN interface is named `<parent>.<id>` and must be a legal kernel name.

Why: The apply would reject an illegal name. A parent name that contains `.` cannot round-trip through the owned file.

- The name must be 15 characters or fewer (`IFNAMSIZ`). `tag_tokens` is the only `iface.id` constructor. It drops an over-long name with a warning.
- So a 15-character MAC-derived parent such as `enx001122334455` provisions nothing. Generated short names for such parents are deferred past 1.0.
- `discover_phys_ifaces` refuses a parent name that contains `.`, because `.` is the `<parent>.<id>` separator.
- Parent names may contain `-` and `_`. `iface_key` hex-escapes each non-alphanumeric byte, so `enp-1`, `enp_1` and `enp.1` never share a stash variable.
- Standard predictable and legacy NIC names satisfy both limits.

Enforced by: `tag_tokens`, `iface_key`; `tests/unit.sh` §1n. The `.` refusal in `discover_phys_ifaces` has no unit test.

## Reconcile policies

Boot, rescan, reapply and teardown all finish in the same `apply_change`. They differ only in how they compute the target.

Boot and rescan compute candidate VLANs and removals per trunk, in a loop over every relevant iface. They tag each trunk's ids to tokens and combine them into one token set. Then they make one `apply_change` call for the whole box, never one per trunk. Why: one `netplan try` window must cover every trunk's change together.

Before they combine, boot and rescan drop additions on two kinds of iface. The first is a trunk that this run prunes as carrier-down. The second is any iface that lacks carrier now (`ifaces_without_carrier`, `drop_iface_tokens`, M4). `--dry-run` drops additions on ifaces without carrier too, for preview parity. So all three modes skip additions on a dead parent. Why: additions come from tags sniffed before the carrier verdict. A new trunk that dies before the apply would otherwise get stanzas on a dead parent. Both modes call `warn_overlap` before their no-change return (L1).

### --boot (reconcile)

Boot ignores the return code of `run_detection` and branches on `DETECTED_TRUNKS`. Why: that code is non-zero only when `DETECTED_TRUNKS` is empty, so it cannot tell a probe failure from a quiet wire. Branching on it would abort the case FR-41 exists for: every owned trunk unplugged.

An empty detection blocks additions. An owned carrier-down trunk stays eligible for FR-41 pruning when `REMOVE_ON_CARRIER_LOSS=true`. If there is no default route and every owned trunk is down, `have_routing` fails and boot changes nothing.

1. **Pass 1.** Loop over the union of owned trunks and newly detected trunks. Per trunk, compute candidate VLANs = detected ∩ [MIN,MAX] − ignore − managed-elsewhere − owned on that trunk. Tag them to tokens. Stash each trunk's pass-1 carrier sample.
2. **Decide `need_pass2`.** It is true when `RESET_ON_BOOT=true`, because detection-diff removal needs a second sample. It is also true when `REMOVE_ON_CARRIER_LOSS=true` and an owned trunk was down at pass 1, because that sample is half of the carrier debounce. Otherwise boot stays single-pass, which is the all-up fast path.
3. **Pass 2** (only when `need_pass2`). Sleep `BOOT_SETTLE_SECONDS`. Re-detect only when `RESET_ON_BOOT=true`, because a carrier-only resample needs no new sniff. Then decide per trunk:
   - **Carrier up at pass 2:** detection-diff removal, only with `RESET_ON_BOOT=true`. `boot_removals` removes owned ids that are absent from both passes. An empty detection in either pass preserves. An `invalid` sample in either pass (H1) preserves with a warning.
   - **Carrier down at pass 2 (FR-41):** `carrier_removals` returns the trunk's full owned set for removal. Boot preserves instead when the knob is off, when pass-1 carrier was up (a flap), or when `have_routing` is false.
4. **Combine** all trunks' additions and removals into one token set. Run the count gate, then make one `apply_change` call.

For a carrier-down trunk, `have_routing` is the only safety gate. Why: the dead trunk may be the box's own uplink. The post-apply health check does not cover this case, because an empty route snapshot always passes.

Boot has no relocation branch. A trunk with carrier up and no tags is preserved, because that is detection uncertainty. A trunk moved to another NIC is two separate events. The old NIC goes carrier-down and is pruned. The new NIC is provisioned on its own evidence.

### --rescan (timer)

Additions are the per-trunk candidate VLANs over every iface in `DETECTED_TRUNKS`, tagged and combined.

Removals come from FR-41 only, and only when `REMOVE_ON_CARRIER_LOSS=true`. Rescan checks carrier on every owned iface, not only on detected ones. Why: a carrier-down owned trunk may report zero tags and be absent from `DETECTED_TRUNKS`.

- **Fast path:** the settle sleep runs only when an owned trunk is carrier-down and `have_routing` is true. An all-up box, or a down trunk with no healthy routing, adds no latency.
- **Settle:** sleep `BOOT_SETTLE_SECONDS` once for all down trunks.
- **Re-check routing:** check `have_routing` again before building any removal. If the uplink was lost during the settle, preserve everything. The health check cannot catch this case, because an empty route snapshot always passes.
- **Prune:** re-sample carrier on the down trunks. `carrier_removals` prunes each trunk that is still down. A trunk that recovered during the settle is preserved.

Additions and removals then combine into one token set. Rescan runs the count gate and makes one `apply_change` call.

### --reapply (FR-39)

`--reapply` runs no detection. Its target is the owned set, unchanged, across whatever trunks it spans.

- It refuses if the owned set is non-empty but yields no distinct ifaces.
- It generates a candidate config under `/run`. It applies only if `config_body_differs` reports a changed body.
- That comparison skips line 1, the version and build header. Why: the header carries a per-build id (FR-38), which would force an apply on every upgrade.
- It never adds or removes a VLAN. It bypasses the count gate, because zero additions is not growth and `fill` mode would trim.
- When the change is accepted, it waits for leases on the full owned set. Why: there are no additions to wait on, and a restart during re-DHCP would drop kept subnets.

Why it exists: a regeneration otherwise needs a change in the VLAN set. Without `--reapply`, a change to the generated stanza never reaches a box whose VLAN set is stable.

### --teardown (Group 6, D7)

`--teardown` is attended and runs from the console. It does these steps in order:

1. `main` branches before `check_preconditions`. Teardown needs root, `ip`, netplan and `netplan try`, not the detection tools (`check_apply_prereqs`).
2. An invalid config falls back to `config_defaults`, so a bad config never blocks recovery.
3. Take the run lock with the `--reapply` bounded wait. Hold it until exit.
4. Require both units to be disabled or masked, and inactive or failed (`teardown_check_posture`). An indeterminate state refuses.
5. Drain pending deletes.
6. Read the owned set. An unreadable owned set, or a `vlans:` file that it cannot recognize, refuses.
7. Call `apply_change "" "" "$owned" ""`. The empty candidate config goes through the normal health-gated `netplan try`. Deletes run only after an accept. Otherwise the prior file is restored.
8. After an accepted apply, drain again. For each owned link still present, print its exact `ip link delete` command, and return 1.

A non-accepted apply gives no delete advice. After teardown, the owned file defines no VLANs. `--dry-run` does not preview teardown.

### --dry-run

`--dry-run` uses the same per-trunk candidate-VLAN math as boot. It runs one pass over the union of owned and detected trunks.

- It previews an FR-41 carrier-down removal per trunk from one advisory sample, with no debounce. `have_routing`, computed once at the start, gates the preview.
- Detection-diff removals come only from a trusted sample (S2).
- It drops additions on any iface that lacks carrier now, as boot and rescan do (M4).
- The real count gate applies (S3). A refusal cancels additions and removals, prints the unchanged owned target, validates nothing, and returns 1.
- A quiet wire does not cause an early return (L9). The run still previews guarded pending-delete retries and the new-subnet state, and it validates.
- The pending-delete preview uses the route snapshot taken before detection, as the real drain does. The later snapshot feeds only the default-route guard preview (C1).
- It stages the netplan tree with `backend_stage_netplan_tree`: `/etc/netplan`, plus `/lib` and `/run` netplan YAML when present. It generates the candidate config there and validates. A failed copy returns 1 (L8).
- It prints the per-trunk diff with carrier state, a combined total, and the count gate. In routed mode it also prints the metric map and any conflict.
- It never applies, deletes, restarts, or writes the pending or seen records.
- Detection still brings NICs administratively up and leaves promiscuous mode on. This is disclosed, not restored.
- It returns non-zero on a validation fail (M3), a count-gate refusal, a base-tree copy failure, or a failed pending or managed query. Otherwise it returns 0, so `$?` works as a scripted preflight.

### --status

`--status` prints one row per owned or detected trunk. Each row shows carrier, configured, detected, ignored, out-of-range and managed-elsewhere ids (FR-35, L13).

- It gates its detection on `check_detect_deps` and returns non-zero if a tool is missing (M8).
- If `DETECT_INVALID` is non-empty, it marks detection unavailable or incomplete and returns non-zero (D5). Partial results still print.
- A failed managed-elsewhere query reads `unavailable` and returns 1. A quiet, valid wire returns 0.
- Each row also shows `owned-ignored` and `owned-out-of-range`: owned ids outside the current ignore or range policy. These print even when detection is unavailable (Group 5).

### Count gate (FR-12, FR-36)

Above `VLAN_WARN`, dynavlan warns. Above `VLAN_LIMIT`, it refuses by default and logs the refusal. In `fill` mode it keeps the lowest-numbered additions that fit the remaining slots.

- Fill orders additions by numeric VLAN id, then by interface name (`sort_tokens_by_id`, M7). Lexical order would put 10 and 100 before 2.
- A change with removals only always passes. The cap limits growth, never a shrink.

### The timer drop-in restates every monotonic trigger (FR-21a)

**Rule:** The timer drop-in must emit every monotonic trigger that the timer needs.

Why: In systemd, an empty assignment to any `On*Sec=` clears the whole monotonic trigger list. A timer left with only `OnUnitActiveSec` anchors on the last activation of `dynavlan-rescan.service`. With no prior activation it never elapses, and nothing logs an error (context/decisions.md, 2026-07-25).

- `render_timer_dropin` starts with an empty `OnUnitActiveSec=`. That also clears the base unit's `OnBootSec` and `OnActiveSec`.
- It then emits `OnActiveSec` (first fire, 2 minutes after timer activation) and `OnUnitActiveSec` (the interval). It replaces the base `OnBootSec` with `OnActiveSec` on purpose.
- First fire anchors on timer activation, not on kernel boot. Why: `install.sh` stops and restarts the timer on upgrade, long after any boot deadline.
- Symptom of a dead timer: `systemctl list-timers` shows `n/a` in every column, while the timer is `active` with `Result=success`.

Enforced by: `render_timer_dropin`, `do_reconfigure`; `tests/unit.sh` §1j. Hardware check: L3-24 in `dev/features/dynavlan-tests.md`.

## Apply and revert state machine

This chain decides whether a change can strand the box.

```
apply_change(target, additions, removals)
  snapshot default route (iface; metric too in routed mode)
  default_iface_in_removals            # refuse the whole reconcile, before any disk change (C1)
  [routed mode] plan per-VLAN metrics; refuse up front if any metric <= the uplink metric
  stop request? -> nothing applied
  backend_validate_candidate(target)   # isolated, see below; rc 1 = rejected, rc 2 = setup failure; nothing changed
  stop request? -> nothing applied     # a TERM during validation is honored before any live change
  backup current owned file            # failure = refuse: no safe target to converge back to
  backend_generate_config(target)      # live atomic write: same-dir mktemp 0600, fsync, rename (try reads it)
                                       # write fails -> restore the prior file, return 1, nothing applied
  backend_apply_with_revert            # the accept primitive below
  accepted:     prune backups -> delete removed VLAN links (only here) -> wait leases -> restart targets
  not accepted: converge disk back to the prior file; no deletes, no restarts
```

- **Isolated validation:** `backend_validate_candidate` stages the `/lib`, `/etc` and `/run` netplan YAML into a scratch root. It writes the candidate config there and runs `netplan generate --root-dir`.
- To write the candidate config, it points `NETPLAN_FILE` at the scratch root, then restores it. It always removes the scratch root under `SCRATCH_DIR`.
- **Warning:** any new early return in `backend_validate_candidate` must still restore `NETPLAN_FILE` and remove the scratch root. Otherwise the live apply writes into a deleted path.
- Validation tells "our YAML is bad" from "a base file is bad". A bad base file freezes dynavlan updates.
- Validation never regenerates the live `/run/systemd/network`. Why: `netplan try` backs up that runtime state. A backup that held the candidate config would make a revert restore it.
- **Lease wait:** one box-wide `LEASE_SETTLE_SECONDS` deadline polls all pending VLANs together (H5). A wait per VLAN in series could outrun the systemd start timeout and skip the restarts.
- **Not accepted:** the child may have reverted, failed early, or hit the wall-clock guard. dynavlan never assumes a completed revert (L6).
- **Residual link:** after a fail, a link that only the reverted candidate config created stays in the kernel. This is an accepted limitation (FR-43).

### The accept primitive (netplan try and a fifo)

`netplan try` applies first and reads stdin after. Its revert timer starts after the apply. A newline written early would wait in the pipe buffer, and netplan would consume it unconditionally. That would accept a change that the health check never saw.

**Rule:** The accept loop writes the confirming newline only when all four conditions below hold.

Enforced by: `backend_apply_with_revert`, `apply_settle_floor`, `health_check_eval`; `tests/unit.sh` §1c, §1y.

1. **Apply evidence.**
   - With additions, the first added VLAN's netdev must exist. That proves the apply began. A settle floor (`APPLY_FALLBACK_SETTLE`) then runs before any health sample.
   - A change with no additions (removal-only, or `--reapply`) has no in-kernel signal. `netplan try` does not delete removed netdevs, and a regeneration changes no kernel state.
   - Such a change anchors at t=0 and uses the larger `APPLY_NOEVIDENCE_SETTLE` floor (`apply_settle_floor`, C2). The floor makes the first health sample land after the apply, not on pre-apply routing.
   - Constraint: `APPLY_NOEVIDENCE_SETTLE <= TRY_TIMEOUT - 2*POLL_INTERVAL - HEALTH_CONSEC*POLL_INTERVAL`. With the current constants the ceiling is 22. Above it, a change with no additions could never accept.
   - `tests/unit.sh` §1y checks this ceiling. It also checks that `APPLY_NOEVIDENCE_SETTLE` exceeds `APPLY_FALLBACK_SETTLE`.
   - There is no positive completion signal. Parsing the `netplan try` prompt is fragile across versions and is not validated.
   - So the evidence for a change with no additions is the floor, liveness, consecutive health passes, and the window bound together.
   - dynavlan records the exit of `netplan try` on both the accept and fail paths, for audit only. It cannot cancel a newline already written.
2. **Liveness.** `netplan try` must still run at the accept instant. A dead `try` has reverted or failed, so dynavlan never accepts it.
3. **Health.** `HEALTH_CONSEC` consecutive health passes are required.
   - A pass means the snapshot iface still holds a default route at the minimum post-apply metric.
   - The check compares the iface only, because metric and gateway changes are normal DHCP events.
   - With several equal-metric uplinks, the check is set membership at the minimum metric (P3). A change in route listing order therefore cannot cause a false fail and a revert.
4. **Window bound.** No accept is allowed once `waited - first_evidence >= TRY_TIMEOUT - 2*POLL_INTERVAL`. Why: past that point a live `try` may be reverting. The revert restores routing, so health would pass and a buffered newline would accept a reverted change.

### Stop requests during an apply (D2)

**Rule:** Bash must not exit while `netplan try` can still revert.

Why: Both units run `KillMode=mixed`. A stop sends SIGTERM to the main Bash process only. systemd sends SIGKILL to a surviving `netplan try` as soon as Bash exits.

- **Trap scope:** inside `apply_change`, the TERM trap sets `STOP_REQUESTED=1` and closes the unaccepted fifo writer (`exec 9>&-`). The trap does nothing else.
- **Write atomicity:** a trap runs between commands, never inside the confirming `{ printf '\n' >&9; }`. So that write either already happened, which is an accept, or it fails.
- **Revert on EOF:** if the write fails, netplan sees EOF on stdin and reverts. This path is validated on hardware (evidence: docs/hardware-validation.md, Phase 3b).
- **Early TERM:** a TERM before the writer opens closes an unopened fd 9, and the later `exec 9>` reopens it. So dynavlan checks the stop flag again before launch and after the open.
- **Cleanup:** `backend_stop_cleanup` always closes fd 9 itself.
- **Bounded waits:** child waits are `kill -0` polls (`wait_child_gone`), never a bare `wait`. A trapped signal interrupts `wait` while the child still lives.
- **Deadline:** the cleanup deadline is `TRY_TIMEOUT + STOP_CHILD_MARGIN`. After it, Bash restores the prior file and exits, and systemd kills the leftover child.
- **Budget:** the nominal stop budget is 52 seconds, inside `TimeoutStopSec=60`. §1ao checks this inequality against the unit files.
- **Stop after accept:** dynavlan keeps the change and runs the removals. It skips `wait_leases`, `restart_targets` and the FR-40 pass.
- **Exit:** `main` returns 1 and does not call `maybe_restart_on_new_subnet`.
- **Catch-up:** a skipped restart is not guaranteed to happen later. It needs a still-unseen subnet and `RESTART_ON_NEW_SUBNET=true`.

Enforced by: `stop_trap_on`, `stop_trap_off`, `stop_requested`, `wait_child_gone`, `backend_stop_cleanup`; `tests/unit.sh` §1ao.

### Fifo behavior on a fail

On a fail, dynavlan holds the fifo write end open until `try` exits on its own timer. Why: this avoids an early stdin EOF on the normal path.

If the writer process dies during an apply, the write end closes and `netplan try` reverts on the EOF. This path is validated on hardware (evidence: docs/hardware-validation.md, Phase 3b).

An independent wall-clock guard of 3 × `TRY_TIMEOUT` bounds the whole interaction.

## Routed mode (FR-37, opt-in)

The default is full isolation. Every VLAN is DHCP address-only.

- All four of `use-routes`, `use-dns`, `use-ntp` and `use-domains` are `false`. With fewer, networkd pins DHCP-provided DNS and NTP servers as host routes.
- Every VLAN also carries `accept-ra: false`.
- With `VLAN_ROUTES=true`, the stanza sets `use-routes: true` and `route-metric: N`. DNS, NTP and domains stay declined.

### Metric assignment

**Rule:** Every caller must get the token-to-metric map from `plan_route_metrics`, once per run.

Why: A second call site that rebuilds the map from its parts drifts from the first without notice.

- **Kept tokens:** each reuses the metric read back from the owned file. The owned file is the state store, keyed by token, so two trunks that share a VLAN id get separate metrics.
- **New metrics:** these go to target tokens that lack a persisted metric, not to the additions.
- **Why not additions:** the two sets differ when an owned VLAN has no persisted metric, as in a move from isolated to routed mode. Assigning only for additions leaves the rest without a metric, and generation stops for good.
- **Order:** new metrics are next-free and ascending, in lexical full-token order within the batch. All trunks share one metric sequence.
- **Stability:** existing tokens never get a new number. Lexical token order is the only ordering mode.
- **Conflict:** if any assigned metric equals or beats the uplink's metric, dynavlan refuses before it touches disk. Why: the apply would cause a health fail and a revert loop.

Enforced by: `plan_route_metrics`, `assign_route_metrics`, `metric_conflict`, `backend_owned_metrics`; `tests/unit.sh` §1g.

### Isolation covers each channel separately (FR-14a)

**Rule:** Every generated VLAN must carry `accept-ra: false`, in routed mode and in isolated mode.

Why: The four `use-*` keys are `dhcp4-overrides` and bind DHCPv4 only. networkd accepts IPv6 RA by default on a non-router link. So a VLAN RA can install a SLAAC address, RDNSS resolvers, and a default route that no `use-*` key declines (evidence: context/decisions.md, 2026-07-25).

- This is a revert-safety matter, not only a confidentiality matter.
- `default_routes_tokens` samples `ip route show default`, which is IPv4 only. An RA default route through a VLAN is invisible to the health check and could never trigger a revert.
- The IPv4-only sample is correct only while `accept-ra: false` holds.
- If a VLAN may ever get an IPv6 default route, give the health check an `ip -6` arm in the same change.
- `link-local` stays at the netplan default, so the `fe80` addresses remain.

Enforced by: `backend_generate_config`, `default_routes_tokens`; `tests/unit.sh` §1o, §1au. Hardware check: L3-26 in `dev/features/dynavlan-tests.md`.

## Package lifecycle (debian maintainer scripts and install.sh)

The maintainer scripts (`debian/preinst`, `prerm`, `postinst`, `postrm`) and `install.sh` preserve the operator's unit posture across an install or upgrade (Group 2).

1. **Capture first.** Before anything is stopped or replaced, record each unit's enabled and active state in `/run/dynavlan/upgrade-state`.
2. **Record format.** The record has three validated fields and an `owner=` field, the dpkg parent pid.
3. **Ownerless records.** An ownerless record is reused only when it comes from an outgoing 0.4.1 to 0.4.15 `prerm` and its enablement matches the live state.
4. **Quiesce.** Stop the timer and verify that it stopped, from its live state, never from the record.
5. **Wait.** Always wait for the run lock, even when no timer exists.
6. **Restore.** On success or abort, restore each unit's enablement separately. Restart the timer only if it ran before.
7. **Retry.** Keep the record after a failed `postinst`. Why: dpkg retries configure without running `preinst` or `prerm` again.

`install.sh` stamps the build id into the script (FR-38). It enables the service and the timer for the next boot and never applies. One EXIT trap (`cleanup`) removes temp files and restores the timer.

Enforced by: `tests/lifecycle.sh`, folded into `tests/unit.sh` §1aq.

## Key invariants

### Never strand the box

**Rule:** Every failure path ends with no net change, a reachable uplink, and a log entry.

Why: The box may be remote and headless. A bad apply that breaks the uplink can need physical access to fix.

- The routing health check decides a revert, never an exit code.
- There is no fallback from `netplan try` to a bare `netplan apply`.

Enforced by: `apply_change`, `backend_apply_with_revert`; `tests/unit.sh` §1ak, §1ao, §1av.

### One file owned

**Rule:** dynavlan writes only `/etc/netplan/90-dynavlan.yaml` and never reads base config for assumptions.

Why: An operator's own netplan files stay theirs (FR-13).

- Exception: validation, the overlap check and `--dry-run` read the merged netplan tree, but only to detect conflicts.
- A validation error in a base file freezes dynavlan updates. dynavlan never "fixes" a base file.

Enforced by: `backend_generate_config`, `backend_validate`, `backend_validate_candidate`; `tests/unit.sh` §1av.

### Discover, don't assume

**Rule:** Never hardcode interface names, VLAN ids, the native VLAN, or base filenames.

Why: Discovery trusts only live kernel state and the wire.

Enforced by: `discover_phys_ifaces`, `run_detection`; code review.

### Deletes only after accept

**Rule:** `ip link delete` for a removed VLAN runs only after the change is accepted.

Why: A revert restores files only. It cannot recreate a destroyed interface.

Enforced by: `apply_change`, `backend_remove_vlan`; `tests/unit.sh` §1ak, §1ao.

### A failed delete is retried, not forgotten (M5)

**Rule:** If an accepted change's `ip link delete` fails, dynavlan records the token and retries it on the next run.

Why: After an accept the stanza is already gone from the owned file. A failed delete would leave the live interface and its subnet until reboot. The next run could not tell that orphan from an external VLAN.

- **Record:** `apply_change` writes the token to `/run/dynavlan/pending-delete`. The file is on tmpfs, so it lasts until reboot, as the interface does.
- **Drain:** `drain_pending_deletes` runs at the start of every `do_boot` and `do_rescan`, and retries each record.
- **Current state first:** the record proves past ownership only. Each drain therefore checks current state before it deletes a token.
- **Default route:** if the token is now the box's default-route interface, the drain preserves it with a warning (D1).
- **Defined elsewhere:** if any key in the current netplan config now defines the token, the drain preserves it with a warning. The check uses `backend_netplan_vlan_tokens` (L7).
- **Query result:** `backend_netplan_vlan_tokens` returns 0 when the query ran, even with an empty result. It returns non-zero only when the query failed. Every safety caller must check it.
- **Query failure:** if that query fails, the drain preserves the whole record, attempts nothing, and returns non-zero.
- **Persist failure:** a later failure to rewrite the survivors also returns non-zero. That direct `>` write can truncate the file, so a still-failing delete may be lost until reboot. The drain logs this.
- **Abort:** either failure aborts `do_boot` or `do_rescan` before detection.

Enforced by: `record_pending_delete`, `drain_pending_deletes`, `backend_netplan_vlan_tokens`; `tests/unit.sh` §1ae, §1aj.

### Never remove the default-route interface (C1)

**Rule:** If the current default-route interface is a removal, `apply_change` refuses the whole reconcile before any disk change.

Why: The delete runs after `netplan try` commits. During the try the VLAN is still up, so the health check passes. Without this guard the delete would remove the default egress with no revert.

- `default_iface_in_removals` compares `snapshot_default_route` against the removal tokens as exact matches.
- Only routed mode can reach this guard. In isolated mode the default route is always the base uplink, so the guard does nothing.
- The guard refuses the whole reconcile, not part of it. This matches the metric-conflict and zero-detection guards.
- Nothing changes until the operator moves the default route off that VLAN.
- `do_dryrun` previews the refusal.

Enforced by: `default_iface_in_removals`, `apply_change`, `do_dryrun`; `tests/unit.sh` §1aa.

### Zero detection never removes everything (FR-41)

**Rule:** A detection that finds nothing blocks additions and never causes a removal by itself.

Why: Carrier is a separate, authoritative signal, so carrier-down pruning still runs. `run_detection` returns non-zero only when it saw nothing. So "failed" and "saw nothing" share one return code, and the modes branch on `DETECTED_TRUNKS` instead.

Two independent gates keep zero detection from removing everything:

- Detection-diff removal needs a VLAN absent across two passes on a carrier-up trunk.
- Carrier-down removal needs `have_routing`. `have_routing` needs a physical NIC with carrier, so it is false on a box where every port is dark.

Enforced by: `boot_removals`, `have_routing`, `do_boot`; `tests/unit.sh` §1d, §1s.

### Carrier-down removes; carrier-up with no tags preserves (FR-41)

**Rule:** Prune a trunk's owned set only when carrier stays down across two samples and routing is healthy.

Why: A dead port cannot pass frames, so carrier-down is authoritative kernel evidence. A carrier-up trunk with no tags may only be a detection miss, such as STP or LLDP not yet converged, or a silent VLAN.

- A trunk with carrier up and no tags across both passes is preserved, never removed on that basis alone.
- A trunk that stays carrier-down across the two-sample debounce loses its entire owned set on that trunk.
- The prune needs `REMOVE_ON_CARRIER_LOSS=true` (the default) and `have_routing`.
- If the dead trunk is the box's only uplink, `have_routing` fails and the trunk is preserved. A removal there would be doomed.
- One up sample during the debounce (a flap) preserves.
- `have_routing` needs a default route whose egress iface has carrier. It also needs at least one physical NIC with carrier.
- Why the physical clause: a tun or WireGuard default reports carrier whenever it is up. It would make a dark box look routable.

Enforced by: `carrier_removals`, `have_routing`; `tests/unit.sh` §1r, §1s, §1t, §1u. Hardware check: L3-30 (revised) in `dev/features/dynavlan-tests.md`.

### Side effects are change-gated

**Rule:** If there is no change, dynavlan runs no apply, no lease wait, and no restarts.

Why: A restart interrupts the monitoring agent, and every apply opens a revert window.

- Restart targets are the nominated snaps and services. A failed restart is a warning, never fatal.

Enforced by: `do_boot`, `do_rescan`, `apply_change`, `restart_targets`; `tests/unit.sh` §1aw.

### The new-subnet restart (FR-40)

**Rule:** After `apply_change` returns, `--boot` and `--rescan` run `maybe_restart_on_new_subnet` on every exit path.

Why: A new global IPv4 subnet can appear anywhere, including on the base uplink. Its appearance does not depend on whether VLAN provisioning succeeded.

- This is the only restart trigger that the VLAN token set does not gate.
- It can fire when the VLAN apply failed and reverted, or when the `VLAN_LIMIT` gate refused it.
- It restarts the targets at most once per run. `RESTARTED_THIS_RUN` removes the duplicate with a VLAN-driven restart.
- `apply_change` itself is not involved.

Enforced by: `maybe_restart_on_new_subnet`, `current_subnets`, `read_seen`, `write_seen`; `tests/unit.sh` §1af, §1ar.

### A total restart failure keeps the subnet unseen (M6, L10)

**Rule:** If no target restarted, the new subnet stays out of the seen set, so the next run retries.

Why: The seen set must never claim a subnet that no agent was restarted to pick up.

- `restart_targets` sets `RESTART_NONE_SUCCEEDED_THIS_RUN` only when no target restarted at all.
- A partial success consumes the subnet. A subnet cannot be mapped to one target.
- Why: if any failure blocked the subnet, one broken target would restart the working agents on every timer run.
- A transient total failure, such as snapd or systemd briefly busy, is still retried.
- In the common single-target config, the two rules give the same result.
- The flag also covers a failed restart inside `apply_change`.
- With no restart targets configured, two holds apply together (L10). `restart_targets` does not set `RESTARTED_THIS_RUN`.
- `maybe_restart_on_new_subnet` also explicitly keeps new subnets unseen when no target is configured.
- So a target configured later gets one catch-up restart.

Enforced by: `restart_targets`, `maybe_restart_on_new_subnet`; `tests/unit.sh` §1af, §1ar.

### State lives in the owned file

**Rule:** All persistent configuration state lives in the owned file.

Why: With no sidecar state file, nothing can drift out of step with the owned file.

- The owned token set, across any number of trunks, is read back from the owned file.
- Routed-mode metrics, keyed by token, are read back from the same file.
- There are no sidecar config or state files and no persisted "selected trunk".
- The FR-40 seen-subnet set is an exception in kind only. It is runtime scratch in `/run/dynavlan/seen`, on tmpfs and wiped on reboot. It never touches the owned file.

Enforced by: `backend_owned_vlans`, `backend_owned_metrics`; `tests/unit.sh` §1o.

### Config is strict and isolated (H2)

**Rule:** An invalid config value refuses the whole run, and the config file is parsed, never sourced.

Why: A config file must not run code or override an internal or safety variable. The config surface is exactly the documented keys.

- The config file must be root-owned and not writable by group or other.
- `config_load_file` honors only allowlisted `KEY=value` lines for the keys in `CONFIG_KEYS`.
- An unknown or protected key, or a line that is not an assignment, refuses the run.
- Values are assigned as inert literals with `printf -v`.
- So the config cannot override `NETPLAN_FILE`, `TRY_TIMEOUT`, `ver`, `PATH`, or any other internal variable.
- Keep `CONFIG_KEYS` in step with the defaults in `config_defaults`.

Enforced by: `load_config`, `config_load_file`, `config_allowed_key`, `config_normalize_value`; `tests/unit.sh` §1z, §1as.

### Logs are the console

**Rule:** Every decision leaves a log entry.

Why: Nobody is meant to log in to the box. dynavlan logs by level to stderr, and journald stores it under the identifier `dynavlan`.

Enforced by: `log`, `level_num`.
