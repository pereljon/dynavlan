# todo - outstanding tasks and their state

Owns: open tasks and their status. Does NOT hold permanent facts or decisions (those live in dev/ docs and context/decisions.md).
Maintain: update whenever a task is added, changes state, or completes.
Entry format: `- [ ] task`  /  done: `- [x] task (done YYYY-MM-DD)`

## Current state (2026-08-04)

See `context/index.md` STATE line for the authoritative up-to-date summary (kept current
there to avoid two places drifting). As of this date: v0.4.0 (carrier-down VLAN removal,
FR-41) RELEASED - hardware-validated (6/6 L3-30 sub-cases PASS), tagged, pushed, GitHub
release created with `.deb` auto-built and attached by Actions (see the v0.4.0 milestone
below). v0.3.0 (restart-on-new-subnet) also released, prior to this. Superseded, kept for history:
v0.2.1 was released and hardware-validated with 132 tests, ~1700 lines, on the commits
below.

Commits on main since the all-trunks redesign (historical, through v0.2.1):
- `18f58ef` feat: all-trunks provisioner redesign (v0.2.0)
- `1cd76db` fix: backend_list_managed_vlans awk assumed link: before id: (v0.2.1)
- `570cd23` docs: record hardware validation results (L3-29..L3-32 all PASS)
- `44cc5c4` docs: reformat CHANGELOG for v0.2.1 release
- `ee8dfb6` docs: trim README status block for v0.2.1 release
- `235970f` feat: add one-line curl installer (get.sh)
- `0815ce7` feat: add .deb packaging and GitHub Actions release workflow

Release: v0.2.1 tagged + pushed + GitHub release created on pereljon/dynavlan.

## Outstanding (see `context/index.md` SESSION HANDOFF for detail)

- [ ] Gate-4 Codex review backlog (register groups 4-5). GROUP 4 (pre-freeze contract decisions) DECIDED + CODE-COMPLETE 2026-08-05 as ver 0.4.4 (H6 refuse over-IFNAMSIZ names + document/defer generated short-names; M1 refuse `.` + injective `iface_key`; M7 `fill` selects lowest NUMERIC id; 224 unit tests, 0 failures) - H6 not yet HW-validated (Protectli uses short `enp` names). GROUP 5 in progress (all merged to main 2026-08-05): H1 CODE-COMPLETE as ver 0.4.5 (detector-failure guard: a failed sniff/LLDP/promisc no longer reads as an empty trunk and cannot authorize a boot detection-diff removal; under default `both`, sniff-ok suffices - Option B; 239 unit tests, 0 failures; fork-reviewed no CRITICAL/HIGH; NOT HW-validated - the wire trigger cannot be reproduced on the Protectli, acceptable given the preserve-only direction). H4 CODE-COMPLETE (packaging-only, no ver bump; `debian/prerm` aborts on lock-timeout instead of proceeding + restores the rescan timer on abort; control-flow verified with stubbed flock, real flock -w timeout needs the box). H5 CODE-COMPLETE as ver 0.4.6 (post-accept lease wait is now ONE box-wide deadline, not per-VLAN in series that stacked to VLAN_LIMIT × LEASE_SETTLE and could outrun the systemd timeout and skip the restart; verified with a stubbed-predicate harness, real timing needs the box). M2 CODE-COMPLETE (CI-only, no ver bump; release-workflow APT rebuild lists all releases + hard-fails a missing/failed `.deb` while skipping releases that carry none + asserts the just-published version is present; verified by reading + `bash -n`, only exercises on a real tagged release). M4 CODE-COMPLETE as ver 0.4.7 (`ifaces_without_carrier` drops additions on any addition-bearing trunk carrier-down at apply time, regardless of ownership/need_pass2, so an unowned trunk that dies in the detection->apply window no longer gets stanzas on a dead parent; do_dryrun mirrors it; §1ad, 245 tests; NOT HW-reproducible - narrow window, guard only ever drops additions). M5 CODE-COMPLETE as ver 0.4.8 (a failed post-ACCEPT `ip link delete` is recorded in `/run/dynavlan/pending-delete` and retried at the start of every do_boot/do_rescan via `drain_pending_deletes`, instead of leaving the orphan interface up until reboot; ownership-safe, reboot-scoped; do_dryrun previews read-only; §1ae, 253 tests; NOT HW-reproducible - needs a transient delete failure). M6 CODE-COMPLETE as ver 0.4.9 (a TOTAL restart failure no longer marks the new subnet as seen: `restart_targets` sets `RESTART_NONE_SUCCEEDED_THIS_RUN` when nothing restarted, and `maybe_restart_on_new_subnet` holds the new tokens out of the seen-set to retry next run instead of stranding the subnet unseen this uptime; total-failure ONLY - a partial success consumes, else one permanently-broken target would re-restart the working agents every run forever (restart storm); covers a failed apply-driven restart too; §1af 5 cases, 258 tests; NOT HW-reproducible - needs a transient restart failure). GROUP 5 remaining: M8 robustness + the state-machine test harness, then P1-P3, HV-1. Faithful C1 positive-refusal HW test deferred (needs switch access). Full register: `docs/superpowers/plans/2026-08-04-v1.0-gate4-review-fixes.md`.
- [ ] Upgrade the Protectli box from its 0.4.2 `build source` test build to the released packaged 0.4.2 (`sudo apt update && sudo apt upgrade`) - operator will do when ready.
- [ ] Review + implement the `--report` command (redaction-first diagnostic bundle for crowdsourcing edge-switch LLDP coverage). Design DONE + committed locally (git-excluded): `docs/superpowers/specs/2026-08-05-report-command-design.md`. Next: operator reviews the spec, then `writing-plans` -> implement (ver 0.4.3 -> 0.5.0, new `--report` CLI mode, no new config key). Parked 2026-08-05 to continue the gate-4 Codex backlog.

