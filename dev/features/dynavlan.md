# dynavlan: technical design

Owns: the architecture, structure, sequencing, seams, module decomposition, and systemd and install layout of dynavlan, with the design decisions and their rationale. Does not hold requirements (docs/dynavlan-PRD.md), logic flow and invariants (dev/SKELETON.md), per-function purposes (dev/CODEMAP.md), or dated project history (context/decisions.md).
Maintain: update when the architecture, a seam, or a design decision changes. To supersede a decision, add a new dated Decision note; do not rewrite the old one.

The PRD's FR, NFR and AC IDs are the source of truth for behavior. This doc uses the terms that dev/SKELETON.md defines in its "Terms" section, with the same meanings. Each section describes the current design first. History and reasons sit in labeled **Decision** and **Rationale** notes. The companion test plan is `dev/features/dynavlan-tests.md`.

Section numbers are stable, because the script and other docs cite them (for example "design §7").

## 1. Implementation decisions

| Decision | Choice | Details |
|----------|--------|---------|
| Language | bash | Below |
| Code layout | One self-contained file, no build step | Below |
| Timer interval | Static systemd timer plus a drop-in synced from config | Below; §11 |
| Two-pass boot state | Held in process, within one `--boot` run | Below |
| Network backend | A partial netplan seam; netplan is the only implementation | §4 |
| Config format | `/etc/dynavlan.conf`, parsed against an allowlist, never sourced (H2) | Below |

**Language: bash.**
- bash needs no runtime beyond the shell. It does not couple to an interpreter version, so it ports across distros at the shell level.
- The job is orchestration of `netplan`, `ip`, `tcpdump` and `lldpctl`, which bash does naturally.
- The concurrency hazards of bash (the run lock and the fifo) stay inside a few functions (§7, §9).

**Code layout: one file.** All script code lives in `./dynavlan`, which installs to `/usr/local/sbin/dynavlan`. Tests source the file, because `main` is guarded by `BASH_SOURCE` (dev/CODEMAP.md). The project AGENTS.md sets the style that follows from this: expanded guards over dense one-liners.

**Timer interval.** systemd timers are static files. `dynavlan --reconfigure` writes `RESCAN_MINUTES` into `/etc/systemd/system/dynavlan.timer.d/interval.conf`, then runs `systemctl daemon-reload`. The install also runs `--reconfigure`. After an edit to `RESCAN_MINUTES`, run `--reconfigure` again.

Rationale: a static timer avoids a self-rescheduling loop and a long-running daemon. The PRD chose a oneshot service plus a timer.

**Two-pass boot state.** Boot detects, sleeps `BOOT_SETTLE_SECONDS`, detects again, and removes only VLANs absent from both passes (FR-23). Shell variables hold both samples. Nothing persists, and no state crosses invocations. Rescan needs no such state, because its only removal path is carrier-down pruning (FR-41).

**Config format.** The config is commented `KEY=value` lines. `config_load_file` parses it line by line against the allowlist of documented keys (H2, 2026-08-04). The file is never sourced. The full rule is in dev/SKELETON.md, "Config is strict and isolated (H2)".

Rationale: a config line can then set only a documented key. It can neither run code nor override an internal or safety variable. The schema matches PRD §8.

`COMPATIBILITY.md` is the 1.x contract for the frozen surfaces: config keys, generated YAML, CLI flags and exit codes. `docs/exit-codes.md` lists the exit codes per mode.

## 2. Architecture: two layers

```
+-------------------------------------------------------------+
|  CORE (distro-agnostic)                                     |
|  config parse/validate · interface discovery · sniff/lldp  |
|  detection · filter/exclude/candidates · reconcile logic · |
|  health-check evaluation · logging · run lock · entrypoints|
+-------------------------------------------------------------+
                         | calls (most netplan access, not all: see §4)
                         v
+-------------------------------------------------------------+
|  BACKEND FUNCTIONS (partial seam): netplan implementation   |
|  list_managed_vlans · generate_config · validate ·          |
|  apply_with_revert · remove_vlan · owned_vlans/metrics      |
+-------------------------------------------------------------+
```

The core holds the decision logic. The `backend_*` functions hold most of the netplan-coupled code, but not all of it. The core still calls `netplan`, `ip` and the owned file directly in the places that §4 lists.

A port to another stack (NetworkManager, systemd-networkd directly, or ifupdown) would implement the `backend_*` operations. It would also need those direct dependencies abstracted first.

## 3. Ownership model

dynavlan owns a namespace of VLAN definitions. It never modifies a definition outside that namespace.

- **netplan:** the namespace is the owned file, and every other netplan file is excluded (FR-13).
- **NetworkManager (sketch):** the namespace would be the `dynavlan-*` connections.
- **networkd-direct (sketch):** the namespace would be the `90-dynavlan.*` unit files.

Exclusion (FR-10) means "every VLAN managed outside our namespace". The core queries it through the backend. The invariant itself is in dev/SKELETON.md, "One file owned".

## 4. Backend functions: a partial seam

Each operation is a bash function named `backend_<op>`. Netplan is the only implementation. The table gives the capability that each operation stands for; operation names drop the `backend_` prefix.

The six rows are the operations that matter to an apply. Other `backend_*` helpers exist, such as `backend_owned_metrics`, `backend_netplan_vlan_tokens` and `backend_stop_cleanup` (dev/CODEMAP.md, "Backend functions"). The NetworkManager and networkd-direct columns are sketches, not designs.

