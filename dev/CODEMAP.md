# CODEMAP - where things live

Owns: a one-line purpose for each function of the `dynavlan` script, for locating code. Does NOT hold logic flow (dev/SKELETON.md), design (dev/features/dynavlan.md), or requirements (docs/dynavlan-PRD.md). Line numbers drift; section anchors and ordering are stable.
Maintain: add/update a row when a function lands or changes purpose; keep each purpose to one line.

Everything lives in the single `./dynavlan` script (installs to /usr/local/sbin/dynavlan), sourceable for tests (`main` guarded by BASH_SOURCE). Sections appear in this order in the file.

## Pure helpers (side-effect-free; unit-tested in tests/unit.sh)

| function | one-line purpose | tests |
|----------|------------------|-------|
| `emit_set` | Print ids as a sorted de-duplicated space-separated set (shared by all set producers) | (via others) |
| `parse_vlan_ignore` | Expand VLAN_IGNORE comma/space list with low-high ranges into a set; any bad token = non-zero (refuse) | 1a |
| `boot_removals` | Owned ids absent from BOTH boot passes; both-empty = remove nothing (zero-detection guard) | 1d |
| `carrier_removals` | FR-41: full owned-on-trunk set if BOTH carrier samples are "down", else empty (dead-trunk full teardown, not a diff) | 1r |
| `health_check_eval` | PASS iff the lowest-metric post-apply default egresses the snapshot iface (iface only; "" snap = PASS) | 1c |
| `vlan_guard` | Count gate verdict: OVER (> limit, 0 = unlimited) / WARN (> warn) / OK | 1f |
| `limit_fill` | Lowest-N subset of additions for fill mode by NUMERIC vlan id, iface tie-break (deterministic across a fleet; M7) | 1f |
| `assign_route_metrics` | FR-37 iface.id:metric map: kept tokens verbatim + next-free ascending metric for new tokens (discovery order, the only mode) | 1g |
| `map_filter` | Keep only listed tokens' entries of a token:metric map (drops removed VLANs' metrics) | 1g |
| `map_ids` | Tokens (keys) of a token:metric map, as a sorted set | 1g |
| `plan_route_metrics` | THE FR-37 assignment decision point: owned map + target + additions -> full token:metric map; assigns for target tokens LACKING a metric (not additions). Every caller must use this | 1g |
| `metric_conflict` | CONFLICT if any assigned metric <= uplink default's metric (tie counts), else OK | 1g |
| `compute_candidates` | detected ∩ [MIN,MAX] − ignore − managed-elsewhere − owned (per-trunk bare-id math; caller tags the result to iface.id) | 1b |
| `ipv4_network` | Network address for an IPv4 ADDR+PREFIX, dotted-quad (FR-40 subnet-token keying, so a same-pool renewal maps to an identical token) | 1q |

## Token helpers (iface.id canonical key, spec section 3; pure)

Every set in the pipeline holds `iface.id` tokens, not bare VLAN ids, so two trunks sharing a VLAN id never alias. Split is always on the LAST dot.

| function | one-line purpose |
|----------|------------------|
| `emit_tokens` | Sorted (lexical) de-duplicated space-separated token set (the token-domain counterpart of `emit_set`) |
| `sort_tokens_by_id` | Deduped token set ordered by NUMERIC vlan id then iface (`sort -t. -k2,2n -k1,1`); the fill-selection order (M7) |
| `tok_iface` | Token -> its iface part (strip trailing `.id`) |
| `tok_id` | Token -> its id part (strip leading `iface.`) |
| `tag_tokens` | IFACE + bare-id set -> `iface.id` tokens; DROPS any name > 15 chars (IFNAMSIZ, H6) with a warning - the sole choke point, so all modes see a legal set |
| `untag_tokens` | Token set -> bare-id set (strips the iface part; used when a caller needs ids on one trunk) |
| `tokens_for_iface` | Token set filtered to one iface's tokens |
| `drop_iface_tokens` | Token set minus every token on any listed iface (tests 1w). Used to discard additions on a trunk confirmed carrier-down, since additions are computed from tags sniffed before the carrier verdict |
| `ifaces_without_carrier` | Addition tokens -> subset of their ifaces that lack carrier NOW (tests 1ad, M4). Single sample. do_boot/do_rescan/do_dryrun fold its result into the drop set so a newly-detected but not-yet-owned trunk that dies in the detection->apply window doesn't get stanzas on a dead parent (the owned-only removal path misses it) |
| `distinct_ifaces` | Token set -> sorted set of the distinct ifaces present (drives the per-trunk loop in do_boot/do_rescan/do_dryrun) |

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
| `config_body_differs` | Pure: SAME/DIFFERENT for two configs ignoring exactly line 1 (the version/build header) (FR-39) | 1m |
| `load_config` | Defaults, then parse /etc/dynavlan.conf via `config_load_file` (root-owned, not group/other-writable, else refuse), then strict-validate every key |
| `config_load_file` | H2: parse the config declaratively (never source); honor only allowlisted KEY=value lines, refuse any unknown/protected key or non-assignment line, assign inert literals via `printf -v` (no code execution, no internal-var override) |
| `config_allowed_key` | H2: membership test of a key against `CONFIG_KEYS`, the exact documented config surface |
| `config_normalize_value` | H2: strip a config value's inline comment, surrounding quotes, and outer whitespace, keeping internal spaces (unquoted lists preserved, not truncated) |

