# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Start Here

On a fresh session or after a compact: read `context/index.md` first - it owns the read-order and points at the live-state files (current status, next action, open questions). Do not trust status statements anywhere else; `context/todo.md` is the source of truth for project state.

## Project

**dynavlan** -- a self-configuring VLAN provisioner for headless netplan/systemd-networkd Linux boxes. Single-file bash. It discovers the active tagged VLANs on every trunk the box is plugged into, brings each up with DHCP (address-only, fully route/DNS-isolated by default), and restarts the nominated snaps/services so an interface-enumerating agent picks up the new subnets, with no SSH and no hand-edited YAML. Runs at boot and on a timer. Deployment steps: `docs/deployment-guide.md`.

Audience: infrastructure tool for boxes that may be remote, headless, or unattended. Safety and recoverability dominate every decision; a bad apply that breaks the uplink may be unrecoverable without physical access.

## Commands

Single bash script, no build step. Dev loop:

```bash
bash tests/unit.sh          # Layer-1 unit suite; run before every commit (enforces the FR-38 version/build identity contract, §1k/1l)
bash -n dynavlan            # syntax-check the script
./dynavlan --version        # print ver + build id; works with no root and no valid config
sudo ./dynavlan --dry-run   # preview detection + planned adds/removes, validate, NO apply
sudo ./dynavlan --status    # report owned vs detected-now trunks
```

Install/first-run/removal live in `docs/deployment-guide.md`. Hardware testing is console-backed on the real appliance, never SSH-only (a bad apply drops the link).

## Design Principles

Infrastructure, not a framework. Never surprise the operator; never strand the box.

- **Never strand a headless box:** every apply is validated, health-checked against a pre-apply default-route snapshot, and auto-reverts (`netplan try`). Every failure path fails toward "no change, reachable, logged." Rollback is gated on a routing health check, never on an exit code.
- **Own one namespace, touch nothing else:** dynavlan owns exactly one generated netplan file and never reads base config for assumptions nor modifies any other file.
- **Discover, don't assume:** interfaces, the trunk, and VLANs are all discovered from live kernel state and the wire. No hardcoded interface names, VLAN IDs, native VLAN, or base filenames.
- **Smallest thing that works:** no speculative backends, frameworks, or test infrastructure until a real second case exists. The backend seam is structured for portability but has one implementation.
- **Hardware- and vendor-agnostic:** works on any netplan/systemd-networkd box, any switch vendor, any VLAN scheme (validated on a Protectli/igb appliance on a Meraki trunk).

## How I Work

- A question is a request for analysis, not an instruction to act. Explain or investigate; wait for explicit instruction before writing or changing code.
- Ask 1-2 focused clarifying questions when requirements, scope, or edge cases are ambiguous. No preamble.
- Prefer the smallest change that solves the problem. No speculative features, abstractions, or error handling for cases that cannot happen.
- Fix root causes, not symptoms. Don't bypass safety checks (e.g. `--no-verify`) or silence errors to make a problem disappear.
- Distinguish what you know from what you're guessing. Say "I'm not sure" when you can't verify. Verify claims about existing code by reading it, not from memory.
- Lead with the answer or result, then supporting detail. Reference code as `file_path:line_number`.
- Write like a developer. No LLM-stereotype language ("delve", "leverage", "streamline", "excited to").
- Default to no code comments; add one only when the reason behind the code is non-obvious (a constraint, invariant, or workaround). Match the conventions already in the file.
- `dynavlan` is intentionally a single self-contained file (design §1); file-size caps from global rules (e.g. an 800-line limit) do NOT apply here. Optimize for clarity, never compress logic or drop comments to hit a line count. Expanded multi-line guards are preferred over dense one-liners.

## Documentation Roles

