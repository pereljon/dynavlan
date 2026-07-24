# Context Index

Read these live-state files first on every session, in order:
1. context/todo.md - outstanding tasks (current next action: Step 5, hardware checklist)
2. context/open_questions.md - unresolved questions
3. context/decisions.md - decisions already made (do not re-litigate)

dynavlan is code-complete (four review rounds folded in) but NOT yet exercised on hardware. Before coding a change, read in order:
4. dev/SKELETON.md - logic flow and key invariants
5. dev/CODEMAP.md - where things live (per-function map)
6. docs/dynavlan-PRD.md - v3.3, authoritative requirements (FR/NFR/AC)
7. dev/features/dynavlan.md - technical design: architecture, backend seam, apply/rollback state machine
8. dev/features/dynavlan-tests.md - test plan (unit asserts 1a-1g, --dry-run, hardware checklist L3-1..L3-23)

These files are the project's working memory; keep them current.
