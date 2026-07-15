---
title: Development Project
description: Self-bootstrapping scaffold for a software project. Behavioral directives, folder structure, and live-state context files are created on first run.
template_version: 1
---


# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Start Here

On a fresh session or after a compact: read `context/index.md` first (read-order + live state), then `dev/SKELETON.md` and `dev/CODEMAP.md` before touching code.

## Project

**[PROJECT NAME]** -- [ONE-LINE DESCRIPTION OF WHAT THIS PROJECT IS, ITS TECH STACK, AND ITS PRIMARY DELIVERABLES].

[OPTIONAL CONTEXT ABOUT AUDIENCE AND THE STANDARDS THAT FOLLOW FROM IT, e.g. "Open-source project with external users: safety, portability, stability matter." or "Internal service for [TEAM]; optimize for iteration speed."]

## Design Principles

[ONE-LINE STATEMENT OF THE PROJECT'S GUIDING PHILOSOPHY, e.g. "Infrastructure, not a framework."]

- **[PRINCIPLE]:** [what it means in practice].
- **[PRINCIPLE]:** [explanation].
- **[PRINCIPLE]:** [explanation].

[List the handful of opinionated principles that should shape every design decision. Concrete, not platitudes; each specific enough to settle a real disagreement.]

## How I Work

- A question is a request for analysis, not an instruction to act. Explain or investigate; wait for explicit instruction before writing or changing code.
- Before editing, read enough of the codebase to understand the logic flow and blast radius. Don't grep blind or guess at structure.
- Ask 1-2 focused clarifying questions when requirements, scope, or edge cases are ambiguous. No preamble.
- Prefer the smallest change that solves the problem. No speculative features, abstractions, or error handling for cases that cannot happen.
- Fix root causes, not symptoms. Don't bypass safety checks (e.g. `--no-verify`) or silence errors to make a problem disappear.
- Distinguish what you know from what you're guessing. Say "I'm not sure" when you can't verify. Verify claims about existing code by reading it, not from memory.
- Type checks and tests verify code correctness, not feature correctness. Exercise features in the real environment before claiming they work; if you can't, say so explicitly.
- Lead with the answer or result, then supporting detail. Reference code as `file_path:line_number`.
- Write like a developer. No LLM-stereotype language ("delve", "leverage", "streamline", "excited to"). No em dashes; use regular dashes (-) everywhere: code, comments, docs, commit messages.
- Default to no code comments; add one only when the reason behind the code is non-obvious (a constraint, invariant, or workaround). Match the conventions already in the file. Handle errors at boundaries; prefer immutable operations and small, focused functions.

## Documentation Roles

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Conventions, checklists, guardrails for working in this repo |
| `context/index.md` | Read-order for a fresh session; pointers to the live-state files below |
| `context/todo.md` | Outstanding tasks and their state |
| `context/decisions.md` | Dated log of decisions made and rejected |
| `context/open_questions.md` | Unresolved questions with status and resolution path |
| `dev/CODEMAP.md` | Where things live: function/module purposes, for locating code |
| `dev/SKELETON.md` | How it works: logic flow and key invariants |
| `dev/IMPLEMENTATION-SPEC.md` | Architecture, config reference, design decisions, deprecation policy |
| `README.md` | Landing page: install, capabilities, usage examples |
| `CHANGELOG.md` | What changed per release |
| `docs/...` | [Additional user-facing docs and their single, clear role] |

Keep this table current; each file gets one clear role. Optional: when a feature matures, adopt a `dev/features/<feature>.md` design doc + `<feature>-tests.md` test plan convention.

## Non-Obvious Behaviors

These affect how code changes should be made. Full architecture is in `dev/IMPLEMENTATION-SPEC.md`.

- **[BEHAVIOR NAME]**: [the non-obvious thing and why it matters for code changes]

[Highest-value section. Capture what is NOT derivable from reading the code linearly: hidden coupling, ordering constraints, state that lives somewhere surprising, framework quirks the project depends on.]

## Security Context

[Describe the threat model honestly. e.g. "Single-user tool on the user's own account: accidental footguns, not adversarial scenarios." vs "Public-facing service handling untrusted input." This calibrates how much defensive code is warranted.]

## Working Rules

- **Keep context files current**: update `context/` files whenever a task, decision, or open question changes. Stale context compounds errors downstream.

(General working style is in **How I Work** above.)

## Development Workflow

[Describe the edit/deploy loop. e.g. "Changes hot-reload; restart [SERVICE] for config changes." or "Deploy after commit: [COMMAND]."]

Before coding any change: read `dev/SKELETON.md` and `dev/CODEMAP.md` to identify the blast radius, then locate the specific functions and their scope. Don't start editing until you know what's affected.

### Code Review Before Release

Scope depends on the size of the change:

- **Patch (x.y.Z)**: review only the changed units
- **Minor (x.Y.0)**: review all units added or modified in the release
- **Major (X.0.0)**: full review of the relevant surface

Address CRITICAL and HIGH issues before committing.

## Git Approvals

Each step requires explicit user approval. Approval for one step does not imply approval for the next.

1. **Commit**: propose the commit message and changed files, wait for approval before `git commit`.
2. **Push**: wait for explicit approval before `git push`.
3. **Release**: only the user can authorize a release. A release requires [STATE WHAT A RELEASE REQUIRES, e.g. `git tag vX.Y.Z`, `git push origin vX.Y.Z`, `gh release create vX.Y.Z`]. Commit or push do not imply release.

After completing work, ask which steps the user wants: "Want to commit, push, or release?"

## Testing Plan

Before coding a new feature or change, review with the user: happy path, edge cases, flag/config conflicts, data/schema migration, interface or prompt updates. Get confirmation before writing code.

Exercise the feature in the real environment before claiming success. Type checking and tests verify code correctness, not feature correctness. If you can't test it, say so explicitly rather than claiming it works.

## Change Checklist

**GATE: Do NOT suggest commit, push, or release until every item below has been checked and all affected files are updated.**

After any code change, check whether these need updating:

- `README.md`
- `[CONFIG EXAMPLE FILE]` (new settings)
- `dev/IMPLEMENTATION-SPEC.md` (architecture, settings, behavior changes)
- `dev/CODEMAP.md` (new/renamed/removed functions or modules)
- `dev/SKELETON.md` (logic-flow changes: new conditions, changed call sequences)
- `context/` files (todo, decisions, open questions)
- `CLAUDE.md` (if key behaviors changed)
- `CHANGELOG.md` (new features, fixes, removals per release)
- `[VERSION LOCATION]` bump if needed (semver: patch/minor/major)
- [OTHER PROJECT-SPECIFIC ARTIFACTS THAT MUST STAY IN SYNC WITH CODE]

When making multiple changes, consider logical ordering: some changes should come before others (e.g. move code before updating references to it; validate inputs before using them).