File-to-role map (what each doc is for): `context/index.md` (## File roles). Keep it current; each file gets one clear role.

## Non-Obvious Behaviors

Hardware-validated netplan/NIC behaviors that strand the box or silently lose monitoring if violated live in `dev/SKELETON.md` (Key Invariants + the accept primitive). Read it before touching the apply, detection, or removal paths - these facts are not derivable from the code.

## Security Context

Runs as root, typically on a remote, headless, or unattended box. The threat model is accidental self-inflicted footguns (stranding the box, hijacking the uplink route, leaking network topology), not adversarial input. Recoverability outweighs everything: defensive code is warranted specifically around the apply/rollback path, not general input hardening. Captured VLAN IDs and subnets are confidentiality-sensitive: logs stay local, sniff uses a minimal snaplen and never persists frames.

**No real MACs or PII in committed files or commit messages.** This is a public repo. Never commit a real MAC address, and no personally identifying information beyond the maintainer's name (Jonathan Perel) -- no personal email addresses (the Debian `Maintainer` field uses a GitHub noreply address). This applies to commit messages too, not only file contents: never quote a real MAC or personal email in a commit message, including when the commit's purpose is to *remove* that value (describe it as "the personal email" / "the real MAC", never the literal). When a real capture, log excerpt, or hardware detail illustrates a point (e.g. in `context/decisions.md`), redact the MAC to an RFC 7042 documentation value (`00:00:5e:00:53:xx`) before committing. IP addresses and VLAN IDs are not PII and are fine.

## Development Workflow

- Before coding any change: read `dev/SKELETON.md` + `dev/CODEMAP.md` (and `dev/features/dynavlan.md` for design depth) to identify the blast radius, then locate the specific functions. Don't start editing until you know what's affected.
- New logic: TDD pure helpers in `tests/unit.sh` first (RED before GREEN, per `superpowers:test-driven-development`); wire integration code cohesively - the apply/rollback state machine is too coupled for subagent fan-out.
- There is no hot-reload: dynavlan installs as a systemd service + timer. Hardware testing happens on the real appliance on the real trunk with console access, never only over SSH (a bad apply drops the connection). No VM.

### Workflow Pipeline

The canonical order of a change, start to finish. This is the *sequence*; the detailed rules live in the sections it links to - do not duplicate them here.

1. **Read state** - `context/index.md` -> `context/todo.md`/`open_questions.md`/`decisions.md` (Start Here).
2. **Scope the change** - review with the user: happy path, edge cases, flag/config conflicts, interface updates (Testing Plan). Confirm before coding.
3. **Set up a worktree** (if warranted, see Worktree Policy below) - report when creating one, no need to ask first. Then read `dev/SKELETON.md` + `dev/CODEMAP.md` to find the blast radius (Development Workflow, above).
4. **Code** - TDD pure helpers RED-before-GREEN in `tests/unit.sh`; wire coupled integration code inline, never fanned out to subagents.
5. **Code review** - scope by version bump (Code Review Before Release); fix CRITICAL/HIGH before committing.
6. **Update docs** - the Change Checklist GATE, done after review so docs describe the final code, not a draft of it.
7. **Test** - `bash tests/unit.sh` (mandatory before every commit). Exercise the feature for real; hardware validation is a separate, later gate and is never satisfied by unit tests alone (Testing Plan).
8. **Commit** - [approval gate] (Git Approvals).
9. **Merge** - if built in a worktree, merge to `main` locally by default (Worktree Policy), then re-run `bash tests/unit.sh` on `main` itself before pushing.
10. **Push** - [approval gate] (Git Approvals).
11. **Release** - [approval gate]; hardware-validate first (cannot claim it works until it has run on the box); confirm version/build identity is current; `git tag` -> `git push origin TAG` -> `gh release create` (Git Approvals).
12. **Session hygiene** - update `context/` files, then clear or compact to start the next cycle fresh (Session Hygiene).

### Worktree Policy

- **Behavior changes to `dynavlan`** (new FR, config key, or apply/rollback/detection logic) get an isolated worktree/branch (per `superpowers:using-git-worktrees`) before landing on `main`. Report when creating one (see Git Approvals) - no need to ask first.
- **Docs-only or trivial fixes** (typos, one-line comment/doc corrections) can land directly on `main` - a worktree adds ceremony with no payoff at that size.
- **Code review runs in the same worktree/branch**, not a separate one: review the diff before merging, fix findings there, then merge. A worktree isolates the change from `main`; review is part of finishing that change, not a new one.
- **A major-release review (X.0.0, e.g. 1.0)** gets its own dedicated worktree/branch (e.g. `release/1.0.0-review`), separate from any single feature's branch, since it reviews the accumulated surface across multiple prior features and may collect several fix commits before one merge + tag. Create it only once the release's other gates are already met.
- Solo-maintainer project: default to **Option 1 (merge locally)** from `superpowers:finishing-a-development-branch` unless the user asks for a PR - there is no second reviewer requiring one.
- **Testing sequence: merge -> verify -> push.** Run `bash tests/unit.sh` before every commit in the worktree (already mandatory). After merging into `main`, re-run the suite on `main` itself before pushing - a merge changes what's on disk even when it's a fast-forward, so the merged tree, not the pre-merge branch, is what gets pushed. Hardware validation is a separate, later gate tied to *release*, not to push: pushing merged commits doesn't run anything on the box, so it belongs before `git tag`/`gh release`, not before `git push`. Full order for a feature: merge -> unit tests on `main` -> push (whenever) -> hardware validation -> release.

### Task Tracking Granularity

Three layers, kept distinct - do not conflate them:

- **`context/todo.md` holds milestones only.** A milestone is a project-state unit a fresh session must know to understand where things stand: a feature moving through `designed → planned → code-complete → hardware-validated → released`. One line per milestone. This is the project's source of truth for status (see Documentation Roles).
- **The plan file** (`docs/superpowers/plans/YYYY-MM-DD-<feature>.md`) holds the task/step decomposition of a single milestone. Plan *tasks* are sized per `superpowers:writing-plans` (Task Right-Sizing: the smallest unit that carries its own test cycle and is worth a fresh reviewer's gate); *steps* are the bite-sized actions inside a task. These live in the plan, never in `context/todo.md`.
- **The in-session task tool** (TaskCreate/TaskUpdate) tracks plan *tasks* while executing, per `superpowers:executing-plans` ("create todos for the plan items"). Track at task granularity, never per step; it is ephemeral execution scaffolding and is never mirrored into `context/todo.md`.

Placement test: "If I cleared the session now, would a new session need this line to know where the project stands?" Yes -> milestone in `context/todo.md`. No -> a task/step in the plan file.

Coupled work is executed inline, not fanned out: per `superpowers:subagent-driven-development` (tightly-coupled tasks -> manual execution), the apply/rollback state machine is not dispatched to parallel subagents (restates the TDD bullet above).

### Code Review Before Release

- **Patch (x.y.Z)**: review only the changed units
- **Minor (x.Y.0)**: review all units added or modified in the release
- **Major (X.0.0)**: full review of the relevant surface

Address CRITICAL and HIGH issues before committing.

## Git Approvals

Each step requires explicit user approval. Approval for one step does not imply approval for the next.

1. **Worktree**: report when creating a new git worktree (e.g. via `superpowers:using-git-worktrees` or an `EnterWorktree`-style tool) - no need to ask first, since the Worktree Policy below already decides when one applies. It's local and reversible, unlike commit/push/release. Ask only when it's genuinely ambiguous whether a change counts as "behavior change" (worktree) vs. "trivial" (main) under that policy.
2. **Commit**: propose the commit message and changed files, wait for approval before `git commit`.
3. **Push**: wait for explicit approval before `git push`.
4. **Release**: only the user can authorize a release. A release requires `git tag vX.Y.Z`, `git push origin vX.Y.Z`, and `gh release create vX.Y.Z` on `pereljon/dynavlan` (gh account: pereljon). Commit or push do not imply release.
   - **Immediately before `git tag`**, re-run `bash tests/unit.sh` and confirm `dynavlan --version` reports the expected version - never tag off a state that hasn't been freshly verified (see Version and build identity below; this is the same discipline, applied at the one moment it matters most).
   - **Release gate**: only tag a release if the deliverable script, its installer, or its packaged config/service templates changed since the last release - those are the only assets an install or upgrade actually consumes. Docs-only changes are already available via the repo and don't need a release.

After completing work, ask which steps the user wants: "Want to commit, push, or release?"

## Session Hygiene

Before starting a new task, close out the current one: update `context/` files (todo, decisions, open questions), commit, and compact or clear the session to start fresh. Stale context from a long session compounds errors.

## Testing Plan

Before coding a new feature or change, review with the user: happy path, edge cases, flag/config conflicts, interface updates. Get confirmation before writing code.

Type checks and tests verify code correctness, not feature correctness. Exercise the feature in the real environment before claiming it works; if you can't, say so explicitly. Never claim a feature works until it has run on the box.

## Change Checklist

**GATE: Do NOT suggest commit, push, or release until every item below has been checked and all affected files are updated.**

After any code change, check whether these need updating:

- `README.md`
- `dynavlan.conf` template (new config settings)
- `docs/dynavlan-PRD.md` (requirement changes: FR/NFR/AC)
- `dev/features/dynavlan.md` (design: architecture, state machine, module changes)
- `dev/features/dynavlan-tests.md` (new/changed test cases)
- `dev/CODEMAP.md` / `dev/SKELETON.md` (new/renamed functions, logic-flow or invariant changes)
- `context/` files (todo, decisions, open questions) - keep current; stale context compounds errors downstream
- `CLAUDE.md` (if conventions or guardrails changed)
- `CHANGELOG.md` (new features, fixes, removals per release)
- version in the `dynavlan` script (`ver=` variable) - see **Version and build identity** below; this is a gate, not a judgement call
- systemd units (`dynavlan.service`/`dynavlan-rescan.service`/`dynavlan.timer`) and `install.sh` if artifacts change
- **When adding a config key**: default + `in_list`/range validation in `load_config`, a commented template entry in `dynavlan.conf` at its default, and the FR/config-surface section in `docs/dynavlan-PRD.md`.
- **When adding a CLI mode/flag**: the dispatch in `main`, the Usage section in `README.md`, and the corresponding FR/AC in `docs/dynavlan-PRD.md`.

When making multiple changes, consider logical ordering: some changes should come before others (e.g. move code before updating references to it; validate inputs before using them).

### Version and build identity (FR-38) - MANDATORY

A box must always be able to answer "what code is running here." That guarantee is cheap to maintain and was expensive to lack: on 2026-07-25 a deploy landed between two edits, and because nothing could distinguish the running build from the intended one, a working fix was diagnosed as broken. Do not let it decay.

**Every change to the `dynavlan` script:**

1. **Bump `ver=`** whenever behavior, output, config surface, or generated YAML changes. Patch for fixes, minor for new behavior or config keys, major for breaking changes. If you genuinely believe no bump applies (comments, docs, tests only), say so explicitly in the commit message rather than leaving it unstated - an unbumped version must be a decision on the record, never an omission.
2. **Never touch the `build=` line.** `install.sh` stamps it by matching `/^build=/`. It must stay a single, unindented, literal assignment at column 0. Do not rename it, indent it, compute it, or add a second one. `tests/unit.sh` section 1l enforces this and will fail loudly - if it does, fix the script, never the test.
3. **Never gate `--version` behind root or a valid config.** It is dispatched before `load_config` and before the root check on purpose: an unprivileged shell or a broken config are exactly when the question gets asked.
4. **Run `bash tests/unit.sh`** before proposing a commit. Sections 1k/1l cover the identity helper and the cross-file stamp contract.

**Every deploy to a box:** run `dynavlan --version` first and confirm the build is the one you intended, BEFORE drawing any conclusion from its behavior. A `-dirty` suffix means the tree had uncommitted changes and the build matches no commit. Never infer which code is running from whether a symptom persists; that inference has already been wrong once.