| Operation | Contract | netplan implementation | NM (future) | networkd-direct (future) |
|-----------|----------|------------------------|-------------|--------------------------|
| `list_managed_vlans` | Bare VLAN ids managed outside our namespace on one given trunk. This is the exclusion source, per trunk, because ids are scoped to their trunk. | `netplan get network.vlans` ∪ `ip -d link show type vlan`, filtered to that iface, minus our own tokens on it | `nmcli -g … con show` VLANs ∪ `ip link` | parse other `*.netdev` ∪ `ip link` |
| `owned_vlans` | The tokens currently in our namespace, across every trunk (the known set) | parse the stanza headers of `90-dynavlan.yaml` | our `dynavlan-*` connections | our `90-dynavlan.*.netdev` |
| `generate_config` | Write our namespace atomically so that it defines exactly the given VLAN set | atomic write of `90-dynavlan.yaml` (FR-16) | `nmcli con add/mod` | write `.netdev` and `.network` |
| `validate` | Validate the candidate config without applying it; tell our error from a base-file error | `netplan generate` (FR-17) | `nmcli con … --check` | `networkctl` verify or `systemd-analyze` |
| `apply_with_revert` | Apply, run the caller's health check, keep on a pass, else auto-revert | `netplan try` driven through a fifo (FR-18, §9) | native `nmcli` checkpoint with a rollback timeout | hand-rolled snapshot, apply, timer and revert |
| `remove_vlan` | Remove a VLAN from our namespace and tear down the live interface | file edit plus `ip link delete` (FR-24) | `nmcli con delete` | remove the units plus `ip link delete` |

**Direct dependencies outside the `backend_*` functions.** These make the seam partial:
- the netplan version gate and the `netplan try --help` probe (`check_netplan_version`, `check_preconditions`, `check_apply_prereqs`);
- `backup_current` and `restore_prior`, which operate on the owned file path;
- the `NETPLAN_FILE` swap in `--dry-run`, which points the generator at the staged tree;
- interface discovery, link up, promiscuous mode and carrier reads (`ip`, `/sys`);
- route snapshots and the health check (`ip route show default`);
- the detection tools (`tcpdump`, `lldpctl`).

**Revert capability varies by backend.** This is the one hard portability item. netplan has `netplan try`. NetworkManager has native checkpoints, which are cleaner. networkd-direct and ifupdown have neither, so a port must hand-roll the revert. The core's `apply_with_revert` contract is "apply with a health-gated auto-revert", so the core does not depend on the mechanism.

**Decision: no `backend_detect` yet.** A startup `backend_detect` would read `/etc/os-release` and probe for `netplan`. It would be the entry point of the seam. The script does not have it, because the backend is hardcoded to netplan, the only implementation. The stub lands with a second backend. Until then there is no backend-selection config.

## 5. Module decomposition

The script is one file, divided into sections. dev/CODEMAP.md gives one row per function, in file order. This table groups the functions by responsibility, so a maintainer can see which module a change touches.

| Module | Functions | Responsibility |
|--------|-----------|----------------|
| Entry and dispatch | `main` | Parses the mode flag, takes the run lock, and dispatches to the mode function. |
| Config | `load_config`, `config_load_file`, `parse_vlan_ignore` | Sets defaults, parses `/etc/dynavlan.conf` against the allowlist (H2), and validates every value. A bad value refuses the run. |
| Preconditions | `check_preconditions`, `check_detect_deps`, `check_apply_prereqs`, `have_cmd`, `tcpdump_supports_inbound` | Gate a run on root, tools and netplan capability (FR-0, M8). |
| Discovery and detection | `discover_phys_ifaces`, `prep_iface`, `has_carrier`, `detect_sniff`, `detect_lldp`, `detect_iface`, `run_detection` | Find physical NICs, bring them up in promiscuous mode, and detect tagged VLANs on every carrier-up iface. |
| Candidate VLANs and tokens | `compute_candidates`, `emit_tokens`, `tok_iface`, `tok_id`, `tag_tokens`, `untag_tokens`, `tokens_for_iface`, `distinct_ifaces`, `drop_iface_tokens`, `ifaces_without_carrier` | Compute per-trunk candidate VLANs as bare ids, convert them to tokens, and drop additions on dead parents. |
| Removal decisions | `boot_removals`, `carrier_removals`, `have_routing` | Decide detection-diff removals (FR-23) and carrier-down removals (FR-41), with the routing pre-condition. |
| Count gate | `vlan_guard`, `limit_fill`, `gate_vlan_count` | Warn, refuse, or fill over the box-wide combined additions (FR-12, FR-36). |
| Routed mode | `plan_route_metrics`, `assign_route_metrics`, `map_ids`, `map_filter`, `metric_conflict`, `backend_owned_metrics`, `snapshot_default_metric` | Assign per-token route metrics and refuse a metric that would beat the uplink (FR-37, §10). |
| Backend | `backend_*` | The partial storage and apply seam (§4). |
| Apply orchestration | `apply_change`, `backup_current`, `restore_prior`, `prune_backups` | Take one change through validation, the live write, and accept or revert (§7). |
| Health check | `snapshot_default_route`, `post_apply_health`, `health_check_eval`, `default_iface_in_removals` | Snapshot the default route before an apply and judge it after (§8). |
| Pending deletes | `pending_deletes`, `write_pending_deletes`, `record_pending_delete`, `drain_pending_deletes` | Record a failed post-accept delete and retry it on the next run (M5). |
| Side effects | `wait_leases`, `restart_targets`, `maybe_restart_on_new_subnet`, `current_subnets`, `read_seen`, `write_seen` | Wait for leases and restart targets after an accepted change; run the new-subnet restart (§11a). |
| Modes | `do_boot`, `do_rescan`, `do_dryrun`, `do_status`, `do_reconfigure`, `do_reapply`, `config_body_differs`, `do_teardown` | One function per mode (§6). |
| Status display | `ids_in_ignore`, `ids_out_of_range` | List detected ids inside `VLAN_IGNORE` or outside `[MIN,MAX]`, per trunk (M8, FR-35). |
| Logging | `log` | Leveled logging to the journal under the identifier `dynavlan`, with start and end lines. |

