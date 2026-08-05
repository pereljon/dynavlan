# Context Index

Read these live-state files first on every session, in order:
1. context/todo.md - outstanding tasks and current status
2. context/open_questions.md - unresolved questions
3. context/decisions.md - decisions already made (do not re-litigate)

STATE (2026-08-03): dynavlan v0.3.0 released and hardware-validated (restart-on-new-subnet, FR-40:
restart the nominated agent when a new IPv4 subnet appears on any interface, not only on a tagged-VLAN
change; closes the agent-started-before-DHCP boot race and covers access/native ports). Hardware-validated
2026-07-30 on the Protectli box with the real Domotz snap (UniFi + Meraki access, UniFi trunk, boot race).
Prior: all-trunks redesign (v0.2.0) + netplan-get field-order fix (v0.2.1). All tagged, pushed, released
on GitHub. Packaging: `get.sh` (curl one-liner, no arg = latest), `.deb` via GitHub Actions on release.
The v0.3.0 release auto-built and attached `dynavlan_0.3.0_all.deb` (first successful workflow build).
Installing that .deb via `dpkg` was validated on the Domotz box (Ubuntu 22.04), console-backed, 2026-08-03:
install.sh->.deb migration, FR-38 build id, conffile preservation, reboot + boot apply (no-change, no
revert), and real Domotz snap restart all passed. That box is now dpkg-managed (no longer install.sh).

STATE (2026-08-04): v0.4.0 (carrier-down VLAN removal, FR-41) RELEASED. Prunes an owned trunk's
VLANs after a debounced carrier-down loss (boot + rescan), gated on healthy routing; supersedes the
old L3-30 "carrier-pull preserve" result with "carrier-pull prune". Hardware-validated on the
Protectli box, console-driven: all 6 sub-cases PASS (carrier-pull prune, re-plug re-add, flap
preserves, own-uplink-no-redundancy preserves, `--boot` prune, post-boot re-add;
`dev/features/dynavlan-tests.md` L3-30 + 2026-08-04 hardware-run note). Code review (3 reviewers +
a 4-agent adversarial pass) found and fixed FR-41 unreachable-in-its-headline-case (`run_detection`'s
rc could not distinguish a probe failure from a quiet wire; boot/rescan/dry-run branch on
`DETECTED_TRUNKS` instead) plus three more issues (`have_routing` needs a live physical NIC;
rescan re-checks routing after the settle; additions on a mid-sniff-dead trunk are dropped;
`--dry-run` no longer over-lists removals). Tagged/pushed/released `v0.4.0` on pereljon/dynavlan;
GitHub Actions built and attached `dynavlan_0.4.0_all.deb`. The tag was deleted and redone once
during release to fix a stale CHANGELOG line, so `v0.4.0` points at a commit with accurate docs.
An earlier session in this same day also codified a Worktree Policy + Workflow Pipeline in
`CLAUDE.md` (worktree for behavior changes, docs-only stays on `main`, merge-locally default,
tag-time re-verification, release gate on shippable-artifact changes) - see `context/decisions.md`
2026-08-03.

STATE (2026-08-04, later): APT repository hosting (v1.0 gate 2) DONE and LIVE. GitHub Pages +
`reprepro`, signed with a dedicated repo key, rebuilt from release `.deb` assets on every
release; `get.sh` is apt-aware with a tarball fallback. Implemented + code-reviewed (6 findings,
4 CONFIRMED + 2 PLAUSIBLE, all fixed) on branch `feature/apt-repository-hosting`, merged, pushed;
no `ver=` bump. Republished the existing `v0.4.0` release (delete + retag, no new dynavlan
version) to fire `publish-apt` for the first time; hit one undocumented repo-setup gap along the
way - the `github-pages` deployment environment needs its own `v*` **tag** policy (not branch)
under Settings -> Environments, separate from the Pages source setting - fixed via the GitHub
API. Verified live (`https://pereljon.github.io/dynavlan` serves a signed `InRelease`/`Packages`
listing dynavlan 0.4.0) and validated end-to-end on the Domotz test box (keyring + source added,
`apt update`/`apt-cache policy`/`apt install --only-upgrade` all work correctly). Full detail:
`context/decisions.md` 2026-08-04, `context/todo.md` APT repository hosting milestone.

STATE (2026-08-04, v1.0 gate-4 review remediation): working the pre-1.0 adversarial review
(`internal/codex-review-v0-4.md`) via a fix register (`docs/superpowers/plans/2026-08-04-v1.0-gate4-review-fixes.md`).
Unit 1 (doc contradictions) + Unit 2 (M3 dry-run exit code, H7 build-deb version binding, H3 upgrade
timer-state) DONE, HW-validated, merged to main (`4730206`), pushed. Unit 3 (pre-freeze blockers
C2/H2/C1) underway: **C2** (apply-evidence gap on no-addition changes) CODE-COMPLETE + fork-reviewed
on branch `fix/gate4-c2-apply-evidence` (minimal-#1: `APPLY_NOEVIDENCE_SETTLE` floor + exit backstop;
`ver=` 0.4.2; `tests/unit.sh §1y`; rationale in `context/decisions.md` 2026-08-04). C2 hardware
validation (slow removal-only + slow reapply, finalizes the provisional floor) PENDING, then H2, then C1.
NEXT UP: hardware-validate C2 on the Protectli box, then H2 (config isolation) + C1 (routed-mode delete
guard) to close the pre-freeze blockers; v1.0 gates (1)+(2) done, remaining gates are multi-site
validation and the 1.0.0 freeze+review (see `context/todo.md` v1.0 milestone).

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
| `docs/v1.0-definition.md` | Authoritative 1.0 definition: maturity bar, release gates, compatibility policy, out-of-scope |
| `docs/deployment-guide.md` | Deployment guide: install, configure, first attended run, operation, removal |
| `README.md` | Landing page: what the project is and where the docs are |
| `CHANGELOG.md` | What changed per release |
