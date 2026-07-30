# Changelog

Format: Keep a Changelog. Add bullets under `## Unreleased`; on release, retitle that section to `## [x.y.z] - YYYY-MM-DD`.

## Unreleased

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
