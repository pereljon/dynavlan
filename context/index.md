# Context Index

Read these live-state files first on every session, in order:
1. context/todo.md - outstanding tasks. **CURRENT NEXT ACTION: invoke the `writing-plans` skill against
   the approved all-trunks design spec, then implement.** See the CURRENT WORK block at the top of todo.md.
2. context/open_questions.md - unresolved questions (incl. the deferred monitoring-vs-general positioning)
3. context/decisions.md - decisions already made (do not re-litigate); newest entry is the all-trunks redesign

STATE (2026-07-28): dynavlan v0.1.0 is code-complete, hardware-validated on the box (apply/rollback,
routed mode, IPv6 isolation, revert drill all passed), and UNRELEASED (no tag). The active work is the
**all-trunks provisioner redesign**: DESIGNED + operator-APPROVED, NOT yet implemented. Read its spec
before touching code on it: `docs/superpowers/specs/2026-07-28-all-trunks-provisioner-design.md`.

Before coding a change, read in order:
4. dev/SKELETON.md - logic flow and key invariants
5. dev/CODEMAP.md - where things live (per-function map)
6. docs/dynavlan-PRD.md - authoritative requirements (FR/NFR/AC); NOTE: still describes the single-trunk
   model - the all-trunks spec supersedes FR-4/AC-3 and revises FR-35, to be folded in on implementation
7. dev/features/dynavlan.md - technical design: architecture, backend seam, apply/rollback state machine
8. dev/features/dynavlan-tests.md - test plan (unit asserts, --dry-run, hardware checklist)
9. docs/superpowers/specs/2026-07-28-all-trunks-provisioner-design.md - the approved redesign (active work)

These files are the project's working memory; keep them current.