## Completed milestones

- [x] v0.4.2 RELEASED (done 2026-08-05): Unit 3 pre-freeze blockers C2 (apply-evidence floor), H2 (config isolation), C1 (routed-mode default-route delete guard) + earlier M3/H3/H7; 213 unit tests; HW-validated on the Protectli box (C2 removal-only accept at 18.19s = floor-16; C1 live true-negative). Tagged `v0.4.2`, pushed, GitHub release published, `.deb`/APT built by Actions.

- [x] All-trunks provisioner redesign (v0.2.0, done 2026-07-30)
- [x] Hardware validation: L3-29 dual leasing, L3-30 carrier-pull preserve, L3-31 routed multi-trunk, L3-32 unified revert (done 2026-07-30)
- [x] Code review fix: netplan-get field-order bug (v0.2.1, done 2026-07-30)
- [x] v0.2.1 release: CHANGELOG reformatted, tagged, GitHub release created (done 2026-07-30)
- [x] One-line curl installer: get.sh (done 2026-07-30)
- [x] .deb packaging: debian/, build-deb.sh, GitHub Actions workflow (done 2026-07-30)
- [x] GitHub repo description updated for multi-trunk positioning (done 2026-07-30)

## Completed: carrier-down VLAN removal (v0.4.0) - RELEASED