### Design notes on the modules

- **`main`** dispatches `--boot`, `--rescan`, `--dry-run`, `--status`, `--reconfigure`, `--reapply` and `--teardown`. The lock policy per mode is in dev/SKELETON.md, "Run lifecycle".
- **`parse_vlan_ignore`** accepts canonical ids and `low-high` ranges, separated by commas or whitespace. Spaces around a comma are fine. An empty comma element at the start, middle or end refuses, and so does a leading zero.
- **`have_cmd` and `tcpdump_supports_inbound`** are the `command -v` presence test and the tcpdump `-Q in` probe. Tests stub them.
- **Detection cost.** `prep_iface` brings every NIC up first. Then one shared carrier deadline runs, and the sniffs run concurrently in one window. So detection cost does not grow with the port count (dev/SKELETON.md, "Detection").
- **`detect_sniff`** is a passive 802.1Q capture with a minimal snaplen. It never writes frames to disk. `detect_iface` combines the enabled methods for one iface.
- **No trunk selection.** `run_detection` sets `DETECTED_TRUNKS` to every iface with a non-empty tag set. There is no trunk contest, no hysteresis, and no `select_trunk` (dev/SKELETON.md, "Every detected trunk is provisioned").
- **Pure helpers for unit tests.** `boot_removals(owned, pass1, pass2)` holds the per-trunk removal combination (tests/unit.sh §1d). `carrier_removals` mirrors its shape (§1r).
- **Count gate helpers.** `vlan_guard(n, warn, limit)` returns `OK`, `WARN` or `OVER`. `limit_fill(adds, slots)` returns the lowest-N subset (§1f). `gate_vlan_count` applies the `VLAN_LIMIT_MODE` policy.
- **Token helpers** convert between the token domain and the per-trunk bare-id domain of `compute_candidates` and `boot_removals`. `distinct_ifaces` drives the per-trunk loop in every mode (tests/unit.sh §1n).
- **`drop_iface_tokens`** removes every token on the listed ifaces from a token set (§1w).
  Rationale: detection checks carrier once, then sniffs for `SNIFF_SECONDS`. A trunk that dies during the sniff keeps its tags. Without the drop, one apply would create new VLANs on the trunk while it tears down the old ones.
- **`ifaces_without_carrier`** returns the ifaces of addition tokens that lack carrier now (§1ad, M4). `do_boot`, `do_rescan` and `do_dryrun` always add them to the `drop_iface_tokens` set.
  Rationale: one carrier sample is enough here. A declined addition fails toward no change, and the next rescan adds it again; only a removal needs a debounce. The drop covers a newly detected trunk that is not yet owned and dies between detection and apply. The carrier-down removal path covers owned trunks only, so it misses that case.
- **`apply_change`** takes the change for the whole box, across any number of trunks. An optional fourth argument overrides the set that the lease wait covers. `--reapply` uses it to wait on the full owned set, because it has no additions.
- **`restart_targets`** restarts `RESTART_SNAPS` with snap, then `RESTART_SERVICES` with systemctl. It skips a missing or failed target. It sets `RESTART_NONE_SUCCEEDED_THIS_RUN` only on a total failure (M6).
- **`prune_backups`** keeps the newest `BACKUP_KEEP` backups.
- **`do_status` and `do_dryrun`** report carrier state per owned trunk (FR-41). `do_dryrun` also previews a carrier-down removal.
- **Missing-VLAN clocks** live in `/run/dynavlan/missing-since`, one `TOKEN UPTIME_SECONDS` line per owned VLAN that a trusted sample missed. The rule, the record and the review findings are in dev/features/missing-vlan-removal.md (tests/unit.sh §1az).
- **Pending deletes** live in `/run/dynavlan/pending-delete`. The record and the drain rules are in dev/SKELETON.md, "A failed delete is retried, not forgotten (M5)" (tests/unit.sh §1ae, §1aj).

## 6. Control flow per mode

dev/SKELETON.md, "Reconcile policies", owns the step-by-step flow of each mode. This section keeps the design reasons behind that flow.

### --boot (FR-22, FR-23, FR-41)

Flow: dev/SKELETON.md, "--boot (reconcile)". Boot loops over the union of owned and detected trunks, combines every trunk's change into one token set, and makes one `apply_change` call.

- **Rationale: boot ignores the return code of `run_detection`.** That code has one non-zero case, which fires only when `DETECTED_TRUNKS` is empty. So it cannot tell a probe failure from a quiet wire. An abort on it would fire on the case FR-41 exists for: every owned trunk unplugged. It would also log "detection failed" for an ordinary quiet trunk.
- **Rationale: a carrier-only pass 2 runs no sniff.** Boot stashes each trunk's pass-1 carrier sample in a `_c1_<trunk>` variable. A carrier-only resample reads `/sys` and the owned set, never detection. A fresh sniff there would add only latency.
- **Rationale: `have_routing` is the only gate on a carrier-down trunk.** The dead trunk may also be the box's own uplink. An uplink that is already missing leaves the pre-apply route snapshot empty. An empty snapshot passes the health check unconditionally (AC-12), so the health check cannot catch this case (§7).
- **Rationale: no relocation branch.** A trunk with carrier up and no tags is preserved, because that is detection uncertainty. A carrier-down trunk is pruned by FR-41 once routing is healthy. There is nothing to relocate to, because every other tagged trunk is already provisioned on its own evidence.

