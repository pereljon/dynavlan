# CODEMAP: where things live

Owns: a one-line purpose for each function of the `dynavlan` script, for locating code. Does NOT hold logic flow (dev/SKELETON.md), design (dev/features/dynavlan.md), or requirements (docs/dynavlan-PRD.md). Line numbers drift; section anchors and ordering are stable.
Maintain: add or update a row when a function lands or changes purpose. Keep each purpose to one sentence of about 25 words. Put flow and sequence detail in dev/SKELETON.md.

Everything lives in the single `./dynavlan` script, which installs to /usr/local/sbin/dynavlan. Tests can source it, because `main` is guarded by `BASH_SOURCE`. Sections appear in this order in the file.

## Pure helpers (side-effect-free; unit-tested in tests/unit.sh)

| function | one-line purpose | tests |
|----------|------------------|-------|
| `emit_set` | Prints ids as a sorted, de-duplicated, space-separated set; every set producer uses it. | (via others) |
| `parse_vlan_ignore` | Expands `VLAN_IGNORE` ids and `low-high` ranges into a set, accepting spaces around commas; a bad token, leading zero, or empty element returns non-zero. | 1a, 1as |
| `boot_removals` | Returns owned ids absent from both boot passes; if both passes are empty, it removes nothing (zero-detection guard). | 1d |
| `carrier_removals` | Returns the trunk's full owned set when both carrier samples are `down`, else nothing (FR-41). | 1r |
| `missing_since_of` | Returns a token's recorded missing-since uptime from the state text, or nothing for no line or a malformed one. | 1az |
| `missing_since_update` | Returns the next missing-since state for owned tokens: a sighting clears, a miss keeps or starts the clock, others stay. | 1az |
| `missing_due` | Returns the tokens missed this run whose clock has run `REMOVE_MISSING_MINUTES`; nothing when the key is 0. | 1az |
| `missing_left` | Returns `token:minutes` left, rounded up, for each token missed this run that is not yet due. | 1az |
| `health_check_eval` | Returns `PASS` if the snapshot iface still holds a default route at the minimum post-apply metric, in any listing order (P3); an empty snapshot passes. | 1c |
| `vlan_guard` | Returns the count-gate verdict: `OVER` (above the limit; 0 means unlimited), `WARN` (above the warn level), or `OK`. | 1f |
| `limit_fill` | Selects the lowest-N additions for `fill` mode, by numeric VLAN id with the iface as tie-break (M7). | 1f |
| `assign_route_metrics` | Builds the FR-37 token-to-metric map: kept tokens unchanged, new tokens get next-free ascending metrics in lexical token order. | 1g |
| `map_filter` | Keeps only the listed tokens' entries of a token-to-metric map, which drops removed VLANs' metrics. | 1g |
| `map_ids` | Returns the tokens (keys) of a token-to-metric map as a sorted set. | 1g |
| `plan_route_metrics` | The single FR-37 metric decision point, which every caller must use; it assigns metrics to target tokens that lack one. | 1g |
| `metric_conflict` | Returns `CONFLICT` if any assigned metric is less than or equal to the uplink default's metric, else `OK`. | 1g |
| `compute_candidates` | Computes per-trunk bare-id candidates: detected ∩ [MIN,MAX] − ignore − managed-elsewhere − owned; the caller tags the result. | 1b |
| `ids_in_ignore` / `ids_out_of_range` | Return the detected ids inside `VLAN_IGNORE` or outside `[MIN,MAX]`, for the per-trunk `--status` report (M8, FR-35). | 1ah |
| `ipv4_network` | Returns the dotted-quad network address for an IPv4 address and prefix, so a same-pool renewal keeps its FR-40 subnet token. | 1q |

## Token helpers (iface.id canonical key, spec section 3; pure except `tag_tokens` and `ifaces_without_carrier`)

Every set in the pipeline holds `iface.id` tokens, not bare VLAN ids, so two trunks that share a VLAN id never alias. A token always splits on its last dot.