## Preconditions (FR-0)

| function | one-line purpose |
|----------|------------------|
| `parse_version` | Pure: first `N.N[.N]` in a version string, empty when none (handles dpkg epoch/revision) |
| `netplan_version` / `version_ge` | Probe netplan version (`netplan --version` on 1.x, else dpkg-query on 0.10x) and compare against MIN_NETPLAN (sort -V) |
| `check_preconditions` | root; netplan >= min; non-mutating `netplan try` capability probe; tcpdump/lldpctl per DETECT_METHOD; tcpdump `-Q in` support (FR-5a, probed via `-d`, non-mutating) |

## Discovery + detection (FR-1..5)

| function | one-line purpose |
|----------|------------------|
| `discover_phys_ifaces` | Live physical Ethernet NICs from /sys/class/net (device symlink, ARPHRD_ETHER, not wireless, charset `[A-Za-z0-9_-]` - `.` refused as it aliases the VLAN separator, M1) |
| `iface_key` | IFACE -> injective, shell-identifier-safe key (hex-escapes each non-alnum byte). Backs `tags_var` + the boot carrier stashes so `enp-1`/`enp_1` never collide (M1) |
| `tags_var` / `iface_tags` | Per-iface tag-stash variable name (via `iface_key`, injective) and its reader (no eval injection surface) |
| `valid_var` / `iface_valid` | Per-iface detection-validity stash (via `iface_key`) and its reader; `valid`/`invalid` removal-trust verdict parallel to `tags_var` (H1) |
| `prep_fail_var` | Per-iface prep-failure flag stash; `prep_iface` sets it, `store_detection` folds it into the validity verdict (H1) |
| `detection_sample_valid` | Pure: METHOD SNIFF LLDP PREP → `valid`/`""`; decides whether a boot sample is trustworthy for REMOVALS. Prep failure invalidates; under `both` only sniff (the primary) must have succeeded, LLDP failure is non-fatal (H1) |
| `prep_iface` / `has_carrier` | Admin-up + promisc on (records failure via `prep_fail_var`, H1); carrier probe |
| `detect_sniff` | Passive 802.1Q capture, INBOUND ONLY (`-Q in`, FR-5a: our own egress is not evidence); minimal snaplen, no disk → `"STATUS IDS"` where STATUS is ok\|fail from tcpdump's own exit (`{0,124}`=ok; captured before the grep pipeline so `pipefail`+grep cannot mask a real failure, H1) |
| `lldp_tagged_vlans` | Pure: tagged VLAN ids from `lldpctl -f keyvalue` text; drops the native VLAN (`pvid=yes`), stateful adjacency parse (FR-7a) |
| `detect_lldp` | lldpctl-advertised VLAN ids (PVID excluded) → `"STATUS IDS"`, STATUS ok\|fail from lldpctl's exit (H1) |
| `detect_iface` | Union of enabled methods for one iface → `"SNIFFSTATUS LLDPSTATUS IDS..."` (relays per-method run status for the validity verdict, H1) |
| `store_detection` | Parse a `detect_iface` line, stash `TAGS_` (ids) + `VALID_` (removal-trust verdict via `detection_sample_valid` + the prep flag); empty/short line defaults to `invalid` (safe: preserves owned VLANs) (H1) |
| `iface_tags` | Reader for one iface's stashed detection result (set by `run_detection`) |
| `run_detection` | Orchestrate: prep all, ONE shared carrier deadline, concurrent per-iface detection → `store_detection` sets `TAGS_`/`VALID_` per iface → `DETECTED_TRUNKS` (every carrier-up iface with a non-empty tag set, not a single selected trunk) |

## Backend seam (§4 - netplan implementation, the only backend)

