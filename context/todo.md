# todo - outstanding tasks and their state

Owns: open tasks and their status. Does NOT hold permanent facts or decisions (those live in dev/ docs and context/decisions.md).
Maintain: update whenever a task is added, changes state, or completes.
Entry format: `- [ ] task`  /  done: `- [x] task (done YYYY-MM-DD)`

## Current state (2026-07-30)

v0.2.1 released and hardware-validated. 132 tests, 0 failures. Script ~1700 lines.

Commits on main since the all-trunks redesign:
- `18f58ef` feat: all-trunks provisioner redesign (v0.2.0)
- `1cd76db` fix: backend_list_managed_vlans awk assumed link: before id: (v0.2.1)
- `570cd23` docs: record hardware validation results (L3-29..L3-32 all PASS)
- `44cc5c4` docs: reformat CHANGELOG for v0.2.1 release
- `ee8dfb6` docs: trim README status block for v0.2.1 release
- `235970f` feat: add one-line curl installer (get.sh)
- `0815ce7` feat: add .deb packaging and GitHub Actions release workflow

Release: v0.2.1 tagged + pushed + GitHub release created on pereljon/dynavlan.

## Completed milestones

- [x] All-trunks provisioner redesign (v0.2.0, done 2026-07-30)
- [x] Hardware validation: L3-29 dual leasing, L3-30 carrier-pull preserve, L3-31 routed multi-trunk, L3-32 unified revert (done 2026-07-30)
- [x] Code review fix: netplan-get field-order bug (v0.2.1, done 2026-07-30)
- [x] v0.2.1 release: CHANGELOG reformatted, tagged, GitHub release created (done 2026-07-30)
- [x] One-line curl installer: get.sh (done 2026-07-30)
- [x] .deb packaging: debian/, build-deb.sh, GitHub Actions workflow (done 2026-07-30)
- [x] GitHub repo description updated for multi-trunk positioning (done 2026-07-30)

## Next steps (not started)

- [ ] Test .deb build end-to-end: trigger by creating a release (or run build-deb.sh on an Ubuntu box)
- [ ] APT repository: host a signed repo so `apt upgrade` picks up new versions (Launchpad PPA, GitHub Pages + reprepro, or packagecloud.io)
- [ ] Git hooks for version gate enforcement (see open_questions.md, designed but not built)
- [ ] IPv6 health-check arm (deferred from FR-14a; required before any future IPv6 route acceptance)
- [ ] Non-Meraki switch validation (sniff-primary proven only on Meraki; LLDP coverage varies by vendor)
- [ ] G-4: per-VLAN MAC derivation (low priority, PER_VLAN_MAC default off)
- [ ] Automatic config-drift detection on boot/rescan (deferred until a second box exists)

## Positioning (internal, not committed)

- `docs/positioning-brief.md` (untracked) - initial brief on market gap, objections, competitive landscape
