# Context Index

Read these live-state files first on every session, in order:
1. context/todo.md - outstanding tasks and current status
2. context/open_questions.md - unresolved questions
3. context/decisions.md - decisions already made (do not re-litigate)

CURRENT STATE (2026-10-12) - this paragraph supersedes every dated STATE and NEXT ACTION paragraph below,
which are kept as history. The v1.0 major review's runtime and hardware work is CLOSED with accepted
limitations (D2 retained link, C1 on the shared guard, Gate 3 waived; finding matrix in
docs/hardware-validation.md). `main`, `origin/main` and `release/1.0.0-review` are at `503621b`. The
reference box runs `0.4.22 (build 01e9f98)` at its 14-VLAN baseline. The uncommitted 1.0.0 candidate on
`release/1.0.0-review` (`ver=1.0.0`, script otherwise identical to `01e9f98`; version-gate hooks in
`githooks/`; `COMPATIBILITY.md` final text effective with the 1.0.0 tag) is taking Codex's local
corrections (installer executable-bit and empty `core.hooksPath` fixes, doc wording). NEXT: Codex
closure, then ONE explicit operator approval for R1-R6 (hook install, commit, ff-only merge, push,
v1.0.0 tag and release, console-backed HV-31). Nothing in R1-R6 is authorized yet. HV-31/D3 stays
release-gated.

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

STATE (2026-08-06, gate-4 backlog COMPLETE - pre-hardware-validation): the entire pre-1.0 gate-4 Codex
review backlog is worked. Group 4 contract decisions (H6/M1/M7) shipped as 0.4.4. Group 5: H1 (0.4.5),
H4 + M2 (packaging/CI, no ver bump), H5 (0.4.6), M4 (0.4.7), M5 (0.4.8), M6 (0.4.9), M8 (0.4.10), P3
(0.4.11) - all code-complete, unit-tested, merged to main. PLAUSIBLE items: **P1 CLOSED** (not a defect -
accept cannot gate on a netplan-try exit that only happens post-confirm), **P2 -> HARDWARE** (kill-mid-apply
FIFO-EOF, added to the HV checklist). The injected-command **state-machine test harness is DEFERRED** (not
built: spine already HW-validated + console-backed, cannot reproduce the real netplan-try FIFO/timing anyway,
per-helper units already cover the M-fix decision logic; rationale + a preserved design sketch in
`context/decisions.md` 2026-08-06 + the register). Unit suite **276/0**; main is at **ver 0.4.11**. (Those commits were pushed with the
v0.4.11 release, below; main is now up to date with origin.)
STATE (2026-08-06, later - HV PASSED + v0.4.11 RELEASED): the consolidated gate-4 hardware-validation
pass ran console-backed on the Protectli box (build `b0317b6`, installed from a locally-built `.deb` over
the prior 0.4.2 test build) and PASSED 14/14 targeted checks: build-identity gate, Phase 1 smoke + M8
dep-gate + M5 drain, H5 lease timing (7 leases in one 179ms bounded pass), M6 restart-failure seen-set
(total holds unseen + retries, partial consumes + no storm), P2 kill-mid-apply FIFO-EOF revert (~4.3s
after writer death, box intact), and L3-30 carrier-pull PRUNE + re-add re-confirmed on 0.4.11. Only C1
POSITIVE refusal stays deferred (needs switch access to make a dynavlan VLAN the box default route; its
true-negative was observed live during the prune). Sign-off matrix: `docs/hardware-validation.md`.
Preserve-biased detail found: neither `VLAN_MAX` nor `VLAN_IGNORE` prunes an already-owned VLAN, and
`--reapply` no-ops on a matching on-disk yaml. Docs updated (CHANGELOG retitled `[0.4.11]`, SKELETON P2
EOF status, tests-doc 2026-08-06 run note, this file, todo). **v0.4.11 RELEASED** (docs-only commit on top
of the HW-validated `b0317b6`, so the shipped script is byte-identical to what was validated; `ver=` stays
0.4.11, no bump for the doc commit). The box still runs the 0.4.11 test build; `sudo apt update && apt
upgrade` swaps in the packaged 0.4.11 when the operator is ready. Rescan timer restored to active; config
at defaults.

