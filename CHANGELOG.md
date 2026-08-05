# Changelog

Format: Keep a Changelog. Add bullets under `## Unreleased`; on release, retitle that section to `## [x.y.z] - YYYY-MM-DD`.

## Unreleased

### Fixed

- A capture method that **fails** at runtime (tcpdump cannot open the device or the
  BPF filter is rejected, `lldpctl`'s daemon is down, or promisc could not be set)
  no longer reads as a genuinely empty trunk and can no longer authorize a boot
  detection-diff removal. Detection now carries a per-interface validity verdict;
  the `RESET_ON_BOOT` removal path preserves all owned VLANs on a trunk (with a
  warning) when either pass's sample is untrustworthy. Additions still proceed on
  whatever positive evidence exists. Under the default `DETECT_METHOD=both`, only
  the primary **sniff** must have succeeded (a failed sniff is the actual removal
  hazard); LLDP is a supplement, so a down `lldpd` does not block removals
  (gate-4 H1). (`ver=` 0.4.4 -> 0.4.5.)
- `VLAN_LIMIT_MODE=fill` now keeps the lowest-**numeric**-id VLANs, matching the
  documented "lowest IDs" contract. It previously selected by lexicographic token
  order, so with VLANs 2/10/100 it kept 10 and 100 before 2 (gate-4 M7). (`ver=`
  0.4.3 -> 0.4.4.)
- A physical NIC whose name plus the `.<vlan-id>` suffix would exceed the 15-char
  kernel limit (IFNAMSIZ) - e.g. the MAC-derived `enx001122334455` - is no longer
  provisioned into an interface the kernel would reject; the over-long VLANs are
  skipped with a warning naming them (gate-4 H6). Full support for such NICs via
  generated short names is a post-1.0 item.
- Interface names containing `.` are refused at discovery (a dotted parent is
  ambiguous with dynavlan's own `<parent>.<id>` VLAN separator and could not
  round-trip in owned-state, provisioning once then vanishing). `-`/`_` remain
  supported and are now handled by an injective interface-key map, so names like
  `enp-1`/`enp_1` no longer alias to one another (gate-4 M1). Standard predictable
  and legacy NIC names are unaffected (they contain none of these characters).

### Removed

- `PER_VLAN_MAC` config key. It was reserved but never implemented: the only
  thing it ever did was refuse `true`. Rather than freeze that dead surface
  into the 1.0 config contract, it is removed. Per-VLAN MAC derivation stays a
  post-1.0 item (G-4); any future implementation adds its own key. `debian/postinst`
  neutralizes an uncommented `PER_VLAN_MAC=` line in an existing conffile on
  upgrade, so the removal cannot make a box refuse its own config. (`ver=` 0.4.2 -> 0.4.3.)

## [0.4.2] - 2026-08-05

### Added

- Public APT repository (GitHub Pages + `reprepro`, signed with a dedicated
  repo key) so `sudo apt update && sudo apt upgrade` picks up new dynavlan
  releases. Rebuilt from the GitHub release `.deb` assets on every release
  (nothing stored in git); manual/attended upgrades only by design, not
  structured for unattended-upgrades. `get.sh` is now apt-aware (adds the
  repo + installs via apt when apt/dpkg is present) and falls back to the
  existing tarball + `install.sh` path otherwise, or if the repo isn't
  reachable. No `ver=` bump - the `dynavlan` script itself is untouched.

### Fixed

- Apply-evidence gap on no-addition changes (C2): a removal-only reconcile or
  `--reapply` could ACCEPT a `netplan try` on elapsed time, sampling pre-apply
  routing on a slow apply. These changes have no in-kernel signal to observe
  (netplan try does not delete removed netdevs; a rerender changes no kernel
  state), so they now use a larger, bounded settle floor
  (`APPLY_NOEVIDENCE_SETTLE`) sized so the first health sample lands post-apply,
  and netplan try's exit is logged on both accept and revert paths instead of
  discarded. Additions are unchanged. (`ver=` 0.4.1 -> 0.4.2.)
- Config is now parsed declaratively instead of `source`d (H2). A line in
  `/etc/dynavlan.conf` could previously assign any internal/safety variable
  (`NETPLAN_FILE`, `TRY_TIMEOUT`, `ver`, `PATH`, ...) or execute arbitrary shell,
  because the file was sourced and only the documented keys' *values* were
  validated. `load_config` now honors only allowlisted `KEY=value` lines for the
  documented keys; an unknown/protected key or non-assignment line refuses the
  run, and values are assigned as inert literals (no code execution). The config
  surface is now exactly the documented keys. (`ver=` 0.4.1 -> 0.4.2.)
- Routed-mode default-route delete guard (C1). In routed mode (`VLAN_ROUTES=true`)
  a dynavlan VLAN can be the box's default egress. Removing it would strand the
  box: the `ip link delete` runs only after `netplan try` ACCEPTs, and the health
  check PASSes during the try (the VLAN is still up), so the delete tears down the
  default route post-ACCEPT with no revert. `apply_change` now refuses the whole
  reconcile before any disk change when the current default-route interface is in
  the removal set, preserving it and changing nothing until an alternate default
  exists; `--dry-run` previews the refusal. No-op at the default `VLAN_ROUTES=false`
  (the default is always the base uplink, never a dynavlan VLAN). (`ver=` 0.4.1 -> 0.4.2.)
- `--dry-run` now exits non-zero when `netplan generate` rejects the candidate
  config; it previously printed `validate: FAIL` but exited 0, so a scripted or
  attended pre-flight keying on `$?` could not tell a bad config from a good one.
  The printed line and `VALIDATE_ERRSRC` still distinguish our-YAML from a
  pre-existing base-file error. (`ver=` 0.4.0 -> 0.4.1.)
- Debian upgrades preserve the operator's timer/service state instead of
  unconditionally re-enabling and starting the timer on every configure. `prerm`
  records the prior enabled/active state before stopping; `postinst` restores it,
  so an upgrade never re-arms a `dynavlan.timer` the operator deliberately
  disabled. First install is unchanged (enable for next boot, never start). On
  the first upgrade FROM a pre-fix package the outgoing `prerm` cannot record
  state, so `postinst` falls back to live `is-enabled` (which `stop` does not
  clear) for the enable dimensions and infers the running-state from enablement:
  an enabled timer is assumed to have been running, a disabled timer is never
  started (`tmr_active` follows `tmr_enabled`). Hardware-validated (L3-37),
  including the transitional disabled case.
- `build-deb.sh` refuses to build when the requested version (the release job
  passes the git tag) differs from the script's `ver=`, so a tag that outran a
  `ver=` bump fails the build instead of publishing a package whose `--version`
  disagrees with its label (FR-38). Checked before the `dpkg-deb` requirement so
  the version mismatch is the reported failure.

## [0.4.0] - 2026-08-04

### Added

- Carrier-down VLAN removal (FR-41). When an owned trunk's physical link stays carrier-down across a two-sample debounce (`BOOT_SETTLE_SECONDS` apart) - at boot or on the rescan timer - and the box still has a healthy default route, dynavlan removes all owned VLANs on that trunk through the standard validated + health-gated + auto-reverting apply chain. A carrier-down port cannot pass frames, so this is a full teardown of the trunk's set, not a per-VLAN detection diff. Independent of `RESET_ON_BOOT`: governed solely by new config key `REMOVE_ON_CARRIER_LOSS` (default `true`), so a `RESET_ON_BOOT=false` box still self-heals a dead trunk. Rescan (previously strictly add-only) gains its first removal path; the settle sleep is incurred only when an owned trunk is actually carrier-down, so the steady-state fast path is unchanged. Narrows the prior preservation invariant: preservation now protects only genuine detection uncertainty (carrier-up, no tags) - carrier-down is authoritative kernel evidence and is no longer blanket-preserved. `--dry-run` previews a would-be teardown; `--status` reports carrier state per owned trunk. Two new pure helpers: `carrier_removals` (the debounce decision) and `have_routing` (the routing pre-condition - a carrier-down trunk that doubles as the box's own uplink, with no redundant route, is preserved rather than attempted). `have_routing` requires a lowest-metric default route, carrier on its egress iface, AND carrier on at least one physical NIC; the last clause keeps a tun/wireguard default route - those netdevs report carrier whenever merely configured up - from making an all-dark box look routable, while still allowing pruning on a box that legitimately routes over a VPN atop a live uplink. A zero detection no longer aborts the boot/rescan run: `run_detection` returns non-zero if and only if it saw nothing, so an rc-based abort could not distinguish a probe failure from a quiet wire and suppressed FR-41 in its own headline case (every owned trunk unplugged, leaving nothing to detect). A `BOOT_SETTLE_SECONDS` below 5 is clamped to 5 for the carrier samples only (and only while the knob is on): back-to-back samples cannot tell a port bounce from a sustained loss, and clamping rather than rejecting avoids turning an already-deployed conffile into a boot-time config failure. **Supersedes** the hardware-validated v0.2.0 "L3-30 carrier-pull preserve" result with a revised "carrier-pull prune" case (`dev/features/dynavlan-tests.md`). Hardware-validated 2026-08-04 on the Protectli box, all 6 L3-30 sub-cases PASS: carrier-pull prune, re-plug re-add, flap-shorter-than-settle preserve, own-uplink-no-redundancy preserve, `--boot` prune, post-boot re-add.

## [0.3.0] - 2026-07-30

### Added

- Restart on a newly-appeared IPv4 subnet (FR-40). Previously, dynavlan only restarted `RESTART_SNAPS`/`RESTART_SERVICES` on a tagged-VLAN change, so two cases were missed: an access port or native-only trunk that gets a DHCP lease after boot (no tagged VLAN, so nothing changes), and the monitoring agent starting before the base interface finishes DHCP (dynavlan's boot run is deliberately not ordered after `network-online.target`). Both are the same underlying problem: the agent cares about IPv4 subnets it can scan, not VLAN tags. New pure helper `ipv4_network` keys subnet tokens on the network address, not the host address, so a same-pool DHCP renewal never restarts; a monotonic per-uptime seen-set at `/run/dynavlan/seen` (wiped on reboot) means a flap back onto an already-seen subnet doesn't either, and an empty seen-set at boot restarts once after settle regardless of boot-vs-DHCP ordering. At most one restart per run, deduped against any VLAN-driven restart. New config key `RESTART_ON_NEW_SUBNET` (default `true`). `--dry-run`/`--status` report the would-restart delta without restarting or writing the seen-set. `apply_change` is unchanged; the growth-check is an additive post-step called from `main` after every `--boot`/`--rescan` exit, regardless of that mode's own return code.

## [0.2.1] - 2026-07-30

### Fixed

- `backend_list_managed_vlans` awk assumed `link:` precedes `id:` in `netplan get` output, but netplan 0.107 emits `id:` first. The netplan-get exclusion source silently returned nothing, falling back to `ip -d link` single-source (FR-10 degraded). Found in code review; verified on hardware. 3 tests added.

## [0.2.0] - 2026-07-30

### Added

- **All-trunks provisioner** (redesign): dynavlan now provisions VLANs on every carrier-up trunk with detected tags, not one selected trunk. A box with two live trunks (validated: `enp1s0` and `enp2s0`, each with a different native VLAN, one VLAN id tagged on both) gets both provisioned in one reconcile. The universal token for every set downstream of detection is now `iface.id` (e.g. `enp1s0.100`), not a bare VLAN id: bare ids alias across parents the moment two trunks share an id. New pure token helpers: `emit_tokens`, `tok_iface`, `tok_id`, `tag_tokens`, `untag_tokens`, `tokens_for_iface`, `distinct_ifaces`. `do_boot`/`do_rescan`/`do_dryrun` loop per-trunk candidate/removal math over the union of owned and detected trunk interfaces, tag each trunk's result to tokens, then combine into one token set and make a single unified `apply_change`/`netplan try` call for the whole box. Hardware-validated 2026-07-30 (L3-29 dual leasing, L3-30 carrier-pull preserve, L3-31 routed multi-trunk, L3-32 unified revert, all PASS).

- `dynavlan --reapply` (FR-39). Regenerates the owned set with the running build and applies it only if the generated body differs from what is on disk, through the full `netplan try` + health-check chain. Runs no detection (pinned to the owned parent), never adds or removes a VLAN, lease-waits the entire owned set before restarting targets, bypasses the count gate, and blocks on the run lock rather than reporting a misleading rc-0 "skipped." The comparison ignores line 1 (version/build header), so an FR-38 build stamp change alone cannot force a no-change apply. Refuses if it generates a candidate config it cannot read back.

- `dynavlan --version` (alias `-V`) and install-stamped build identity (FR-38). Prints `dynavlan <ver> (build <commit>)` and exits before the config load and root check, so it works when the config is invalid or the caller is unprivileged. `install.sh` stamps the source checkout's short commit, suffixed `-dirty` when the tree has uncommitted changes. The same string appears on every `run start:` journal line and in the generated netplan file's header.

- Opt-in routed mode (FR-37): `VLAN_ROUTES=true` accepts DHCP routes on discovered VLANs at per-VLAN metrics; `VLAN_ROUTE_METRIC_START` (default 100), discovery-order assignment shared across the whole box (existing VLANs never renumber, persisted in the owned YAML). Refuses up front if any assigned metric would match or beat the uplink default's metric. DNS/NTP/domains stay declined in both modes.

### Changed

- `backend_owned_vlans`/`backend_owned_metrics` now parse `iface.id` stanza headers across however many parents the owned file spans. `backend_list_managed_vlans` takes an `iface` argument and is scoped per trunk. `plan_route_metrics`/`assign_route_metrics`/`map_filter`/`metric_conflict`/`map_ids` all operate on `iface.id:metric` maps rather than bare-id maps.

- `VLAN_MIN` default is now 1 (was 2). The old default encoded "VLAN 1 is the switch management VLAN" as if it were a fact about the wire; a validated Meraki trunk broke it in both directions. `VLAN_IGNORE` remains the way to skip specific IDs.

- `RESTART_SNAPS` default is now empty (was `domotzpro-agent-publicstore`); the Domotz agent snap is the documented example, not a baked-in default.

- Install docs recommend `sudo bash install.sh` over `sudo ./install.sh`. Transfers that do not carry Unix modes strip the executable bit; invoking the interpreter is immune.

- `--dry-run` now takes the run lock non-blocking: holds it during the preview if free; warns and proceeds read-only if a run is already in progress.

- Positioning reframes dynavlan from a single-trunk monitoring provisioner toward a general dynamic-VLAN provisioner with a monitoring origin; isolation stays the default, routed mode is first-class.

### Removed

- `select_trunk` and its hysteresis contest. There is no longer a "which NIC is the trunk" decision.

- AC-3 relocation branch: a trunk that goes dark has its owned VLANs preserved, never torn down and rebuilt on a different NIC.

- `VLAN_ROUTE_METRIC_MODE` (and its `id` mode). Metric assignment is discovery-order only, since a stateless START+id scheme has no coherent meaning once VLAN ids are no longer globally unique keys.

- Domotz-on-Ubuntu deployment runbook and base-deployment spec (`docs/deployment-guide.md` rewritten as the dynavlan deployment guide; `dev/IMPLEMENTATION-SPEC.md` deleted).

### Fixed

- Routed mode (FR-37) could only be enabled on a box that already owned VLANs. `apply_change` passed additions to `assign_route_metrics`, but the correct set is "target ids without a metric." Assignment now lives in one pure `plan_route_metrics` that every caller must use. No stranding risk: the refusal preceded `netplan try`.

- `lldp_tagged_vlans` matched any key ending in `.vlan-id=` / `.pvid=yes` rather than the VLAN TLV's `.vlan.` subtree. A foreign key inside a VLAN block flushed the real id as "tagged" before its `pvid=yes` was seen, and leaked the foreign key's value as a candidate. Patterns now anchor on `.vlan.vlan-id=` / `.vlan.pvid=yes`; two regression cases added.

- LLDP detection ingested the native/pvid VLAN as if it were tagged (FR-7a). New pure helper `lldp_tagged_vlans` correlates each `vlan-id` with its adjacent `pvid` and drops the native VLAN. Found on hardware (Meraki trunk advertising pvid 100).

- VLANs accepted IPv6 Router Advertisements (FR-14a), so "fully route/DNS-isolated" was only true for IPv4. networkd accepts RAs by default; a VLAN could acquire a SLAAC address and a default route invisible to the FR-18 health check. Every generated VLAN now carries `accept-ra: false`. Found on hardware.

- Detection counted the box's own transmitted frames, making it self-fulfilling (FR-5a). The sniff now uses `-Q in`; missing `-Q` support is a refuse-to-run precondition. Found on hardware.

- Rescan timer never fired, on any install (FR-21a). `--reconfigure` rendered a drop-in that cleared `OnUnitActiveSec`, which in systemd resets the entire monotonic timer list. The drop-in now restates every trigger using `OnActiveSec`. Found on hardware.

- `install.sh` could replace `/usr/local/sbin/dynavlan` underneath a running invocation. The installer now stops `dynavlan.timer` for the duration and takes the FR-30 lock before touching the script.

- FR-0 netplan version precondition refused to run on every target box. `netplan --version` only exists on >= 1.0; the validated baseline ships 0.10x. Version discovery now falls back to `dpkg-query -W netplan.io`.

- `restore_prior` now checks its copy-back and logs `err` naming the surviving backup on failure.
