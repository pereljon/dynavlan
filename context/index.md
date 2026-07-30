# Context Index

Read these live-state files first on every session, in order:
1. context/todo.md - outstanding tasks and current status
2. context/open_questions.md - unresolved questions
3. context/decisions.md - decisions already made (do not re-litigate)

STATE (2026-07-30): dynavlan v0.2.1 released and hardware-validated. All-trunks provisioner redesign
(v0.2.0) plus the netplan-get field-order fix (v0.2.1) are tagged, pushed, and on GitHub with a release.
Packaging: `get.sh` (curl one-liner), `.deb` packaging + GitHub Actions workflow (builds on release,
attaches .deb). The `.deb` build has not been tested yet (first real test is the next release tag).

Before coding a change, read in order:
4. dev/SKELETON.md - logic flow and key invariants
5. dev/CODEMAP.md - where things live (per-function map)
6. docs/dynavlan-PRD.md - authoritative requirements (FR/NFR/AC)
7. dev/features/dynavlan.md - technical design: architecture, backend seam, apply/rollback state machine
8. dev/features/dynavlan-tests.md - test plan (unit asserts, --dry-run, hardware checklist)

These files are the project's working memory; keep them current.
