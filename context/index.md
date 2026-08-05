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
C2/H2/C1) ALL THREE code-complete + fork-reviewed (no CRITICAL/HIGH/MEDIUM) and MERGED to main as
`ver=0.4.2` (C2 `27f545a`, H2 `6cd7efb`, C1 `42c917d`; 213 unit tests, 0 failures): **C2** apply-evidence
(`APPLY_NOEVIDENCE_SETTLE` floor + exit backstop, §1y), **H2** config isolation (parse-only allowlist
`config_load_file`, §1z), **C1** routed-mode default-route delete guard (`default_iface_in_removals`,
§1aa). Rationale in `context/decisions.md` 2026-08-04/05. HARDWARE-VALIDATED on the Protectli box
2026-08-05: **C2** fully validated (two no-addition `--reapply` applies accepted; isolation revert timed
at 18.2s = the floor-16 prediction, uplink primary throughout; `APPLY_NOEVIDENCE_SETTLE=16` FINALIZED by
measurement), **H2** smoke-validated (real `/etc/dynavlan.conf` parses under `config_load_file`), **M3**
re-confirmed (dry-run exit 0). **C1** unit+review validated and its live dry-run preview confirmed
correctly-absent (no false positive). Later that day the operator toggled the enp1s0 switch port, giving
a genuine carrier-down removal: **C2** got its real removal-only apply (`--rescan` removed 7 VLANs at a
measured **18.19s** applying->ACCEPTED = the floor-16 prediction, closing the register's "console slow
removal-only" need), and **C1** got a live **true-negative** (snap_iface=enp2s0, not in the removal set
-> guard correctly SILENT, legitimate removal proceeded). The faithful C1 POSITIVE refusal (a routed VLAN
that IS the default being removed) still needs switch access and stays deferred. The box now runs 0.4.2
(installed as the service binary, build source; apt metadata still 0.4.1 - restored on the next apt
install; operator will reinstall from apt when ready); enp1s0 currently off (7 VLANs on enp2s0), timer
active. **v0.4.2 RELEASED 2026-08-05** (tag `v0.4.2`, main pushed at `2a1880e`, GitHub release published
on `pereljon/dynavlan`; the release workflow builds the `.deb` + updates the APT repo). CHANGELOG
retitled `[0.4.2]`. The box still runs the 0.4.2 `build source` test build; now that v0.4.2 is released,
`sudo apt update && sudo apt upgrade` on the box replaces it with the packaged 0.4.2 (operator will do
this when ready). enp1s0 currently off by the operator (7 VLANs on enp2s0); re-enabling re-adds them.

SESSION HANDOFF - NEXT UP (gate-4 review is NOT fully done; register groups 1-3 done, 4-5 remain):
Read `docs/superpowers/plans/2026-08-04-v1.0-gate4-review-fixes.md` (the fix register) for full detail.
Remaining Codex findings, in the register's suggested order:
- **Group 4 - contract decisions the register wants BEFORE the 1.0 freeze:** H6 (15-char `enx<mac>`
  iface names can't form a legal VLAN name - IFNAMSIZ; touches the generated-interface-name contract),
  M7 (`VLAN_LIMIT_MODE=fill` selects lexicographic not lowest-numeric ids), M1 (punctuation in iface
  names aliases state). These need a design call.
- **Group 5 - robustness:** H1 (detector failures become partial evidence, can authorize removals,
  off-Meraki), H4 (Debian upgrade proceeds after lock fail), H5 (sequential lease waits exceed systemd
  timeouts, skip restart), M2/M4/M5/M6/M8, plus building the injected-command state-machine test harness
  the register scopes.
- **P1-P3** (netplan-try nonzero-exit-after-FIFO-write - my C2 backstop LOGS it but doesn't un-accept;
  FIFO-EOF over-assertion; equal-metric health order-dependence) and **HV-1** (fresh apt install starts
  the timer; pre-existing, `context/open_questions.md`).
- **Deferred HW test:** faithful C1 POSITIVE refusal (routed VLAN that IS the default being removed)
  needs switch access to set up (`context/open_questions.md`).
Then the 1.0.0 freeze+review itself. v1.0 gates (1)+(2) done; remaining gates are multi-site validation
and the freeze. START a fresh session for group 4 (session hygiene - this session is long).

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