| function | one-line purpose |
|----------|------------------|
| `emit_tokens` | Prints a sorted (lexical), de-duplicated token set; the token counterpart of `emit_set`. |
| `sort_tokens_by_id` | Orders a de-duplicated token set by numeric VLAN id, then iface (`sort -t. -k2,2n -k1,1`); the fill order (M7). |
| `tok_iface` | Returns a token's iface part by stripping the trailing `.id`. |
| `tok_id` | Returns a token's id part by stripping the leading `iface.`. |
| `tag_tokens` | The only `iface.id` constructor; it drops, with a logged warning, any name over 15 characters (`IFNAMSIZ`, H6), so it is not pure. |
| `untag_tokens` | Converts a token set to a bare-id set, for callers that need ids on one trunk. |
| `tokens_for_iface` | Filters a token set to one iface's tokens. |
| `drop_iface_tokens` | Removes every token on the listed ifaces; boot and rescan use it to drop additions on carrier-down trunks (tests 1w). |
| `ifaces_without_carrier` | Returns the ifaces of addition tokens that lack carrier now, from one live sample; not pure (tests 1ad, M4). |
| `distinct_ifaces` | Returns the sorted distinct ifaces in a token set; it drives the per-trunk loop in `do_boot`, `do_rescan` and `do_dryrun`. |

## Set utilities

| function | one-line purpose |
|----------|------------------|
| `set_minus` / `set_union` / `count_ids` | Operate on space-separated sorted id lists. |
| `in_list` / `is_uint` | Test list membership and canonical decimals (`0` or `[1-9][0-9]*`, never octal) for config validation (1as). |

## Logging + config

| function | one-line purpose |
|----------|------------------|
| `level_num` / `log` | Log by level to stderr, which journald stores under the identifier `dynavlan`, filtered by `LOG_LEVEL`. |
| `usage` | Prints the one-line usage to stderr. |
| `version_string` | Returns `<ver> (build <id>)`, rendering an empty build as `unknown`, never `(build )`; pure (FR-38). | 1k |
| `config_body_differs` | Returns `SAME` or `DIFFERENT` for two configs, ignoring only line 1, the version and build header; pure (FR-39). | 1m |
| `load_config` | Sets defaults, parses /etc/dynavlan.conf through `config_load_file` after an ownership and permission check, then validates every key strictly. |
| `config_load_file` | Parses the config declaratively against the allowlist, never by `source`, and assigns values as inert literals with `printf -v` (H2). |
| `config_allowed_key` | Tests whether a key is in `CONFIG_KEYS`, the exact documented config surface (H2). |
| `config_normalize_value` | Strips a value's inline comment, quotes and outer whitespace, keeping internal spaces; returns 1 on an unmatched quote or trailing text, so `config_load_file` refuses (H2, 1as). |

## Preconditions (FR-0)

| function | one-line purpose |
|----------|------------------|
| `parse_version` | Returns the first `N.N[.N]` in a version string, or empty; handles a dpkg epoch and revision; pure. |
| `netplan_version` / `version_ge` | Read the netplan version (`netplan --version` on 1.x, else dpkg-query) and compare it with `MIN_NETPLAN` using `sort -V`. |
| `have_cmd` | Tests `command -v CMD`; a seam that tests stub for the dependency probes. |
| `tcpdump_supports_inbound` | Tests tcpdump `-Q in` support with a non-mutating `-d` probe (FR-5a). |
| `check_detect_deps` | The non-mutating detection dependency gate (M8) that `check_preconditions` and `do_status` share; it checks neither root nor `netplan try`. |
| `check_preconditions` | Checks root, runs `check_detect_deps`, and probes `netplan try` without changing anything (apply modes only). |

## Discovery + detection (FR-1..5)

