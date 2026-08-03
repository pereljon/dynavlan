# Context Index

Read these live-state files first on every session, in order:
1. context/todo.md - outstanding tasks and current status
2. context/open_questions.md - unresolved questions
3. context/decisions.md - decisions already made (do not re-litigate)

STATE (2026-07-30): dynavlan v0.3.0 released and hardware-validated. v0.3.0 is restart-on-new-subnet
(FR-40): restart the nominated agent when a new IPv4 subnet appears on any interface, not only on a
tagged-VLAN change - closes the agent-started-before-DHCP boot race and covers access/native ports.
Hardware-validated 2026-07-30 on the Protectli box with the real Domotz snap (UniFi + Meraki access,
UniFi trunk, boot race). Prior: all-trunks redesign (v0.2.0) + netplan-get field-order fix (v0.2.1).
All tagged, pushed, released on GitHub. Packaging: `get.sh` (curl one-liner, no arg = latest), `.deb`
via GitHub Actions on release. The v0.3.0 release auto-built and attached `dynavlan_0.3.0_all.deb`
(first successful workflow build). Installing that .deb via `dpkg` was validated on the Domotz box (Ubuntu 22.04),
console-backed, 2026-08-03: install.sh->.deb migration, FR-38 build id, conffile preservation, reboot + boot apply
(no-change, no revert), and real Domotz snap restart all passed. That box is now dpkg-managed (no longer install.sh).

Before coding a change, read in order:
4. dev/SKELETON.md - logic flow and key invariants
5. dev/CODEMAP.md - where things live (per-function map)
6. docs/dynavlan-PRD.md - authoritative requirements (FR/NFR/AC)
7. dev/features/dynavlan.md - technical design: architecture, backend seam, apply/rollback state machine
8. dev/features/dynavlan-tests.md - test plan (unit asserts, --dry-run, hardware checklist)

These files are the project's working memory; keep them current.

## File roles

Each file gets one clear role; keep this table current.

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Conventions, checklists, guardrails for working in this repo |
| `context/index.md` | Read-order and file-role map for a fresh session; pointers to the live-state files |
| `context/todo.md` | Outstanding tasks and their state (source of truth for project status) |
| `context/decisions.md` | Dated log of decisions made and rejected |
| `context/open_questions.md` | Unresolved questions with status and resolution path |
| `dev/CODEMAP.md` | Where things live: per-function purposes, for locating code |
| `dev/SKELETON.md` | How it works: logic flow and key invariants (incl. the hardware-validated behaviors) |
| `dev/features/dynavlan.md` | Technical design: architecture, backend seam, apply/rollback state machine, module decomposition, systemd/install layout |
| `dev/features/dynavlan-tests.md` | Test plan: unit assert cases, `--dry-run` verification, hardware integration checklist |
| `docs/dynavlan-PRD.md` | Product requirements: authoritative FR/NFR/AC with severity+impact tags |
| `docs/deployment-guide.md` | Deployment guide: install, configure, first attended run, operation, removal |
| `README.md` | Landing page: what the project is and where the docs are |
| `CHANGELOG.md` | What changed per release |