STATE (2026-08-07, gate-4 freeze artifacts STARTED): began drafting the 1.0.0 config-surface freeze
(gate 4). Three docs-only commits on main plus one script fix, NOT pushed (main 4+ ahead of origin):
(1) `docs/exit-codes.md` - the exit-code table drafted; the full {0,1,2} vocabulary enumerated per mode,
frozen as OPEN-ENDED (consumer treats any unknown non-zero as failure), reverted-apply stays `1` on
observability grounds (Type=oneshot, no OnFailure), NO distinct code 3 for 1.0. (2) **D1 script fix,
`ver=` 0.4.11 -> 0.4.12** (fix/fr22-abort-log-level, merged): the FR-22 zero-detection boot abort logged
at `err` while exiting 0 (err on an intended no-op; do_rescan already logged `info`). Now computes `owned`
first and branches severity - `warning` when preserving owned VLANs behind a quiet wire (the per-trunk
preserve warning is unreachable from the early return), `info` when nothing owned. Exit 0 unchanged. NOT
released (cosmetic, rides the next substantive release); does NOT need its own HV pass (outside the
apply/rollback/detection blast radius). (3) `COMPATIBILITY.md` DRAFT - the deprecate-with-warning contract:
all four surfaces enumerated inline (21 config keys, YAML shape, CLI flags, exit codes -> links
exit-codes.md), integration identifiers frozen (config path, unit/timer names, `dynavlan` syslog id), log
text AND severities declared unfrozen. Marked DRAFT (takes effect at 1.0.0); README cross-link deferred.
All three design rounds ran through an independent Fable-5 adversarial reviewer, which overturned several
first-pass calls (blanket log level; add-code-3; "harden the YAML comparison") and caught real defects in
the COMPATIBILITY draft (BOOT_SETTLE clamp mis-stated, --rescan mis-labeled add-only, enforcement
overclaimed unbuilt hooks) - all fixed. Decisions: `context/decisions.md` 2026-08-07. Then `--help` was
changed to exit **0** (was 2; requested help is success) as **ver 0.4.13** with §1l-bis unit tripwires,
resolving the one open pre-freeze exit-code question. Unit suite **281/0**; main is at **ver 0.4.13**.

STATE (2026-09-05, pre-major-review scoping): no code changed. A conversational external-review pass
(2026-09-04) on the design/fragility questions ahead of the pending 1.0.0 major review produced two
outcomes, both recorded: (1) review-scope + re-litigation-policy decision - the major review covers
`install.sh`/Debian maintainer scripts/systemd units/release workflows alongside `dynavlan`/`tests/unit.sh`,
and documented pre-1.0 decisions stay fixed unless concrete evidence emerges (`context/decisions.md`
2026-09-05); (2) two new open questions - promiscuous-mode lifecycle and detection failure-state exposure
(`context/open_questions.md`) - plus a still-unapplied `dev/CODEMAP.md` doc-drift fix logged in
`context/todo.md` (stale test-section description, duplicated `iface_tags` row, "Token helpers ... pure"
mislabeling two impure functions; applied later in Group 8, 2026-10-08). Session closed out here to start a separate debug coding run.

STATE (2026-09-07 UTC, major-review Group 1 approved locally; Group 0 D2 failed on hardware): the
operator-approved remediation plan is active on `release/1.0.0-review`. Group 1 (D1/L1/L6/L7) is
implemented at `ver=0.4.14` and passed two Codex correction/re-review rounds plus the 312/0 local unit
suite. It is now COMMITTED LOCALLY as `bf59ab0` (code/tests/`dev/` behavior docs; the Group 0
evidence/status commit is `d8d7046`). Both remain unpushed and undeployed; `main`/`origin/main` remain
at `e3f2cef` (`ver=0.4.13`). Group 0 then ran against the clean `0.4.13 (build e3f2cef)` package on the
console-backed hardware box. HV-00 passed. HV-01/D2 failed cleanly: once an isolated-mode candidate
VLAN existed and `netplan try` was alive, `systemctl stop dynavlan-rescan.service` terminated the whole
cgroup; the child did not revert and the unconfirmed candidate remained live and in the owned file.
Codex accepted D2 as a confirmed HIGH defect with potentially CRITICAL impact; no SIGKILL,
routing-breaking, removal, or second destructive reproduction is required. HV-02/D6 and Groups 2-9 are
deferred. Evidence and disposition:
`docs/superpowers/plans/2026-09-07-group0-d2-report-for-codex.md`.

