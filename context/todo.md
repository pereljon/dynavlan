# todo - outstanding tasks and their state

Owns: open tasks and their status. Does NOT hold permanent facts or decisions (those live in dev/ docs and context/decisions.md).
Maintain: update whenever a task is added, changes state, or completes.
Entry format: `- [ ] task`  /  done: `- [x] task (done YYYY-MM-DD)`

## Planning phase - COMPLETE (2026-07-14)

- [x] dynavlan design planned, locked, hardware-validated on a real Protectli/igb lab box - see context/decisions.md, context/open_questions.md
- [x] PRD written, revised to v3.1, three architect reviews (final verdict GO / implementation-ready) - docs/dynavlan-PRD.md
- [x] Technical design doc - dev/features/dynavlan.md (architecture, backend seam, apply/rollback state machine, module decomposition, systemd/install layout)
- [x] Test plan written + architect-reviewed + hardened - dev/features/dynavlan-tests.md (lean 3-layer: unit asserts, --dry-run, VM checklist)
- [x] Project genericized (no company-specific refs) and pushed to github.com/pereljon/dynavlan (private). NOTE: two later local commits (design doc, test plan) are NOT yet pushed.

## NEXT: Build dynavlan

Read first (fresh session): docs/dynavlan-PRD.md (v3.1, authoritative behavior), dev/features/dynavlan.md (how to build it), dev/features/dynavlan-tests.md (tests to write).
Approach agreed: single cohesive bash implementation (NOT subagent fan-out - the apply/rollback state machine is too coupled). TDD the pure helpers; build outward; review with subagents at the end.

- [ ] Step 1 - TDD the 5 pure helpers under `superpowers:test-driven-development`. Write `tests/unit.sh` first (assert script, no framework), RED then GREEN, for: `parse_vlan_ignore` (tests 1a), `compute_candidates` (1b), `health_check` evaluator (1c), `boot_removals` (1d), `select_trunk` (1e). Cases are enumerated in dynavlan-tests.md.
- [ ] Step 2 - Build the core script `/usr/local/sbin/dynavlan` cohesively: config load/validate, interface discovery, promisc+carrier-wait, sniff/lldp detection, detect_union, exclusion, reconcile_boot (two-pass) / reconcile_rescan (add-only), the apply/rollback state machine (design §7), backend seam (6 `backend_*` fns, netplan impl), fifo-drive accept (§9), flock (fd-held), logging, the `--boot/--rescan/--dry-run/--status/--reconfigure` entrypoints.
- [ ] Step 3 - Config template `/etc/dynavlan.conf`, systemd `dynavlan.service` + `dynavlan.timer`, `install.sh`, add tcpdump to deployment-guide packages.
- [ ] Step 4 - Review pass: `code-reviewer` + `security-reviewer` subagents over the finished script; optionally a fork stress-testing the apply/rollback failure branches vs the PRD. Fold in CRITICAL/HIGH.
- [ ] Step 5 - Run the VM integration checklist (dynavlan-tests.md Layer 3) on a console-accessible VM. Codify the already-hand-validated cases.
- [ ] Update dev/CODEMAP.md and dev/SKELETON.md (currently describe the base deployment) to cover dynavlan once code lands.

## Open items (off critical path - see context/open_questions.md)
- [ ] IR-1: exact minimum netplan version (pinned conservatively at 0.106; possible later relaxation).
- [ ] G-4: per-VLAN MAC derivation function (only if PER_VLAN_MAC enabled; default off).
