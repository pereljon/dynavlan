# CODEMAP - where things live

Owns: a one-line purpose for each function of the `dynavlan` script, for locating code. Does NOT hold logic flow (dev/SKELETON.md), design (dev/features/dynavlan.md), or requirements (docs/dynavlan-PRD.md). Line numbers drift; section anchors and ordering are stable.
Maintain: add/update a row when a function lands or changes purpose; keep each purpose to one line.

Everything lives in the single `./dynavlan` script (installs to /usr/local/sbin/dynavlan), sourceable for tests (`main` guarded by BASH_SOURCE). Sections appear in this order in the file.

## Pure helpers (side-effect-free; unit-tested in tests/unit.sh)

| function | one-line purpose | tests |
|----------|------------------|-------|
| `emit_set` | Print ids as a sorted de-duplicated space-separated set (shared by all set producers) | (via others) |
| `parse_vlan_ignore` | Expand VLAN_IGNORE comma/space list with low-high ranges into a set; any bad token = non-zero (refuse) | 1a |
| `select_trunk` | Pick trunk from "iface:tagcount" candidates: most tags wins, hysteresis margin 1 vs previous, lexicographic tiebreak | 1e |
| `boot_removals` | Owned ids absent from BOTH boot passes; both-empty = remove nothing (zero-detection guard) | 1d |
| `health_check_eval` | PASS iff the lowest-metric post-apply default egresses the snapshot iface (iface only; "" snap = PASS) | 1c |
| `vlan_guard` | Count gate verdict: OVER (> limit, 0 = unlimited) / WARN (> warn) / OK | 1f |
| `limit_fill` | Lowest-N subset of additions for fill mode (deterministic across a fleet) | 1f |
| `assign_route_metrics` | FR-37 id:metric map: discovery = kept verbatim + next-free ascending for new; id = START+id stateless | 1g |
| `map_filter` | Keep only listed ids' tokens of an id:metric map (drops removed VLANs' metrics) | 1g |
| `map_ids` | Ids of an id:metric map, as a sorted set | 1g |
| `plan_route_metrics` | THE FR-37 assignment decision point: owned map + target + additions -> full id:metric map; assigns for target ids LACKING a metric (not additions). Every caller must use this | 1g |
| `metric_conflict` | CONFLICT if any assigned metric <= uplink default's metric (tie counts), else OK | 1g |
| `compute_candidates` | detected ∩ [MIN,MAX] − ignore − managed-elsewhere − owned | 1b |

## Set utilities

| function | one-line purpose |
|----------|------------------|
| `set_minus` / `set_union` / `count_ids` | Space-separated sorted id-list operations |
| `in_list` / `is_uint` | Membership and unsigned-integer checks (config validation) |

## Logging + config

| function | one-line purpose |
|----------|------------------|
| `level_num` / `log` | Leveled logging to stderr → journald (identifier `dynavlan`), gated by LOG_LEVEL |
| `usage` | One-line usage to stderr |
| `version_string` | Pure: `<ver> (build <id>)`; empty build renders `unknown`, never `(build )` (FR-38) | 1k |
| `load_config` | Defaults, then source /etc/dynavlan.conf (root-owned, not group/other-writable, else refuse), then strict-validate every key |

## Preconditions (FR-0)

| function | one-line purpose |
|----------|------------------|
| `parse_version` | Pure: first `N.N[.N]` in a version string, empty when none (handles dpkg epoch/revision) |
| `netplan_version` / `version_ge` | Probe netplan version (`netplan --version` on 1.x, else dpkg-query on 0.10x) and compare against MIN_NETPLAN (sort -V) |
| `check_preconditions` | root; netplan >= min; non-mutating `netplan try` capability probe; tcpdump/lldpctl per DETECT_METHOD; tcpdump `-Q in` support (FR-5a, probed via `-d`, non-mutating) |

## Discovery + detection (FR-1..5)

| function | one-line purpose |
|----------|------------------|
| `discover_phys_ifaces` | Live physical Ethernet NICs from /sys/class/net (device symlink, ARPHRD_ETHER, not wireless, safe charset) |
| `tags_var` / `iface_tags` | Sanitized per-iface tag-stash variable name and its reader (no eval injection surface) |
| `prep_iface` / `has_carrier` | Admin-up + promisc on; carrier probe |
| `detect_sniff` | Passive 802.1Q capture, INBOUND ONLY (`-Q in`, FR-5a: our own egress is not evidence); minimal snaplen, no disk → VLAN ids |
| `lldp_tagged_vlans` | Pure: tagged VLAN ids from `lldpctl -f keyvalue` text; drops the native VLAN (`pvid=yes`), stateful adjacency parse (FR-7a) |
| `detect_lldp` | lldpctl-advertised VLAN ids, PVID excluded |
| `detect_iface` | Union of enabled methods for one iface |
| `run_detection` | Orchestrate: prep all, ONE shared carrier deadline, concurrent per-iface detection, select trunk → TRUNK_IFACE/DETECTED_VLANS |