| function | one-line purpose |
|----------|------------------|
| `discover_phys_ifaces` | Lists live physical Ethernet NICs from /sys/class/net and refuses names containing `.`, the VLAN separator (M1). |
| `iface_key` | Maps an iface name to an injective, shell-safe key by hex-escaping each non-alphanumeric byte, for the per-iface stashes (M1). |
| `tags_var` / `iface_tags` | Name and read the per-iface tag stash variable, keyed through `iface_key`, with no eval injection surface. |
| `valid_var` / `iface_valid` | Name and read the per-iface `valid` or `invalid` removal-trust verdict, parallel to `tags_var` (H1). |
| `prep_fail_var` | Names the per-iface prep-failure flag that `prep_iface` sets and `store_detection` reads (H1). |
| `detection_sample_valid` | Decides whether a sample can authorize removals; prep failure invalidates, and under `both` only the sniff must succeed; pure (H1). |
| `prep_iface` / `has_carrier` | Set an iface admin-up and promiscuous, recording a failure in `prep_fail_var` (H1); test carrier. |
| `detect_sniff` | Captures inbound 802.1Q frames only (`-Q in`, FR-5a) with a minimal snaplen and returns `"STATUS IDS"` from tcpdump's own exit (H1). |
| `lldp_tagged_vlans` | Parses `lldpctl -f keyvalue` text into tagged VLAN ids, dropping the native VLAN (`pvid=yes`) by adjacency (FR-7a); pure. |
| `detect_lldp` | Returns LLDP-advertised VLAN ids as `"STATUS IDS"`; a zero-exit connection diagnostic also counts as `fail` (H1, HV-41; tests 1aw). |
| `detect_iface` | Returns the union of enabled methods for one iface as `"SNIFFSTATUS LLDPSTATUS IDS..."`, relaying each method's status (H1). |
| `store_detection` | Parses a `detect_iface` line into the `TAGS_` and `VALID_` stashes; an empty or short line means `invalid` (H1). |
| `run_detection` | Orchestrates one detection pass and sets `DETECTED_TRUNKS` and `DETECT_INVALID` (D5); see dev/SKELETON.md "Detection". |

## Backend functions (§4: a partial netplan seam, the only backend)

The core also calls `netplan`, `ip` and the owned file directly (version and `try` probes, backup and restore, route snapshots, discovery); see `dev/features/dynavlan.md` §4.

| function | one-line purpose |
|----------|------------------|
| `backend_owned_vlans` | Returns the `iface.id` tokens in the owned file, parsed from its stanza headers. |
| `backend_owned_metrics` | Returns the persisted `iface.id:metric` map from the owned file (FR-37 state). |
| `backend_netplan_vlan_tokens` | Lists every netplan VLAN stanza as a token from its own `id:` and `link:`, never the mapping key (L1), keeping duplicates for overlap counts; rc rules in dev/SKELETON.md. |
| `backend_list_managed_vlans` | Returns the bare VLAN ids that netplan or the kernel manage outside the owned file on one trunk. |
| `backend_generate_config` | Writes the owned file atomically from a target token set, with the isolation stanza and `accept-ra: false`, or routes and metrics (FR-14a, FR-37). |
| `backend_validate` | Runs `netplan generate [--root-dir ROOT]` and, on failure, sets `VALIDATE_ERRSRC` to ours or base (base freezes updates). |
| `backend_stage_netplan_tree` | Copies `/etc/netplan` and, if present, `/lib/netplan` and `/run/netplan` into a scratch root; returns 1 on a failed copy (tests 1av). |
| `backend_validate_candidate` | Validates the candidate in an isolated scratch root before `netplan try`; rc 0 valid, 1 rejected, 2 setup failure (tests 1av). |
| `backend_stop_cleanup` | On a stop request, closes the unaccepted fifo writer and waits up to `TRY_TIMEOUT + STOP_CHILD_MARGIN` for `netplan try` to revert (D2); tests 1ao. |
| `backend_apply_with_revert` | The accept primitive: runs `netplan try` through a fifo and writes the confirming newline only under the conditions in dev/SKELETON.md. |
| `backend_remove_vlan` | Runs `ip link delete` on a removed VLAN, only after an accept; returns 1 on failure so the caller records a retry (M5). |

## Apply support, pending deletes, package lifecycle (core and packaging, not backend)