| function | one-line purpose |
|----------|------------------|
| `backend_owned_vlans` | `iface.id` tokens currently in our file (the known-set), parsed from the stanza headers |
| `backend_owned_metrics` | Persisted `iface.id:metric` map read back from our file (FR-37 discovery-mode state) |
| `backend_list_managed_vlans` | IFACE -> bare VLAN ids managed OUTSIDE our namespace on THAT trunk (netplan merge + kernel, minus our own tokens on that iface) |
| `backend_generate_config` | Write our file atomically (same-dir mktemp 0600, fsync, rename) from a target token set; isolation stanza (incl. `accept-ra: false` in both modes, FR-14a), or routes+metric per FR-37, keyed per token |
| `backend_validate` | `netplan generate`; on failure classify VALIDATE_ERRSRC ours-vs-base (base = freeze) |
| `apply_settle_floor` | C2: returns the settle floor before health sampling - `APPLY_FALLBACK_SETTLE` when a probe iface exists, the larger `APPLY_NOEVIDENCE_SETTLE` for no-addition changes (removal-only/`--reapply`) that have no in-kernel apply signal |
| `backend_apply_with_revert` | The accept primitive: netplan try + fifo, apply-evidence + liveness + consecutive-health + window-bound accept; per-change settle floor via `apply_settle_floor`; captures netplan try's exit on both paths (audit); FAIL holds fifo open for try's own revert timer |
| `backend_remove_vlan` | `ip link delete` of a removed VLAN interface (only ever called after ACCEPT). Returns rc 1 on delete failure so the caller can record a retry (M5) |
| `pending_deletes` / `write_pending_deletes` / `record_pending_delete` | Ownership-safe pending-delete record in `/run` (tmpfs, reboot-scoped). `apply_change` records a token whose post-ACCEPT `ip link delete` failed; only tokens dynavlan itself removed are ever written, so a retry never touches an external VLAN (M5) |
| `drain_pending_deletes` | Start of do_boot/do_rescan: retries every recorded delete via `backend_remove_vlan`, keeps only those still failing. do_dryrun previews the pending set read-only (M5) |

## Health check (FR-18)

