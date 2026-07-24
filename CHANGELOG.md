# Changelog

Format: Keep a Changelog. Add bullets under `## Unreleased`; on release, retitle that section to `## [x.y.z] - YYYY-MM-DD`.

## Unreleased

- Changed: `RESTART_SNAPS` default is now empty (was `domotzpro-agent-publicstore`); the Domotz agent snap is the documented example, not a baked-in default. Set it explicitly per deployment.
- Removed: the Domotz-on-Ubuntu deployment runbook and base-deployment spec (`docs/deployment-guide.md` rewritten as the dynavlan deployment guide; `dev/IMPLEMENTATION-SPEC.md` deleted). The project is dynavlan; Domotz remains only as the restart-target example.

- Added: opt-in routed mode (FR-37): `VLAN_ROUTES=true` accepts DHCP routes on discovered VLANs at per-VLAN metrics; `VLAN_ROUTE_METRIC_START` (default 100) and `VLAN_ROUTE_METRIC_MODE` (`discovery` = order found, existing VLANs never renumber, persisted in the owned YAML; `id` = START + VLAN id, stateless). Refuses up front if any assigned metric would match or beat the uplink default's metric. DNS/NTP/domains stay declined in both modes. Default remains fully route-isolated.

- Fixed: `restore_prior` now checks its copy-back and logs `err` naming the surviving backup on failure (silent disk/live divergence on the revert path was possible under disk pressure) (round-4 review).
- Changed: `--dry-run` now takes the run lock non-blocking - holds it during the preview if free (a mid-preview timer rescan skips normally); warns and proceeds read-only if a run is already in progress (round-4 review).