## Backend seam (§4 - netplan implementation, the only backend)

| function | one-line purpose |
|----------|------------------|
| `backend_owned_vlans` | VLAN ids currently in our file (the known-set) |
| `backend_owned_metrics` | Persisted id:metric map read back from our file (FR-37 discovery-mode state) |
| `owned_parent` | Parent iface of our VLANs = previously-selected trunk (stickiness source) |
| `backend_list_managed_vlans` | VLAN ids managed OUTSIDE our namespace (netplan merge + kernel, minus our own) |
| `backend_generate_config` | Write our file atomically (same-dir mktemp 0600, fsync, rename); isolation stanza (incl. `accept-ra: false` in both modes, FR-14a), or routes+metric per FR-37 |
| `backend_validate` | `netplan generate`; on failure classify VALIDATE_ERRSRC ours-vs-base (base = freeze) |
| `backend_apply_with_revert` | The accept primitive: netplan try + fifo, apply-evidence + liveness + consecutive-health + window-bound accept; FAIL holds fifo open for try's own revert timer |
| `backend_remove_vlan` | `ip link delete` of a removed VLAN interface (only ever called after ACCEPT) |

## Health check (FR-18)

| function | one-line purpose |
|----------|------------------|
| `default_routes_tokens` | Current default routes as "iface:metric" tokens |
| `snapshot_default_route` / `snapshot_default_metric` | Iface / metric of the lowest-metric pre-apply default ("" if none) |
| `post_apply_health` | Sample routes now and delegate PASS/FAIL to `health_check_eval` |

## Backups (FR-19)

| function | one-line purpose |
|----------|------------------|
| `backup_current` | Copy the owned file to BACKUP_DIR before a change; failure = caller refuses to apply |
| `restore_prior` | Converge disk back to the prior file (or none on first run); failure logs err naming the surviving backup |
| `prune_backups` | Keep newest BACKUP_KEEP (only ever pruned after ACCEPT) |

## Change-gated side effects (FR-27/28)

| function | one-line purpose |
|----------|------------------|
| `wait_leases` | Bounded non-fatal wait for new-VLAN DHCP leases |
| `restart_targets` | Restart RESTART_SNAPS (snap) then RESTART_SERVICES (systemctl); warn-and-continue on failure |

## Apply orchestration + gates

| function | one-line purpose |
|----------|------------------|
| `apply_change` | The §7 safety chain: snapshot → (FR-37 metric assign + conflict refusal) → backup → generate → validate → apply_with_revert → ACCEPT: prune/deletes/leases/restarts, FAIL: converge disk, nothing else |
| `log_exclusions` | Warn per detected-but-managed-elsewhere VLAN |
| `warn_overlap` | FR-11: warn when an owned id is also defined in another netplan file |
| `gate_vlan_count` | Orchestrate warn / refuse / fill per VLAN_LIMIT_MODE; removals-only always passes |

## Modes + entrypoint

| function | one-line purpose |
|----------|------------------|
| `do_boot` | Two-pass reconcile: zero-detection guard, owned-parent pinning, carrier-gated removals, AC-3 relocation branch |
| `do_rescan` | Add-only timer reconcile, pinned to the owned parent, never relocates/removes |
| `do_dryrun` | Preview: same pinning/candidate math, throwaway-tree validate, diff + count gate + FR-37 metric/conflict preview; never applies |
| `do_status` | Owned vs detected-now vs managed-elsewhere report (root; runs a detection pass) |
| `render_timer_dropin` | Pure: timer drop-in text for an interval; restates ALL monotonic triggers, since the reset clears the whole list (FR-21a) |
| `do_reconfigure` | Write the rendered drop-in to `dynavlan.timer.d/interval.conf` + daemon-reload |
| `main` | Mode dispatch: `--version` (pre-config, pre-root) → config → (status/reconfigure) → preconditions → dry-run (non-blocking lock try) → boot/rescan under the fd-held flock |

## Non-script artifacts

| file | one-line purpose |
|------|------------------|
| `dynavlan.conf` | Config template, every key commented at its default |
| `dynavlan.service` | Boot oneshot (`--boot`), After=networkd, TimeoutStartSec=600 |
| `dynavlan-rescan.service` | Timer-invoked oneshot (`--rescan`) |
| `dynavlan.timer` | OnBootSec/OnUnitActiveSec → rescan service; interval via `--reconfigure` drop-in |
| `install.sh` | Root installer: stamps the build id into the script (FR-38, awk + verify + `bash -n`), script/config/units, deps, persistent journald, enables service+timer for NEXT boot (never applies); ONE EXIT trap (`cleanup`) does temp-file removal and timer restore |
| `tests/unit.sh` | Layer-1 pure-helper asserts (1a-1g), sources the script |