- [x] Carrier-down VLAN removal (FR-41, minor bump -> v0.4.0, `ver=` already bumped). All
      7 plan tasks implemented on branch `worktree-carrier-down-vlan-removal` (7 commits):
      `carrier_removals` (pure debounce helper, tests 1r) + `have_routing` (routing
      pre-condition, tests 1s) + `REMOVE_ON_CARRIER_LOSS` config key (default true) +
      `BOOT_SETTLE_SECONDS` comment clarified as dual-purpose + `do_boot` wiring
      (zero-detection guard split so an empty-but-successful detection still reaches
      carrier-down pruning; pass-1 carrier stash; `need_pass2` fires independently of
      `RESET_ON_BOOT`) + `do_rescan`'s first-ever removal path (fast-path-preserved:
      settle sleep only when an owned trunk is actually down) + `--dry-run` preview
      + `--status` per-trunk carrier flag. 148/148 unit tests passing (139 baseline +
      9 new: 6 `carrier_removals` + 3 `have_routing`). Design:
      `docs/superpowers/specs/2026-07-30-carrier-down-vlan-removal-design.md`; plan:
      `docs/superpowers/plans/2026-07-30-carrier-down-vlan-removal.md` (7 tasks, all
      checked off; test-section letters renumbered 1q/1r -> 1r/1s mid-execution since
      FR-40 had already claimed 1q; two small gaps closed during a plan-review pass
      before execution: rescan run-start log parity with `remove_on_carrier_loss`,
      and the `BOOT_SETTLE_SECONDS` dual-purpose doc comment).
      Docs brought current in the same pass: PRD bumped to v3.7 (new FR-41 + AC-16;
      FR-21/23/AC-3 narrowed - carrier-down no longer blanket-preserved, only
      carrier-up-with-no-tags is), SKELETON (Key Invariants + reconcile-policy
      prose), design doc (new §11b + a `have_routing` note in §7), CODEMAP (new
      helper rows + updated one-liners), README (How-it-works + Safety sections
      corrected - "removals wait for next boot" was stale), CHANGELOG (Unreleased),
      test plan (new 1r/1s Layer-1 sections, Layer-2 dry-run cases, L3-30 revised
      to "carrier-pull PRUNE" with the original preserve result kept as struck-through
      history, AC-16 traceability row).
      SUPERSEDES the hardware-validated L3-30 "carrier-pull preserve" result - the
      revised L3-30 (carrier-pull prune) is NOT YET run on hardware.
      MERGED to `main` 2026-08-03 (fast-forward, 148/148 tests re-verified post-merge
      per CLAUDE.md's merge -> verify -> push sequencing); worktree + feature branch
      removed (all commits preserved on `main`). Pushed to `origin/main` same day.
- [x] Minor-release code review DONE 2026-08-03, on branch `worktree-review+0.4.0-fixes`.
      Three parallel reviewers (removal state machine / never-strand safety /
      spec-surface-tests), then a four-agent adversarial verification pass that
      overturned five of ten verdicts - worth noting, since the first-round
      recommendations for the two blockers were both wrong:
      - C1 (CRITICAL, confirmed twice): `run_detection` returns non-zero iff it
        detected nothing, so the `! run_detection` abort in boot/rescan/dry-run
        fired on exactly FR-41's headline case (all trunks unplugged -> nothing to
        detect -> dead trunk never pruned). Fix was NOT the proposed hard-failure
        rc - nothing can produce one - but dropping the abort and branching on
        `DETECTED_TRUNKS`.
      - M2 rode with it: that abort was also what protected an all-dark box, so
        `have_routing` now also requires a live physical NIC (tun/wireguard report
        carrier whenever merely up). Shipped in one commit to avoid opening the
        AC-4 hole between commits.
      - H1: `do_rescan` gated on routing only BEFORE the settle; the post-apply
        health check does not back that up (empty snapshot = unconditional PASS).
      - H2 (downgraded to MEDIUM, still fixed): additions on a trunk that died
        mid-sniff were created in the same apply that tore its old ones down.
      - H3: `--dry-run` listed removals `--boot` would not perform. Defect predates
        v0.4.0; fixed anyway since this release's test-doc asserts the corrected
        behavior and dry-run is the pre-flight for hardware validation.
      - H4 INVERTED: the PRD was right and SKELETON/CODEMAP/design doc were the
        outliers, describing an intent the code never had.
      - M1 documented not fixed (boot debounce is ~110s at `RESET_ON_BOOT=true`);
        M3 clamps a sub-5s settle for the carrier samples only.
      5 commits, 182/182 tests (148 baseline + 34 new: 1t rescan combine, 1u
      mixed-trunk, 1v config validation + clamp, 1w `drop_iface_tokens`, 1s
      extended). No version bump - all of it folds into the unreleased 0.4.0.