### --rescan (FR-21, FR-41)

Flow: dev/SKELETON.md, "--rescan (timer)". Rescan adds candidate VLANs on every detected trunk; its only removals are carrier-down prunes.

- **Rationale: carrier is checked on every owned iface.** A carrier-down owned trunk reports zero tags, so it is absent from `DETECTED_TRUNKS`.
- **Rationale: the fast path.** The settle sleep runs only when an owned trunk is down and `have_routing` is true. An all-up box pays nothing extra. A down trunk with no healthy routing only logs a preserve warning.
- **Rationale: `have_routing` is checked twice.** The first check decides whether to sleep at all. The second check, after the settle, decides whether to remove. Without it, an uplink lost during the settle would let a removal through. An example is a switch reboot that takes both ports. The empty pre-apply snapshot would make the health check pass, and the removal would be accepted on a box with no routing.

### --reapply (FR-39)

Flow: dev/SKELETON.md, "--reapply (FR-39)". `do_reapply` regenerates the owned set with the running build and applies only if `config_body_differs` reports a changed body.

- **Rationale: no detection.** `--reapply` pins its trunks to `distinct_ifaces` of the owned tokens. A detection pass could silently change which trunks are in scope.
- **Rationale: a blocking lock.** `--boot` and `--rescan` run again next cycle, so a skipped run is harmless there. `--reapply` is an operator command, so it waits for the run lock instead of skipping.

### --dry-run (FR-34, FR-41)

Flow: dev/SKELETON.md, "--dry-run". Dry-run runs the boot candidate math in one pass and validates, but never applies.

- **Validation tree.** Dry-run stages a copy of the real netplan tree with `backend_stage_netplan_tree`, the same helper that `apply_change` uses. It overlays the candidate config on the copy, and `backend_validate` runs `netplan generate` there. So validation sees the base files too.
  Rationale: dry-run then surfaces a base-file freeze (FR-17, risk R-5) instead of hiding it.
- **Carrier-down preview.** Dry-run takes one advisory carrier sample per trunk, with no debounce, because nothing applies. When routing is unhealthy, it prints a note that a carrier-down teardown is suppressed.
- **Lock interaction (review round 4).** Dry-run tries the run lock (FR-30) without blocking. If the lock is free, dry-run holds it for the preview. A timer rescan that lands during the preview then skips and retries next cycle. If the lock is held, dry-run does not block the operator. It warns that the preview may show a mid-change state, and it continues read-only.

### --teardown (FR-42, Group 6, D7)

Flow: dev/SKELETON.md, "--teardown (Group 6, D7)". Teardown is an attended removal of owned network state.

- **Decision: reuse `apply_change` with an empty target.** A shell recipe would duplicate the backup, restore, health and pending-record logic. An adversarial review found concrete defects in such a recipe.
- **Packaging side.** On `prerm remove`, the package quiesces: it verifies the timer stop and waits for the run lock. Then it disables the timer and the boot service, and verifies that. On `postrm purge`, the package removes the conffile, the journald drop-in, and `interval.conf`. It removes the timer drop-in directory only if the directory is empty.

### --status (FR-35, FR-41, M8)

Flow: dev/SKELETON.md, "--status". Status prints one row per owned or detected trunk.

- **Rationale: detection is gated on `check_detect_deps` (M8).** Without the gate, a suppressed missing-tool failure would print `detected trunks: [none]` and exit 0. That looks exactly like a quiet wire. With the gate, status prints `detected trunks: unavailable` and returns non-zero.
- **Static fields need no tools.** The owned set, trunks, carrier and config still print when detection is unavailable. So do the `owned-ignored` and `owned-out-of-range` fields. The detected-id fields do not change.
- **Decision: no persisted last-run record.** Status prints a `journalctl -t dynavlan` hint for run history. A last-run record is deferred.

### --reconfigure

`--reconfigure` renders the `dynavlan.timer` drop-in from `RESCAN_MINUTES`, then runs `systemctl daemon-reload`. For the drop-in's trigger rules, see dev/SKELETON.md, "The timer drop-in restates every monotonic trigger (FR-21a)".

## 7. Apply and revert state machine

This chain runs under the run lock (FR-30). dev/SKELETON.md, "Apply and revert state machine", owns the sequence and every failure branch.

In outline, `apply_change` does these steps:
1. Snapshot the default route.
2. Run the up-front guards: the default-route VLAN guard (C1) and, in routed mode, the metric conflict check.
3. Validate the candidate config in an isolated scratch root (FR-17).
4. Back up the owned file, then write the candidate config live and atomically (FR-16).
5. Apply with `netplan try` and accept or revert (FR-18, §9).
6. On an accept only: prune backups, delete removed VLAN links (FR-24), wait for leases, and restart targets (FR-27, FR-28).
7. On any other outcome: converge the disk back to the prior file, with no deletes and no restarts.