Group 1's pending-delete fail-safe has two DIFFERENT failure modes, which must not be conflated: a
failed current-Netplan **query** preserves the entire pending record untouched and returns non-zero
before any delete is attempted (nothing processed); a failure to persist the **surviving record** after
the retry loop is weaker - the deletes have already run, and the direct `>` write can truncate or partly
rewrite the file, so a still-failing token can be lost and go unretried until reboot. Both return
non-zero and both abort `do_boot`/`do_rescan`, but only the query case can claim "nothing changed".

BOX BASELINE MOVED (2026-09-07): the hardware box now runs the reviewed **0.4.13 (build e3f2cef)**
package - deliberately NOT downgraded after Group 0 - superseding every earlier STATE paragraph that
describes it as running 0.4.11 (or 0.4.2). Note this build PREDATES Group 1's fixes, so the box is not a
valid platform for validating Group 1 behavior until the reviewed build is deployed. Its network state
was restored to the recorded 14-VLAN baseline on 2026-09-07 (owned-file sha256 `c6ce5fb2...f986f8a`,
both default routes intact, timer enabled+active with a finite next elapse, rescan unit reset).

STATE (2026-09-07, Group 3 implemented): Codex directed Group 3 (APT bootstrap and publication) as the
next work, with D2/Group 2/hardware/commit/push all still out of scope. D3 and L4 are implemented in
the tree and COMMITTED LOCALLY as `34bed4e`: the release workflow's cross-job version handoff now travels as an
explicit `build-deb` job output consumed via `needs` (a `steps.*` context is job-local and evaluated
empty, which failed every publish), and `get.sh` no longer destroys a working APT repository
configuration on a transient failure - key/source are staged and moved into place only once written,
pre-existing files are restored byte-for-byte on failure, and files this run created are removed. Two
LOW `pipefail` diagnostics in `get.sh`/`build-deb.sh` were split so a transport failure and an empty
parse stay distinct instead of aborting silently. No `dynavlan` change, so no `ver=` bump. Unit suite
319 -> 346, 0 failures. HV-31 stays release-gated: only a real authorized release can prove D3 fixed.

STATE (2026-10-01, Group 2a D2 implemented locally): Codex approved the D2 graceful-stop design and a scoped
local implementation, now COMMITTED LOCALLY on top of `34bed4e`: `ver=0.4.15`, both service units `KillMode=mixed` +
`TimeoutStopSec=60`, TERM trap in `apply_change` that sets the stop flag and withdraws the unaccepted fifo writer, bounded
child waits, post-ACCEPT partial finish (operator-accepted catch-up limitation, `context/decisions.md`
2026-10-01). 403 unit tests pass; Codex approved the production changes and the tests. D2 closes only after
one benign HV-01 on the corrected artifact (needs operator-authorized hardware). Nothing pushed or deployed.

STATE (2026-10-02, Group 2 upgrade/systemd lifecycle implemented locally): Codex approved the scope with
amendments (new `debian/preinst`, `prerm failed-upgrade`, `postrm` abort cases, `postinst` failure cleanup that
retains the record, validated 3-field record, run-lock wait even with no timer). Implemented:
`ver=0.4.16`, `install.sh` posture restore (D8/L5/L15), `do_reconfigure` propagates a failed daemon-reload (D10),
`tests/lifecycle.sh` (folded into `unit.sh`), 541 tests pass. Codex gave local code/test sign-off 2026-10-02 (the operator accepted the unknown-posture preservation exception); committed locally as `025502d`; not hardware-validated. Nothing pushed. Real dpkg/systemd
behavior is exercised only by the hardware lifecycle cases. Nothing pushed or deployed.