| function | one-line purpose |
|----------|------------------|
| `default_routes_tokens` | Current default routes as "iface:metric" tokens |
| `snapshot_default_route` / `snapshot_default_metric` | Iface / metric of the lowest-metric pre-apply default ("" if none) |
| `default_iface_in_removals` | C1: 0 iff the current default-route iface is non-empty AND an exact token in the removal set (routed-mode-only backstop; drives `apply_change`'s pre-disk refusal and the `do_dryrun` preview; tests 1aa) |
| `post_apply_health` | Sample routes now and delegate PASS/FAIL to `health_check_eval` |
| `have_routing` | FR-41 pre-condition: true iff a lowest-metric default route exists, its egress iface has carrier, AND at least one physical NIC has carrier (composes `snapshot_default_route` + `has_carrier` + `discover_phys_ifaces`; tests 1s). The physical clause stops a tun/wireguard default - those report carrier whenever merely up - from making an all-dark box look routable |

## Backups (FR-19)

| function | one-line purpose |
|----------|------------------|
| `backup_current` | Copy the owned file to BACKUP_DIR before a change; failure = caller refuses to apply |
| `restore_prior` | Converge disk back to the prior file (or none on first run); failure logs err naming the surviving backup |
| `prune_backups` | Keep newest BACKUP_KEEP (only ever pruned after ACCEPT) |

## Change-gated side effects (FR-27/28)

| function | one-line purpose |
|----------|------------------|
| `iface_has_lease` | True if the iface has an IPv4 address (`ip -4 addr`); the lease predicate `wait_leases` polls |
| `wait_leases` | Non-fatal wait for new-VLAN DHCP leases under ONE box-wide `LEASE_SETTLE_SECONDS` deadline (all pending polled together, bounded regardless of count; NOT per-VLAN in series, which stacked to VLAN_LIMIT × the deadline and could outrun the systemd start timeout - H5) |
| `restart_targets` | Restart RESTART_SNAPS (snap) then RESTART_SERVICES (systemctl); warn-and-continue per target; sets `RESTARTED_THIS_RUN` so FR-40's growth-check does not double-restart; sets `RESTART_NONE_SUCCEEDED_THIS_RUN` only on a TOTAL failure (nothing restarted), so a partial success still consumes the new-subnet event (M6) |
| `current_subnets` | FR-40: sorted `iface:network/prefix` tokens from `ip -4 -o addr show scope global`, skipping non-CIDR peer lines and link-local/loopback |
| `read_seen` / `write_seen` | FR-40: read/write the ephemeral seen-subnet set at `/run/dynavlan/seen` (absent file = empty set) |
| `maybe_restart_on_new_subnet` | FR-40: if `current_subnets − seen` is non-empty, restart targets once (deduped via `RESTARTED_THIS_RUN`), then grow `seen` to `seen ∪ current` - but if NO target restarted this run (`RESTART_NONE_SUCCEEDED_THIS_RUN`, a total failure), leave the new tokens unseen so the next run retries (M6); gated by `RESTART_ON_NEW_SUBNET` |

## Apply orchestration + gates

| function | one-line purpose |
|----------|------------------|
| `apply_change` | The §7 safety chain: snapshot → **C1 default-route removal guard (refuse if snap_iface in removals)** → (FR-37 metric assign + conflict refusal) → backup → generate → validate → apply_with_revert → ACCEPT: prune/deletes/leases/restarts, FAIL: converge disk, nothing else |
| `log_exclusions` | Warn per detected-but-managed-elsewhere VLAN |
| `warn_overlap` | FR-11: warn when an owned id is also defined in another netplan file |
| `gate_vlan_count` | Orchestrate warn / refuse / fill per VLAN_LIMIT_MODE; removals-only always passes |

## Modes + entrypoint

| function | one-line purpose |
|----------|------------------|
| `do_boot` | All-trunks reconcile: `run_detection`'s rc is ignored (it means "saw nothing", not "failed" - there is no probe-error signal), branching on `DETECTED_TRUNKS` instead, so a zero detection blocks additions without blocking FR-41 pruning; per-trunk candidates over every owned-or-detected iface (union); carrier-UP trunks get sniff-based detection-diff removal (`RESET_ON_BOOT`), suppressed when either pass's sample is `invalid` (a capture-method failure, H1); carrier-DOWN trunks get full-set FR-41 pruning (`carrier_removals`, gated on `have_routing` + `REMOVE_ON_CARRIER_LOSS`, a flap preserves); second settle+resample (`need_pass2`) fires for either reason; one unified `apply_change` across the whole box. No relocation branch: a tagless-but-carrier-UP trunk is preserved (detection uncertainty); a carrier-DOWN trunk is pruned once routing is healthy, not preserved |
| `do_rescan` | Timer reconcile: additions over DETECTED_TRUNKS as before; FR-41 (v0.4.0) adds its first removal path - carrier-down OWNED trunks are pruned on a routing-gated two-sample settle, fast-path-preserved (settle sleep only when an owned trunk is actually down). `have_routing` is checked twice - before the sleep (whether to settle at all) and again after it (whether to remove), since an uplink lost during the settle would otherwise produce a removal the health check cannot revert |
| `do_dryrun` | Preview: same per-trunk candidate math (single pass) over owned-or-detected ifaces, plus a would-be FR-41 removal per trunk (single advisory sample, `have_routing`-gated); throwaway-tree validate, diff + count gate + FR-37 metric/conflict preview + C1 default-route-guard preview (would-refuse), per-trunk breakdown (now with carrier state) printed; never applies; returns non-zero when validation FAILs (M3), 0 otherwise, so `$?` works as a scripted pre-flight |
| `do_reapply` | FR-39: regenerate the OWNED set (whatever trunks it spans) with this build, apply only if the body differs; NO detection (pins to `distinct_ifaces` of the owned tokens), full owned set lease-waited, count gate bypassed |
| `do_status` | Report for every owned trunk plus every currently-detected trunk: owned vs detected-now vs managed-elsewhere (root; runs a detection pass); also prints carrier up/down per owned trunk (FR-41) |
| `render_timer_dropin` | Pure: timer drop-in text for an interval; restates ALL monotonic triggers, since the reset clears the whole list (FR-21a) |
| `do_reconfigure` | Write the rendered drop-in to `dynavlan.timer.d/interval.conf` + daemon-reload |
| `main` | Mode dispatch: `--version` (pre-config, pre-root) → config → (status/reconfigure) → preconditions → dry-run (non-blocking lock try) → boot/rescan under the fd-held flock, followed by `maybe_restart_on_new_subnet` (FR-40) on every boot/rescan exit path |

## Non-script artifacts

| file | one-line purpose |
|------|------------------|
| `dynavlan.conf` | Config template, every key commented at its default |
| `dynavlan.service` | Boot oneshot (`--boot`), After=networkd, TimeoutStartSec=600 |
| `dynavlan-rescan.service` | Timer-invoked oneshot (`--rescan`) |
| `dynavlan.timer` | OnBootSec/OnUnitActiveSec → rescan service; interval via `--reconfigure` drop-in |
| `install.sh` | Root installer: stamps the build id into the script (FR-38, awk + verify + `bash -n`), script/config/units, deps, persistent journald, enables service+timer for NEXT boot (never applies); ONE EXIT trap (`cleanup`) does temp-file removal and timer restore |
| `tests/unit.sh` | Layer-1 pure-helper asserts (1a-1g), sources the script |