Every failure path ends with no net change, a reachable uplink, and a log entry (dev/SKELETON.md, "Never strand the box"). If the process dies anywhere, the kernel releases the run lock, because a file descriptor holds it. `netplan try` then reverts on its own timer.

**Rationale: `have_routing` sits in front of the chain, not inside it.** FR-41 adds one pre-condition before `apply_change` is called. `have_routing` decides whether a carrier-down trunk's VLANs are proposed for removal at all. The chain itself does not change.

The post-apply health check is not a backstop for this pre-condition. The health check reverts a removal that breaks routing. `have_routing` guards the case where routing is already broken before the apply. There the pre-apply snapshot is empty, and an empty snapshot passes unconditionally (AC-12). So the two layers cover adjacent cases, not the same case twice. For this reason the modes evaluate `have_routing` immediately before they build the removal set, not once at the start of the mode.

**Rationale: a failed `restore_prior` is loud (review round 4).** `restore_prior` converges the disk to the prior file on every failure or revert path. It checks its copy-back. On failure it logs `err` and names the surviving backup path. A failed restore leaves the disk holding the reverted config while the live state is the prior one. The next run would then read a wrong owned set. At that point, a loud log with the manual-recovery path is the only safe remedy.

## 8. Health check (FR-18)

The health check decides whether a change is accepted or reverted. The accept rule that uses it is in dev/SKELETON.md, "The accept primitive", condition 3. This section keeps the design of the check itself.

- **Snapshot.** `snapshot_default_route` returns only the interface of the lowest-metric IPv4 default route, or empty if there is none. It captures no gateway. `snapshot_default_metric` reads the metric separately, for the routed-mode conflict check.
- **Pass rule.** The check passes when a default route exists and the snapshot iface holds a default at the lowest post-apply metric. `post_apply_health` samples the routes, and the pure `health_check_eval` decides.
- **A spurious lower-metric default fails.** Suppose a default with a lower metric appears on a different iface after the apply. Then the lowest-metric default has left the base uplink, so the check fails and the change reverts.
- **Empty-snapshot rule (AC-12).** An empty snapshot means there is no uplink to protect. The evaluator then passes unconditionally, whatever the post-apply routes are. Isolated VLANs add no default route (FR-14), so nothing is missed. In routed mode the metrics are assigned, but with an empty snapshot the check does not constrain a new default. dynavlan never reverts only because the box independently had no uplink.

**Decision: compare the interface only.** The check never compares the metric or the gateway.
Rationale: a metric or gateway change on the same iface is a normal DHCP event. Such a change must not cause a revert.

**Decision: gateway reachability is optional and non-fatal.** dynavlan does not probe the gateway today. If a probe is added, it must use ARP and must never fail the check by itself. Never use ICMP.
Rationale: sites often filter ICMP, which would cause false reverts.

**Dependency on isolation.** In isolated mode the check is valid because FR-14 gives generated VLANs no default route. So the snapshot and the post-apply sample reflect the base uplink alone. Routed mode (FR-37) allows IPv4 VLAN defaults. It relies on the FR-37 metric rules and the snapshot comparison instead. `accept-ra: false` still excludes IPv6 defaults (dev/SKELETON.md, "Isolation covers each channel separately (FR-14a)").

**Warning:** before you change the FR-14 isolation keys, revisit this check.

## 9. The netplan try accept primitive

This is the netplan implementation of `apply_with_revert` (`backend_apply_with_revert`). It is the concurrency-sensitive part of the design (IR-2). dev/SKELETON.md owns its behavior in three places:
- "The accept primitive (netplan try and a fifo)": the timing model and the four accept conditions;
- "Stop requests during an apply (D2)": the stop path under `KillMode=mixed`;
- "Fifo behavior on a fail": the fail path and the wall-clock guard.

**Mechanism.**
- dynavlan starts `netplan try` with stdin from a fifo. It holds the fifo open for writing; that write-open unblocks the read-open by netplan.
- The accept loop polls every `POLL_INTERVAL` seconds. An independent wall-clock guard of `3 * TRY_TIMEOUT` bounds the loop.
- When all four accept conditions hold, the loop writes the newline, closes the fifo, and reaps the child.
- On a fail, the loop writes nothing. It keeps the write end open until `netplan try` exits, so the revert follows netplan's own timeout path.
- A bounded wait follows a fail. If the child is wedged, dynavlan logs and proceeds. The run lock releases when dynavlan exits.
- The accept write tolerates a `netplan try` that has already exited. The loop ignores `SIGPIPE`, so the write fails with `EPIPE` instead of killing the run.
- `TRY_TIMEOUT` is always passed explicitly. dynavlan never uses the netplan default of 120 seconds. The window must exceed the longest health check plus a margin.

**Rationale: a poll loop, not an early write (review round 2).** `netplan try` applies first and reads stdin after. A review found that a newline written early waits in the pipe buffer. netplan then consumes it unconditionally, which accepts a change the health check never saw. The poll loop writes the newline only after every check passes.

**Rationale: apply evidence proves a start, not completion.** Netdev creation is asynchronous after the networkd restart. So the probe iface shows only that the apply began. For this reason, health sampling also waits for the `APPLY_FALLBACK_SETTLE` floor.

**Decision: no positive completion signal for a change with no additions (C2, 2026-08-04).** Parsing the `netplan try` prompt was rejected as fragile across netplan versions. Such a change uses the larger `APPLY_NOEVIDENCE_SETTLE` floor instead (`apply_settle_floor`). The confirmation window bounds that floor from above (review round 0), so the change can still accept. dynavlan logs the exit of `netplan try` on both paths for audit, but the log cannot undo an accept.

