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

## Active: carrier-down VLAN removal (v0.4.0) - PLANNED, next = execute

- [ ] Carrier-down VLAN removal (minor bump -> v0.4.0). State: design approved +
      committed (`docs/superpowers/specs/2026-07-30-carrier-down-vlan-removal-design.md`);
      implementation plan WRITTEN + architect-reviewed (H1/M1/L1 folded in):
      `docs/superpowers/plans/2026-07-30-carrier-down-vlan-removal.md` (7 tasks).
      Decisions: fire at boot + timer; carrier-down only (carrier-up-no-tags still
      preserved); minimal in-run two-pass debounce (grace-timer alt deferred); new
      `REMOVE_ON_CARRIER_LOSS` knob default true, independent of `RESET_ON_BOOT`.
      SUPERSEDES the hardware-validated L3-30 "carrier-pull preserve": the hardware
      checklist / L3-30 references update to prune-on-sustained-carrier-loss.
      NEXT STEP: execute the plan (Task 1: TDD `carrier_removals` RED first),
      inline for the coupled do_boot/do_rescan tasks; then minor-release code
      review + hardware validation gate before the v0.4.0 release.
      (Task/step decomposition lives in the plan file, not here - per CLAUDE.md
      Task Tracking Granularity.)
      VERSION: renumbered v0.3.0 -> v0.4.0 on 2026-07-30 to resolve a collision with
      restart-on-new-subnet (FR-40), which already took v0.3.0 and is code-complete.
      The plan's `ver=` bump lands on whatever ver= is current at execution: 0.2.1 if
      built before FR-40 merges, 0.3.0 if after - target is 0.4.0 either way.

## Active: restart-on-new-subnet (v0.3.0) - HARDWARE-VALIDATED, pending merge + release

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
      NEXT STEP: merge `feature/fr-40-restart-on-new-subnet` -> main, then release v0.3.0
      (git tag + gh release on pereljon/dynavlan) - both user-authorized.

## Next steps (not started)

- [x] Test .deb build end-to-end (done 2026-08-03): installed the v0.3.0 release .deb on the Domotz box (Ubuntu 22.04), console-backed. Validated install.sh->.deb migration (old /etc/systemd/system units removed, /lib copies live), FR-38 build id (`814bcd1`, was `unknown`), conffile preserved, reboot + boot `--boot` apply (no-change, no revert), and real `domotzpro-agent-publicstore` snap restart. Box now dpkg-managed. Apply->netplan-try->revert path not exercised (no config diff); already hw-validated for v0.3.0.
- [ ] APT repository: host a signed repo so `apt upgrade` picks up new versions.
      DESIGNED + user-approved 2026-08-03. Approach: GitHub Pages + reprepro,
      public, manual/attended upgrades only (NOT unattended). Spec (local-only,
      under git-excluded docs/superpowers/):
      `docs/superpowers/specs/2026-08-03-apt-repository-hosting-design.md`.
      Decision recorded in context/decisions.md (2026-08-03). NEXT STEP: write
      the implementation plan (superpowers:writing-plans) - was pending user's
      spec review at session end. Rejected Launchpad PPA (Ubuntu-only, breaks
      distro-agnostic) and SaaS (Cloudsmith/packagecloud; third party in trust
      path). Touches: get.sh (apt-aware + tarball fallback), release.yml (new
      publish-apt job, rebuild-from-assets, actions/deploy-pages), new apt/conf/,
      README/deployment-guide, one PRD NFR (manual-upgrade), CHANGELOG. No ver=
      bump (dynavlan script untouched). Needs a locally-generated RSA-4096
      passphraseless signing key in Actions secret APT_GPG_PRIVATE_KEY, plus
      offline key backup + revocation cert before first publish. Pages source
      must be set to "GitHub Actions".
- [ ] v1.0 release. DEFINED 2026-08-03 (spec: local-only
      `docs/superpowers/specs/2026-08-03-v1.0-definition-design.md`; decision in
      context/decisions.md 2026-08-03). Four gates, all required before the 1.0.0 tag:
      (1) carrier-down VLAN removal shipped as v0.4.0 (see the v0.4.0 milestone above);
      (2) APT distribution built + reference box upgrades via apt (see the APT milestone above);
      (3) second-box / multi-site validation on >=1 more box at a different site
      (non-Meraki switch requirement ALREADY MET via the v0.3.0 UniFi trunk validation);
      (4) 1.0.0 itself = config-surface freeze + `COMPATIBILITY.md` (deprecate-with-warning
      policy) + version-gate git hooks + full major-review (adversarial, other models).
      Path: v0.4.0 -> APT + validation (parallel) -> freeze + tag 1.0.0 (last by construction).
      OUT OF SCOPE for 1.0 (documented limitations): IPv6, exhaustive vendor coverage,
      PER_VLAN_MAC (stays default off), automatic config-drift detection.
- [ ] Git hooks for version gate enforcement (see open_questions.md, designed but not built)
- [ ] IPv6 health-check arm (deferred from FR-14a; required before any future IPv6 route acceptance)
- [ ] Non-Meraki switch validation (sniff-primary proven only on Meraki; LLDP coverage varies by vendor)
- [ ] G-4: per-VLAN MAC derivation (low priority, PER_VLAN_MAC default off)
- [ ] Automatic config-drift detection on boot/rescan (deferred until a second box exists)
