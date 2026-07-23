# Changelog

Format: Keep a Changelog. Add bullets under `## Unreleased`; on release, retitle that section to `## [x.y.z] - YYYY-MM-DD`.

## Unreleased

- Fixed: `restore_prior` now checks its copy-back and logs `err` naming the surviving backup on failure (silent disk/live divergence on the revert path was possible under disk pressure) (round-4 review).
- Changed: `--dry-run` now takes the run lock non-blocking - holds it during the preview if free (a mid-preview timer rescan skips normally); warns and proceeds read-only if a run is already in progress (round-4 review).