STATE (2026-10-07, Group 4 dry-run/status/subnet reporting implemented locally): within Codex's approved scope and
clarifications. Implemented: `ver=0.4.17`, dry-run follows the real boot decisions (S2 invalid-sample guard,
S3 count gate, L8 copy failure, L9 quiet wire + guarded pending preview), `--status` aggregates detector validity over all
sampled interfaces and prints per-trunk rows (D5/L13), no-target subnets stay unseen (L10, both branches). 594 unit tests
pass; Codex approved it locally 2026-10-07; committed locally as `8f4b581`; not hardware-validated (HV-40..45 on the final build). Nothing pushed.

STATE (2026-10-08, Group 5 configuration grammar implemented locally): scope approved by Codex 2026-10-07. Implemented:
`ver=0.4.18`; canonical decimal numbers, strict `VLAN_IGNORE`, strict quoted values (refuse, name the key, no
migration), `--status` `owned-ignored`/`owned-out-of-range` fields, lexical metric-order wording, config lifecycle wording.
691 unit tests pass; Codex-approved locally 2026-10-08; committed locally as `05a7878`; not hardware-validated (HV-50..53). Nothing pushed.

STATE (2026-10-08, Group 6 removal lifecycle implemented locally): Codex approved `dynavlan --teardown` (Option B) with seven corrections.
Implemented: `ver=0.4.19`; `prerm remove` quiesces then disables the timer and boot service, `postrm purge` also removes the generated timer
drop-in, and the attended `--teardown` mode reuses `apply_change` with an empty target. 785 unit tests pass; Codex-approved locally 2026-10-08
(after a rollback correction); committed locally as `a62f691`; not hardware-validated (HV-60/HV-61). Nothing pushed.

STATE (2026-10-08, Group 7 evidence hardening): tests only (`tests/unit.sh` 1au, 16 tests; one false `1c` row removed); 800 unit tests pass;
Codex-approved locally 2026-10-08; committed locally as `09b23ab`; no `ver=` bump (0.4.19); not pushed, no hardware.

STATE (2026-10-08, Group 8 documentation synchronization in the working tree): Codex approved the scope (D11, D12, D13, S1, L16 plus
Groups 1-7 fallout). Edits are comment/doc/template plus two output strings (install.sh upgrade message, generated timer drop-in comment, with the 1j expectation), so `ver=` 0.4.19 -> 0.4.20 (output wording only). Codex required two rounds of bounded corrections, applied, and approved Group 8 locally 2026-10-08. Committed locally as `6eefdd1`. Not pushed, no hardware.

STATE (2026-10-08, Group 9A local/static gate): Codex approved and closed 9A. Syntax, the 800-test suite, the ShellCheck classification against `e3f2cef`,
workflow bindings, the finding map and a secret/identifier scan passed, and Codex verified the retained clean `.deb` built from `d9b3618`
(0.4.20, build `d9b3618`, 47364 bytes, sha256 `49b8dad493f245bc15e159712ceb7bff60b4143339d8ef2eeb0925a10ab2276e`). This is not hardware validation or release readiness.