- [x] Hardware validation DONE 2026-08-04 on the Protectli box, console-driven (serial
      `screen` session, SSH for the .deb transfer only). v0.4.0 deployed via `.deb`
      upgrade over the box's existing v0.3.0 dpkg install (kept the box's customized
      `dynavlan.conf` at the conffile prompt - diff was comment-only). All 6 L3-30
      sub-cases PASS: carrier-pull prune (rescan), re-plug re-add (rescan), flap
      shorter than the settle preserves, box's own uplink with no redundant route
      preserves (`have_routing` false -> "no healthy routing; preserving"), `--boot`
      prune, post-boot re-add. Every removal/addition went through `netplan try` and
      was ACCEPTED; every preserve case logged the expected fail-toward-no-change
      reasoning. Full per-sub-case detail: `dev/features/dynavlan-tests.md` L3-30 row
      and the 2026-08-04 hardware-run note.
- [x] RELEASED 2026-08-04. CHANGELOG retitled `[0.4.0]`, PRD status/AC-16 lines
      corrected (both still said "NOT YET hardware-validated" after the validation
      run - caught before the GitHub release was created). The first tag/push
      (build `298c8a5-dirty`, an untracked unrelated doc file made the tree dirty)
      was deleted and redone once the CHANGELOG fix landed, so `v0.4.0` points at a
      commit (`cb957a3`) with accurate docs; the .deb built from that commit reports
      a clean build id (no local checkout in the loop was ever left dirty for
      more than the one intermediate commit). `bash tests/unit.sh` re-verified
      (182/182) immediately before tagging, per CLAUDE.md. GitHub Actions built and
      attached `dynavlan_0.4.0_all.deb` to the release automatically. Release:
      https://github.com/pereljon/dynavlan/releases/tag/v0.4.0

## Completed: APT repository hosting (v1.0 gate 2) - LIVE

- [x] DONE 2026-08-04. Implemented per spec/plan on branch `feature/apt-repository-hosting`
      (6 commits: signing key + reprepro config, `publish-apt` workflow job, apt-aware
      `get.sh`, docs, then 2 code-review fix commits - see `context/decisions.md` 2026-08-04
      for the full review outcome). Merged to `main`, pushed. No `ver=` bump.
      Republished the existing `v0.4.0` release (deleted + retagged at the post-review
      commit) to fire `publish-apt` for the first time, since no dynavlan script change
      existed to justify a new version. Hit one one-time repo-setup gap not covered by the
      original design: the `github-pages` deployment environment (auto-created when Pages
      source = GitHub Actions) has its own branch/tag protection separate from the Pages
      source setting, and defaults to allowing neither - `publish-apt` failed with "Tag
      v0.4.0 is not allowed to deploy to github-pages" until a `v*` **tag** policy was added
      to the environment (Settings -> Environments -> github-pages -> Deployment branches
      and tags). A `v*` **branch** rule was tried first and did nothing (0 branches match,
      since releases are tags) - fixed via `gh api .../deployment-branch-policies -f
      name='v*' -f type='tag'`. VERIFIED LIVE: `https://pereljon.github.io/dynavlan`
      serves a valid signed `InRelease`/`Packages` (dynavlan 0.4.0 listed, key fingerprint
      matches `639F373F324DE8E23FF6E1DCCA1F8DAB3D00EC9D`); client onboarding tested on the
      Domotz box (add keyring + `.sources` -> `apt update` fetches signed index -> `apt-cache
      policy` resolves the repo candidate -> `apt install --only-upgrade dynavlan` correctly
      reports already-current, since this republish carried no new dynavlan version).
      FOLLOW-UP genuine fresh-install test (same session): `sudo apt remove --purge dynavlan`
      then `sudo apt install dynavlan` on the Domotz box - confirmed the `.deb` was actually
      fetched live from `pereljon.github.io/dynavlan` (not a cache hit), unpacked, and
      installed; `dynavlan --version` reported a clean `(build 2faa749)` with no `-dirty`
      suffix (the exact commit `v0.4.0` was retagged at), confirming FR-38 build identity
      survives the apt path end-to-end. Config/units all landed fresh with correct
      timestamps; `dynavlan.service`/`.timer` enabled but `inactive` (never `--now`); all 14
      VLAN interfaces across both trunks (`enp1s0`/`enp2s0`) and the generated
      `/etc/netplan/90-dynavlan.yaml` were untouched by the purge+reinstall cycle, confirming
      dpkg remove/purge never touches the owned netplan file or running network state
      (`debian/prerm`/`postrm` only stop the timer and clean up config/journald - by design).
      `test-box-access` memory updated: upgrades on that box now go via `apt upgrade`.