**Rationale: the confirmation-window bound (review round 3).** The revert timer of `netplan try` starts when its apply completes. That is at or before the first apply evidence (`seen_at`). Past the bound, a live `try` may be reverting. The revert restores routing, so health passes, and a buffered newline would accept a rolled-back change. So past the bound the loop takes the fail path.

**Rationale: the liveness check.** A false accept would run the FR-24 deletes and the restarts for a change that was never applied. For example, `netplan try` can exit early with "another netplan process is running". Routing is then untouched, so health passes trivially.

**Evidence: stdin EOF reverts (hardware check P2, 2026-08-06).** On the test box, a writer killed during an apply caused a revert in about 4.3 seconds. A stop request uses this path on purpose (D2).

## 10. Data representation

- **Token sets.** Every set after detection is a space-separated, sorted token list in a shell variable (dev/SKELETON.md, "Token representation"). Bare-id lists exist only inside the per-trunk loop (`compute_candidates`, `boot_removals`), which tags them to tokens at once. Set operations use `set_minus`, `set_union` and `emit_tokens`, or the token helpers.
  Rationale: two trunks can share a VLAN id, so the token is the only key that cannot collide.
- **Known set.** `backend_owned_vlans` parses the stanza headers of the owned file as tokens. `netplan get network.vlans` is authoritative for ids. But the token comes from the owned file, because the file is what tells apart a shared id on two trunks.
- **`VLAN_IGNORE`.** `load_config` parses it once with `parse_vlan_ignore` into `IGNORE_SET`, a sorted set of bare ids. It filters inside a trunk's own candidate math, before tagging.
- **Generated stanza (FR-14).** Each token gets one stanza, named `<iface>.<id>`. It has `dhcp4: true`, the four `use-*` keys set to `false` under `dhcp4-overrides`, and `accept-ra: false` (FR-14a). The reason for `accept-ra: false` is in dev/SKELETON.md, "Isolation covers each channel separately (FR-14a)".
  Rationale for `accept-ra: false` in routed mode too: the FR-37 metric guard reasons only about metrics that dynavlan assigns.

### Routed mode (FR-37)

With `VLAN_ROUTES=true` (default off), the stanza sets `use-routes: true` and `route-metric: <assigned>`. DNS, NTP and domains stay declined. The assignment rules are in dev/SKELETON.md, "Metric assignment".

- `plan_route_metrics` is the single decision point for the token-to-metric map. Boot, rescan, dry-run and `--reapply` all call it. No caller composes `map_filter` and `assign_route_metrics` itself (tests/unit.sh §1g).
- The owned file doubles as the metric store (`backend_owned_metrics`), so there is no extra state file.
- All trunks share one metric sequence, not one sequence per trunk.
- **Conflict guard.** Before any disk change, `metric_conflict` refuses if an assigned metric would equal or beat the uplink default's metric.
  Rationale: that VLAN's default would win, and every apply would fail health and revert. A loud refusal up front beats a silent revert loop.
- **Empty snapshot with routes on.** A VLAN default may become the uplink. The PRD documents this as intended failover (FR-37).
- **Default-route VLAN guard (C1).** Once a VLAN is the box's default egress, removing it would strand the box. The rule is in dev/SKELETON.md, "Never remove the default-route interface (C1)". The guard refuses the whole reconcile, consistent with the metric-conflict guard. It does nothing when `VLAN_ROUTES=false`.

**Decision: lexical full-token order is the only ordering mode.** The all-trunks redesign dropped `VLAN_ROUTE_METRIC_MODE` and its `id` mode.
Rationale: a stateless `START + id` scheme has no natural per-trunk meaning once ids are not unique across the box.

**Decision (2026-07-25): assign metrics to target tokens that lack one, not to additions.** Assigning for additions was a defect.
Rationale: on an isolated-to-routed migration, every owned token lacks a metric, while the additions are empty or partial. Generation then refused permanently.

## 11. systemd units and install layout

**Installed files.**
- `/usr/local/sbin/dynavlan` (0755): the script.
- `/etc/dynavlan.conf` (0644): the config, with commented defaults.
- `/etc/netplan/90-dynavlan.yaml` (0600): the owned file, generated.

**`dynavlan.service`** runs `/usr/local/sbin/dynavlan --boot`.
- It sets `Type=oneshot`, `After=systemd-networkd.service`, and `WantedBy=multi-user.target`.
- It does not use `Wants=network-online.target` or `After=network-online.target`. Boot must not block on network-online (FR-29).
- It sets `KillMode=mixed` and `TimeoutStopSec=60` (D2; dev/SKELETON.md, "Stop requests during an apply (D2)").
- It sets `TimeoutStartSec=600`. Rationale: a boot can take `CARRIER_WAIT + 2*SNIFF + BOOT_SETTLE` plus the lease settle.

**`dynavlan-rescan.service`** runs `/usr/local/sbin/dynavlan --rescan`. It sets `Type=oneshot` and has no `[Install]` section, so only the timer activates it.

**Decision: a separate service for rescan.** A timer activates a service with a fixed `ExecStart` mode. Boot and rescan are different modes. Boot is a full reconcile with detection-diff and carrier-down removals. Rescan adds VLANs and prunes carrier-down trunks (FR-41).