| function | one-line purpose |
|----------|------------------|
| `apply_settle_floor` | Returns the settle floor before health sampling: `APPLY_FALLBACK_SETTLE` with an addition, else the larger `APPLY_NOEVIDENCE_SETTLE` (C2). |
| `stop_requested` / `stop_trap_on` / `stop_trap_off` / `wait_child_gone` | Handle a graceful stop (D2): the TERM trap inside `apply_change`, the stop flag, and bounded `kill -0` child polling; tests 1ao. |
| `pending_deletes` / `write_pending_deletes` / `record_pending_delete` | Read and write the pending-delete record in `/run`, which holds tokens whose post-accept delete failed (M5). |
| `drain_pending_deletes` | Retries recorded deletes at the start of `do_boot` and `do_rescan`, after re-checking current ownership (D1, L7, M5); see dev/SKELETON.md. |
| `debian/preinst` / `prerm` / `postinst` / `postrm`, `install.sh` | Preserve each unit's enabled and active posture across install and upgrade (Group 2); see dev/SKELETON.md "Package lifecycle"; tests `tests/lifecycle.sh` (folded into `unit.sh` §1aq). |

## Health check (FR-18)

| function | one-line purpose |
|----------|------------------|
| `default_routes_tokens` | Returns the current IPv4 default routes as `iface:metric` tokens. |
| `snapshot_default_route` / `snapshot_default_metric` | Return the iface or the metric of the lowest-metric pre-apply default route, or empty if there is none. |
| `default_iface_in_removals` | Returns 0 if the current default-route iface is an exact removal token; drives the C1 refusal and its dry-run preview (tests 1aa). |
| `post_apply_health` | Samples the routes now and returns the verdict of `health_check_eval`. |
| `have_routing` | True if a lowest-metric default route exists, its iface has carrier, and a physical NIC has carrier (FR-41; tests 1s). |

## Backups (FR-19)

| function | one-line purpose |
|----------|------------------|
| `backup_current` | Copies the owned file to `BACKUP_DIR` before a change; on failure the caller refuses to apply. |
| `restore_prior` | Converges disk back to the prior file, or to none on a first run; on failure it logs the surviving backup. |
| `prune_backups` | Keeps the newest `BACKUP_KEEP` backups, pruning only after an accept. |

## Change-gated side effects (FR-27/28)

| function | one-line purpose |
|----------|------------------|
| `iface_has_lease` | True if the iface has an IPv4 address (`ip -4 addr`); the lease test that `wait_leases` polls. |
| `wait_leases` | Waits, without failing, for new-VLAN DHCP leases under one box-wide `LEASE_SETTLE_SECONDS` deadline that covers all VLANs together (H5). |
| `restart_targets` | Restarts `RESTART_SNAPS`, then `RESTART_SERVICES`, warning per failure, and sets the flags that the FR-40 check reads (L10, M6). |
| `current_subnets` | Returns sorted `iface:network/prefix` tokens for global IPv4 addresses, skipping peer, link-local and loopback lines (FR-40). |
| `read_seen` / `write_seen` | Read and write the runtime seen-subnet set at `/run/dynavlan/seen`; an absent file is an empty set (FR-40). |
| `maybe_restart_on_new_subnet` | Restarts targets once when a subnet is new, then marks it seen unless no target restarted (FR-40, M6, L10); gated by `RESTART_ON_NEW_SUBNET`. |

## Missing-VLAN state (FR-44; tests/unit.sh §1az)

| function | one-line purpose |
|----------|------------------|
| `uptime_seconds` | Returns whole seconds since boot from `UPTIME_FILE`; rc 1 if unreadable, which skips missing-VLAN tracking. |
| `read_missing_since` | Returns the missing-since record at `/run/dynavlan/missing-since`, or nothing if the file is absent or unreadable. |
| `write_missing_since` | Atomically replaces the record (empty removes it); on failure removes it, so clocks restart rather than run early. |
| `missing_classify` | Splits owned tokens into those a trusted sample on a carrier-up trunk missed and those it saw. |
| `missing_track` | Computes this run's uptime, missed set and next state from the detection stash, without writing. |
| `missing_record` | Runs `missing_track` and persists the state; with the key at 0, drops the record. |
| `missing_log_pending` | Logs one `warning` per missing VLAN not yet due, with its minutes left. |
| `missing_prune` | After an accepted apply, drops record lines for tokens no longer owned. |
| `missing_report` | Prints the missing-VLAN lines for `--status` and `--dry-run`; never writes. |