HISTORY, superseded by CURRENT STATE above (the next two paragraphs mix 2026-10-08..13 states and are not the active handoff).
Former NEXT ACTION: Groups 1, 3, 2a, 2, 4, 5, 6, 7 and 8 are implemented, Codex-approved locally and committed locally (`bf59ab0`/`d8d7046`,
`34bed4e`, `94ac0a0`, `025502d`, `8f4b581`, `05a7878`, `a62f691`, `09b23ab`, `6eefdd1`); no group is fully hardware-validated (the first hardware batch on 2026-10-09 verified the upgrade, baseline, HV-70 and the graceful-stop protocol; HV-01/D2 is PARTIAL). Group 9A is closed. Group 9B's first batch ran on 2026-10-09 (appliance now `0.4.20 (build d9b3618)`, recovered): HV-01 is PARTIAL (rollback residual, see `context/open_questions.md`), D2 stays OPEN. Further hardware batches are not authorized.
The isolated pre-try validation fix (`ver=0.4.21`, 871 tests, 0 failures) is committed as `72d9eea` (2026-10-12); the clean package (sha256 `6237fc58...b0ff79e`) is deployed and the appliance runs `0.4.21 (build 72d9eea)`. Its HV-01 (2026-10-12) restored the prior owned file and runtime files: D2 is CLOSED; the retained candidate kernel link is an operator-accepted limitation (context/decisions.md 2026-10-12). The box runs 0.4.21 at its recovered 14-VLAN baseline. Hardware batch 2 (2026-10-12, runbook steps 4-6): 13 cases PASS, HV-41 FAIL (LLDP daemon-down reads as empty; fails safe; open question); HV-41 and two LOW wording findings fixed in `01e9f98` (`ver=0.4.22`, 885/0). Hardware batch 3 (2026-10-13, runbook steps 7-10 plus the HV-41 recheck) passed every run case; C1 accepted on the HV-61 shared-guard refusal (switch-induced `--boot` not exercised) and the reinstall posture documented (context/decisions.md 2026-10-13); the box runs 0.4.22 (`01e9f98`) at its baseline. The v1.0 review's remediation and hardware work is closed (finding matrix: docs/hardware-validation.md). Merged and pushed (`503621b`). The 1.0.0 candidate (hooks, `ver=1.0.0`, final compatibility text, supported platforms) is prepared locally and uncommitted; remaining: Codex review, then one operator approval for hook install, commit, merge, push, the v1.0.0 release and HV-31 (Gate 3 waived for 1.0, 2026-10-13).
HV-31 is release-gated; `COMPATIBILITY.md` stays DRAFT; the version-gate hooks are outstanding (second-site validation waived for 1.0, 2026-10-13). No push, merge, or release is needed or
authorized for 9B, and further commits need explicit approval. Per-item status: `context/todo.md`; full sequence:
`docs/superpowers/plans/2026-09-05-v1.0-major-review-remediation.md`.

Before coding a change, read in order:
4. dev/SKELETON.md - logic flow and key invariants
5. dev/CODEMAP.md - where things live (per-function map)
6. docs/dynavlan-PRD.md - authoritative requirements (FR/NFR/AC)
7. dev/features/dynavlan.md - technical design: architecture, partial backend seam, apply/rollback state machine
8. dev/features/dynavlan-tests.md - test plan (unit asserts, --dry-run, hardware checklist)

These files are the project's working memory; keep them current.

## File roles

Each file gets one clear role; keep this table current.

| File | Purpose |
|------|---------|
| `AGENTS.md` | Conventions, checklists, guardrails for working in this repo (shared rules in `../AGENTS.md`) |
| `context/index.md` | Read-order and file-role map for a fresh session; pointers to the live-state files |
| `context/todo.md` | Outstanding tasks and their state (source of truth for project status) |
| `context/decisions.md` | Dated log of decisions made and rejected |
| `context/open_questions.md` | Unresolved questions with status and resolution path |
| `dev/CODEMAP.md` | Where things live: per-function purposes, for locating code |
| `dev/SKELETON.md` | How it works: logic flow and key invariants (incl. the hardware-validated behaviors) |
| `dev/features/dynavlan.md` | Technical design: architecture, partial backend seam, apply/rollback state machine, module decomposition, systemd/install layout |
| `dev/features/dynavlan-tests.md` | Test plan: unit assert cases, `--dry-run` verification, hardware integration checklist |
| `docs/dynavlan-PRD.md` | Product requirements: authoritative FR/NFR/AC with severity+impact tags |
| `COMPATIBILITY.md` | The 1.x compatibility contract (final text, effective with the 1.0.0 tag): config keys, YAML shape, CLI flags, exit codes |
| `docs/exit-codes.md` | Exit-code inventory by mode and the frozen table |
| `docs/hardware-validation.md` | Validated hardware, the console-backed validation record, and the pending final-build pass |
| `docs/positioning-brief.md` | Positioning and audience notes (not behavior) |
| `docs/v1.0-definition.md` | Authoritative 1.0 definition: maturity bar, release gates, compatibility policy, out-of-scope |
| `docs/deployment-guide.md` | Deployment guide: install, configure, first attended run, operation, removal |
| `README.md` | Landing page: what the project is and where the docs are |
| `CHANGELOG.md` | What changed per release |