**`dynavlan.timer`** activates `dynavlan-rescan.service`.
- It sets the monotonic triggers `OnBootSec`, `OnActiveSec` and `OnUnitActiveSec`, and `WantedBy=timers.target`.
- `--reconfigure` renders the interval from `RESCAN_MINUTES` into `.d/interval.conf`.
- The drop-in resets the monotonic list and emits only `OnActiveSec` (first fire) and `OnUnitActiveSec` (the interval). So it replaces the base `OnBootSec` with `OnActiveSec` on purpose (dev/SKELETON.md, FR-21a).

**Logging.** The install guarantees persistent journald: `/var/log/journal` plus a `Storage=persistent` drop-in. dynavlan logs to stderr, and the journal stores it under the identifier `dynavlan`.

**Decision: the journald branch only.** The optional `/var/log/dynavlan.log` file branch was not built. FR-31 requires one branch, not both.

**`install.sh`.**
- It requires root.
- It installs the script (0755), the config (0644, never overwriting an existing one), and all three units.
- It makes sure that `tcpdump` and `lldpd` are present.
- It writes the journald persistence drop-in and runs `--reconfigure`.
- It enables `dynavlan.service` and `dynavlan.timer` for the next boot. An upgrade keeps the operator's prior unit posture (dev/SKELETON.md, "Package lifecycle").
- It never triggers a network change. The first apply is the operator's `--boot` or the next reboot, which also starts the timer.

**Decision: install never enables with `--now`.** A monotonic timer whose `OnBootSec` is already past fires at once. That would run a rescan apply before the operator's `--dry-run` preview.

**Known limitation (FR-11).** An external netplan file can reuse dynavlan's exact stanza key (`<iface>.<id>`). Then `netplan get` merges the two entries into one, and the overlap warning cannot fire. Detection of this case would mean reading base files by name, which crosses the never-read-base-config line. This limitation is accepted. An overlap with a different key and the same id is detected and warned.

## 11a. Restart on a new subnet (FR-40)

**Problem.** The FR-27 restart trigger fires only on a tagged-VLAN change. So it misses two real cases:
1. An access port or a native-only trunk gets a lease after boot. dynavlan detects no tagged VLAN on it, so nothing changes.
2. The monitoring agent starts before base-interface DHCP completes. FR-29 does not block boot on `network-online.target`, on purpose.

Both cases are one problem. The agent cares about IPv4 subnets that it can scan, not about VLAN tags.

The rules are in dev/SKELETON.md, "The new-subnet restart (FR-40)" and "A total restart failure keeps the subnet unseen (M6, L10)".

**The seen set.** `maybe_restart_on_new_subnet` samples `current_subnets`: sorted `iface:network/prefix` tokens from every global-scope IPv4 address on the box. Link-local and loopback addresses are excluded. It compares them with the seen set in `SEEN_FILE` (`/run/dynavlan/seen`).
- The token is keyed on the network (`ipv4_network`), never the host address. So a DHCP renewal in the same pool gives the same token, and nothing restarts.
- The seen set normally only grows (`seen ∪ current`, through `set_union`). So a link flap back onto a seen subnet does not trigger again.
- The exception (M6): if no restart target restarted this run, the new tokens are held back (`(seen ∪ current) − new`). The next run then sees them as new and retries.
- L10 applies the same hold when no restart targets are configured. Dry-run and status report `no restart targets configured`.
- Ordering uses `emit_tokens` (lexical `sort -u`). Never use `emit_set` here, because it sorts numerically and takes bare VLAN ids only.

**Decision: hold back on total failure only, not on any failure.** A subnet cannot be mapped to one target, so a partial success consumes the event.
Rationale: if any failure blocked the subnet, one broken target would restart the working agents on every `--boot` and `--rescan`. That is a restart storm at the timer cadence, which disrupts the healthy agents. A transient total failure, such as snapd or systemd briefly busy, is still retried. In the common single-target config the two rules give the same result.

**Decision: the seen set lives in `/run`, not in the owned file.** There are two independent reasons.
1. Lifetime. `/run` is tmpfs and is wiped on reboot, which is the lifetime the seen set needs. After a reboot the agent relaunches and must enumerate again, so the baseline resets to empty. The owned file persists across reboots. A seen set stored there would stay populated and defeat the boot-race fix.
2. Safety. Only `apply_change` writes the owned file, inside the chain of generate, validate, `netplan try`, and accept or revert (FR-16, FR-17, FR-18). The seen set can change on every rescan. Sending that traffic through the one file that must never be half-written adds risk and buys nothing.

**No boot-specific branch.** `read_seen` returns empty when `SEEN_FILE` is absent, which is the first run of an uptime. So at boot, `current − seen` equals `current`. If any real subnet is present, the check fires and restarts once after the settle, whether the agent started before or after DHCP. The same rule runs on every boot and rescan: `new = current − seen`; if `new` is non-empty, restart once; then `seen = seen ∪ current`.

**Deduplication with the VLAN restart.** `apply_change` does not change. On an accept, its own `wait_leases` and `restart_targets` still fire on every VLAN change, in every mode. `restart_targets` sets the per-run flag `RESTARTED_THIS_RUN` whenever it runs, from either caller. So at most one restart happens per run.

**Hook point.** `main` calls `maybe_restart_on_new_subnet` once, after `do_boot` or `do_rescan` returns. It runs whatever the mode's return code is, except after a stop request (D2). So it also runs after a reverted apply or a `VLAN_LIMIT` refusal, because a new subnet does not depend on the VLAN outcome.

It is not called from `--dry-run`, `--status` or `--reapply`. `--dry-run` and `--status` report the would-restart delta (`current_subnets − read_seen`). None of the three calls `restart_targets` or `write_seen`.
Rationale: these modes stay free of side effects (FR-34, FR-35).