## Apply orchestration + gates

| function | one-line purpose |
|----------|------------------|
| `apply_change` / `apply_change_run` | `apply_change` wraps the TERM trap (D2) around `apply_change_run`, the safety chain in dev/SKELETON.md "Apply and revert state machine". |
| `log_exclusions` | Warns once per detected VLAN that is managed elsewhere. |
| `warn_overlap` | Warns when another netplan key also defines an owned `(link,id)` tuple (FR-11, L1); boot and rescan call it before their no-change return. |
| `gate_vlan_count` | Applies warn, refuse or fill per `VLAN_LIMIT_MODE`; a change with removals only always passes. |

## Modes + entrypoint

| function | one-line purpose |
|----------|------------------|
| `do_boot` | The boot reconcile across all trunks, with two-pass detection-diff and carrier-down removal; see dev/SKELETON.md "--boot". |
| `do_rescan` | The timer reconcile: additions over `DETECTED_TRUNKS` plus routing-gated carrier-down pruning (FR-41); see dev/SKELETON.md "--rescan". |
| `do_dryrun` | Previews a reconcile without applying and returns non-zero on any preflight failure (M3); see dev/SKELETON.md "--dry-run". |
| `do_reapply` | Regenerates the owned set with this build and applies only if the body differs, with no detection and no count gate (FR-39). |
| `render_timer_dropin` | Returns the timer drop-in text for an interval, restating `OnActiveSec` and `OnUnitActiveSec` after the reset (FR-21a); pure. |
| `do_reconfigure` | Writes the rendered drop-in to `dynavlan.timer.d/interval.conf` and runs `daemon-reload`. |
| `config_defaults` | Sets the complete built-in default state; `load_config` calls it first, and `--teardown` calls it again for an invalid config. |
| `check_netplan_version` / `check_apply_prereqs` | The shared netplan version gate, and the `--teardown` gate: root, `ip`, netplan and `netplan try --help`, without detection tools. |
| `teardown_unit_file` | True when the named unit file exists in the etc or lib unit directory; a missing unit counts as disabled and inactive. |
| `teardown_check_posture` / `do_teardown` | The attended `--teardown` (Group 6) and its unit-posture check; see dev/SKELETON.md "--teardown" (tests 1at). |
| `do_status` | Prints one row per owned or detected trunk and returns non-zero when detection is unavailable or incomplete (M8, D5); see dev/SKELETON.md. |
| `main` | Dispatches the mode in the order shown in dev/SKELETON.md "Run lifecycle". |

## Non-script artifacts

| file | one-line purpose |
|------|------------------|
| `dynavlan.conf` | The config template, with every key commented at its default. |
| `dynavlan.service` | The boot oneshot (`--boot`), ordered after networkd, with `TimeoutStartSec=600`. |
| `dynavlan-rescan.service` | The timer-started oneshot (`--rescan`). |
| `dynavlan.timer` | Starts the rescan service from `OnBootSec`, `OnActiveSec` and `OnUnitActiveSec`; the `--reconfigure` drop-in replaces `OnBootSec` (FR-21a). |
| `install.sh` | The root installer: stamps the build id (awk, verify, then `bash -n`; FR-38), installs files, dependencies and persistent journald, and enables units for the next boot without applying. |
| `tests/unit.sh` | The Layer-1 unit suite (sections 1a to 1ay); it sources the script and runs `tests/lifecycle.sh` (§1aq) and `tests/hooks.sh` (§1ax). |
| `tests/lifecycle.sh` | Tests the maintainer scripts and `install.sh` lifecycle against fake `systemctl` and `dpkg`; run from `unit.sh` §1aq. |
| `tests/hooks.sh` | Tests the real `githooks/` hooks and installer through real `git commit` runs in disposable repos; run from `unit.sh` §1ax. |
| `githooks/pre-commit`, `githooks/commit-msg`, `githooks/install.sh` | Check the staged `ver=`/`build=` structure and require a higher `ver=` or a `Version-Bump: none (<reason>)` trailer (FR-38); the installer changes no git config and refuses foreign hooks or `core.hooksPath`. |
