# Context Index

Read these live-state files first on every session, in order:
1. context/todo.md - outstanding tasks. **CURRENT NEXT ACTION: run the post-implementation hardware
   checklist (dynavlan-tests.md L3-29..L3-32) on the box, which already has two live trunks wired up.**
   See the CURRENT WORK block at the top of todo.md.
2. context/open_questions.md - unresolved questions
3. context/decisions.md - decisions already made (do not re-litigate); newest entry is the all-trunks redesign

STATE (2026-07-29): dynavlan v0.2.0 (all-trunks provisioner) is code-complete and doc-complete, but NOT
yet hardware-validated on the multi-trunk paths, and UNRELEASED (no tag). v0.1.0 (single-trunk) was
hardware-validated on the box (apply/rollback, routed mode, IPv6 isolation, revert drill all passed) but
that code is superseded by the redesign. Read `dev/SKELETON.md`/`dev/CODEMAP.md` before touching code -
they already reflect the all-trunks model (`select_trunk` removed, `iface.id` tokens, no relocation branch).

Before coding a change, read in order:
4. dev/SKELETON.md - logic flow and key invariants
5. dev/CODEMAP.md - where things live (per-function map)
6. docs/dynavlan-PRD.md - authoritative requirements (FR/NFR/AC), updated for the all-trunks model
7. dev/features/dynavlan.md - technical design: architecture, backend seam, apply/rollback state machine
8. dev/features/dynavlan-tests.md - test plan (unit asserts, --dry-run, hardware checklist incl. L3-29..L3-32)
9. docs/superpowers/specs/2026-07-28-all-trunks-provisioner-design.md - the original design spec (historical; implemented)

These files are the project's working memory; keep them current.