## 11b. Carrier-down removal (FR-41)

**Rationale: carrier is authoritative.** A trunk with carrier up and no tags is preserved, because absence of evidence (a sniff miss) is not evidence of absence. That reasoning does not hold for carrier. `/sys/class/net/<iface>/carrier` is an authoritative kernel signal, not a passive, lossy one. A carrier-down port cannot pass frames at all. So there is no case where the port is down but its VLANs are still live, unlike a silent VLAN on a live port.

**The rule.** dev/SKELETON.md, "Carrier-down removes; carrier-up with no tags preserves (FR-41)", owns it. A two-sample carrier-down debounce plus healthy routing removes every owned VLAN on that trunk. This is a full teardown of the trunk's set, not a per-VLAN diff, because a dead port kills every VLAN on it equally.

**Debounce interval.** On a `RESET_ON_BOOT=true` boot, the debounce reuses the pass-2 settle. The pass-2 re-detect sits between the two carrier samples. So the interval is about `BOOT_SETTLE + CARRIER_WAIT + SNIFF`, roughly 110 seconds with the defaults. On rescan, and on a `RESET_ON_BOOT=false` boot, the interval is a plain `BOOT_SETTLE_SECONDS`.

**Decision: keep the longer boot interval.** A longer interval biases toward preserve, so it is documented, not changed.
Rationale: a carrier sample taken before the re-detect would make the two signals reflect different instants.

**Two helpers carry the decision.** Both are free of side effects and unit-tested.
- `carrier_removals(owned_on_trunk, c1, c2)` is the debounce. It returns the full owned set only if both samples are `down`, else empty. It mirrors the shape of `boot_removals` (tests/unit.sh §1r).
- `have_routing()` is the routing pre-condition. It composes `snapshot_default_route`, `has_carrier` and `discover_phys_ifaces` (§1s). It is false when no default route exists, or when the only default leaves through a carrier-down iface. The second case is a dead trunk that is also the box's only uplink. In both cases the trunk is preserved.

**Rationale: the physical-NIC clause in `have_routing`.** `have_routing` also needs at least one physical NIC with carrier. A tun or WireGuard netdev reports `carrier=1` whenever it is up. So without this clause, a tunnel default would make an all-dark box look routable.

**Rejected alternative: test the egress device against a physical-NIC allowlist.** That would wrongly reject a default route that egresses a VLAN. It would also disable FR-41 completely on a box that really routes over a VPN.

**Rationale: `have_routing` is not redundant with the health check.** See §7. Both `do_boot` and `do_rescan` evaluate it immediately before they build the removal set, after any settle. A check made only before the settle would let an uplink lost during the settle through.

**Fire points differ on purpose.**
- `do_boot` reuses the pass-2 settle when `RESET_ON_BOOT=true` already runs one. The same sleep then serves the detection diff and the carrier resample. When `RESET_ON_BOOT=false`, boot runs its own minimal settle and resample. It does so only if an owned trunk was already down at pass 1 (`need_pass2`). An all-up `RESET_ON_BOOT=false` boot stays single-pass.
- `do_rescan` has this as its only removal path. The settle sleep fires only when at least one owned trunk is carrier-down, not merely absent from `DETECTED_TRUNKS`. So a steady-state rescan with every trunk up adds no latency.

**Independent of `RESET_ON_BOOT`.** `RESET_ON_BOOT` governs only the sniff-based detection-diff removal (FR-23). `REMOVE_ON_CARRIER_LOSS` (default `true`) is the only gate for carrier-down removal in both modes. So a `RESET_ON_BOOT=false` box, which only adds VLANs across boots, still heals a dead trunk.

**Deferred alternative: a grace-timer debounce (recorded, not built).** A persistent tracker in `/run` could record when each trunk first went carrier-down. It would require the trunk to stay down for a configurable grace period, about two rescan cycles, before a prune. That would avoid remove-then-re-add churn across a brief switch reboot or cable re-patch, which lasts tens of seconds to a few minutes. The cost is an ephemeral `/run` tracker and a new grace config key. Cleanup of a real unplug would also be about 10 minutes slower.

**Decision: grace timer rejected for v1.** The two-sample debounce accepts one self-healing agent restart in the transient case, and it needs no new persistent state. Revisit if field data shows real churn from switch maintenance. Spec: `docs/superpowers/specs/2026-07-30-carrier-down-vlan-removal-design.md`.

## 12. Portability plan

**Build now (cheap, structural):** the `backend_*` functions (§4), the abstract ownership model (§3), and the `apply_with_revert` capability contract. The core still has the direct netplan and platform dependencies that §4 lists. `backend_detect` waits for the second backend.

**Build later, only when a second backend is real:** the NetworkManager, networkd and ifupdown implementations, a real `backend_detect`, and any backend-selection config. The hardest piece of each future backend is the revert: native in NetworkManager, hand-rolled in networkd-direct.

**Not planned:** non-systemd init (OpenRC, runit). dynavlan assumes systemd for the service, the timer and journald. Revisit only if a real need comes up.

## 13. Deferred open items

The live list is in `context/open_questions.md`.

- IR-1: the exact minimum netplan version. It is pinned conservatively at 0.106 (`MIN_NETPLAN`), and it may be relaxed later.
- G-4: a per-VLAN MAC derivation function, after 1.0. The reserved `PER_VLAN_MAC` key was removed in 0.4.3; an implementation would bring it back.