## Completed: restart-on-new-subnet (v0.3.0) - RELEASED

- [x] Restart-on-new-subnet (FR-40, minor bump -> v0.3.0, `ver=` already bumped). Restarts
      `RESTART_SNAPS`/`RESTART_SERVICES` when a new global-IPv4 subnet appears on any
      interface (not only on a tagged-VLAN change), closing the agent-started-before-DHCP
      boot race and covering access/native ports dynavlan never provisions. New
      `RESTART_ON_NEW_SUBNET` config key (default true); new pure helper `ipv4_network`
      (subnet-not-host-address keying); ephemeral per-uptime seen-set at
      `/run/dynavlan/seen`; growth-check wired into `main` after every `--boot`/`--rescan`
      exit, deduped against the existing VLAN-driven restart. Design:
      `docs/superpowers/specs/2026-07-30-restart-on-new-subnet-design.md`. Docs (PRD FR-40/
      AC-15, SKELETON, CODEMAP, design doc, test plan 1q + L3-33..36, README, CHANGELOG)
      brought current in the same pass. Built on branch `feature/fr-40-restart-on-new-subnet`
      via subagent-driven-development: 6 commits, per-task + architect + final whole-branch
      reviews all clean, unit suite 139/0. HARDWARE-VALIDATED 2026-07-30 on the Protectli box
      with the real Domotz snap (`domotzpro-agent-publicstore`), enp2s0 as the test NIC:
      L3-33 (access port after boot -> 1 restart; UniFi and Meraki), L3-34 (same subnet ->
      no restart), L3-35 (boot race: Domotz started 05:48:30 then restarted 05:51:01 after
      settle), L3-36 (dry-run/status read-only) all PASS; plus disappearance-no-restart,
      monotonic flap idempotence, reconnected-trunk multi-subnet restart with no re-provision,
      and interface-in-key (base vs .N same subnet distinct). Timer FR-21a health reconfirmed.
      MERGED to `main` and RELEASED as v0.3.0 (`v0.3.0` tag exists, GitHub release created
      on pereljon/dynavlan). Superseded by v0.4.0 work above.

## Next steps (not started)

- [x] Test .deb build end-to-end (done 2026-08-03): installed the v0.3.0 release .deb on the Domotz box (Ubuntu 22.04), console-backed. Validated install.sh->.deb migration (old /etc/systemd/system units removed, /lib copies live), FR-38 build id (`814bcd1`, was `unknown`), conffile preserved, reboot + boot `--boot` apply (no-change, no revert), and real `domotzpro-agent-publicstore` snap restart. Box now dpkg-managed. Apply->netplan-try->revert path not exercised (no config diff); already hw-validated for v0.3.0.
- [ ] v1.0 release. DEFINED 2026-08-03 (spec: local-only
      `docs/superpowers/specs/2026-08-03-v1.0-definition-design.md`; decision in
      context/decisions.md 2026-08-03). Four gates, all required before the 1.0.0 tag:
      (1) [x] DONE 2026-08-04: carrier-down VLAN removal shipped as v0.4.0 (see the v0.4.0 milestone above);
      (2) [x] DONE 2026-08-04: APT distribution built, live, and reference-box-validated (see the APT repository hosting milestone above);
      (3) second-box / multi-site validation on >=1 more box at a different site
      (non-Meraki switch requirement ALREADY MET via the v0.3.0 UniFi trunk validation);
      (4) 1.0.0 itself = config-surface freeze + `COMPATIBILITY.md` (deprecate-with-warning
      policy) + version-gate git hooks + full major-review (adversarial, other models).
      GATE-4 MAJOR-REVIEW RECEIVED 2026-08-04: independent Codex review of the pre-v1 surface
      (2 CRITICAL, 7 HIGH, 8 MEDIUM, 3 plausible, 10 doc contradictions; verdict NOT READY
      for freeze). Independently verified 20/20 code findings + 3 plausibles + 10
      contradictions accurate, zero false positives. Findings logged, all OPEN (nothing fixed):
      register `docs/superpowers/plans/2026-08-04-v1.0-gate4-review-fixes.md`; decision
      `context/decisions.md` 2026-08-04. Freeze/tag BLOCKED until CRITICAL+HIGH resolved with
      tests + console-backed hardware validation, then re-reviewed.
      FIX PROGRESS: Unit 1 (doc-contradiction cluster D1-D10 + README) landed on main
      2026-08-04. Unit 2 (M3 dry-run exit code, H7 build-deb version binding, H3 Debian
      upgrade-state preservation) CODE-COMPLETE + branch-reviewed on
      `fix/gate4-unit2-correctness` (ver 0.4.0 -> 0.4.1), unit suite 183/183, merged to main.
      HARDWARE-VALIDATED 2026-08-04 on the Protectli box (M3 dry-run exit code; H3 fixed->fixed
      + transitional upgrade matrix, L3-37). H3 hardware validation CAUGHT A BUG: the transitional
      (pre-fix->fixed) upgrade started a deliberately-disabled timer (`tmr_active` defaulted to 1);
      FIXED on branch `fix/h3-transitional-disabled-timer` (`tmr_active="$tmr_enabled"`, re-validated,
      no ver bump). Separate pre-existing finding logged (open_questions): a FRESH install starts the
      timer via dpkg/systemd machinery, not postinst. Remaining: C2/H2/C1 (pre-freeze blockers), then
      contract decisions (M7/D5-done/H6+M1), robustness (H1/H5/H4/M2/M4/M5/M6) + state-machine harness.
      Path: v0.4.0 -> APT + validation (parallel) -> freeze + tag 1.0.0 (last by construction).
      OUT OF SCOPE for 1.0 (documented limitations): IPv6, exhaustive vendor coverage,
      per-VLAN MAC (G-4, no reserved key - PER_VLAN_MAC removed in 0.4.3), automatic config-drift detection.
- [ ] Git hooks for version gate enforcement (see open_questions.md, designed but not built)
- [ ] IPv6 health-check arm (deferred from FR-14a; required before any future IPv6 route acceptance)
- [ ] Non-Meraki switch validation: MET for sniff-primary (proven on a UniFi trunk, v0.3.0 validation 2026-07-30); residual is broader vendor LLDP VLAN-table coverage and silent-VLAN gaps, which vary by vendor
- [ ] G-4: per-VLAN MAC derivation (post-1.0, low priority; reserved PER_VLAN_MAC key removed in 0.4.3, any implementation adds its own key)
- [ ] Automatic config-drift detection on boot/rescan (deferred until a second box exists)
