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
- `dynavlan` is intentionally a single self-contained file (design §1). Optimize for clarity: expanded multi-line guards over dense one-liners, never compressed to save lines.

## Documentation Roles

File-to-role map (what each doc is for): `context/index.md` (## File roles). Keep it current; each file gets one clear role.

## Non-Obvious Behaviors

Hardware-validated netplan/NIC behaviors that strand the box or silently lose monitoring if violated live in `dev/SKELETON.md` (Key Invariants + the accept primitive). Read it before touching the apply, detection, or removal paths - these facts are not derivable from the code.

## Security Context

Runs as root, typically on a remote, headless, or unattended box. The threat model is accidental self-inflicted footguns (stranding the box, hijacking the uplink route, leaking network topology), not adversarial input. Recoverability outweighs everything: defensive code is warranted specifically around the apply/rollback path, not general input hardening. Captured VLAN IDs and subnets are confidentiality-sensitive: logs stay local, sniff uses a minimal snaplen and never persists frames.

**No real MACs or PII in committed files or commit messages.** This is a public repo. Never commit a real MAC address, and no personally identifying information beyond the maintainer's name (Jonathan Perel) -- no personal email addresses (the Debian `Maintainer` field uses a GitHub noreply address). This applies to commit messages too, not only file contents: never quote a real MAC or personal email in a commit message, including when the commit's purpose is to *remove* that value (describe it as "the personal email" / "the real MAC", never the literal). When a real capture, log excerpt, or hardware detail illustrates a point (e.g. in `context/decisions.md`), redact the MAC to an RFC 7042 documentation value (`00:00:5e:00:53:xx`) before committing. IP addresses and VLAN IDs are not PII and are fine.

## Testing Plan

Before coding a new feature or change, review with the user: happy path, edge cases, flag/config conflicts, interface updates. Get confirmation before writing code.

Type checks and tests verify code correctness, not feature correctness. Exercise the feature in the real environment before claiming it works; if you can't, say so explicitly. Never claim a feature works until it has run on the box.

## Development Workflow

- Before coding any change: read `dev/SKELETON.md` + `dev/CODEMAP.md` (and `dev/features/dynavlan.md` for design depth) to identify the blast radius, then locate the specific functions. Don't start editing until you know what's affected.
- New logic: TDD pure helpers in `tests/unit.sh` first (RED before GREEN); wire integration code cohesively - the apply/rollback state machine is too coupled for subagent fan-out.
- There is no hot-reload: dynavlan installs as a systemd service + timer. Hardware testing happens on the real appliance on the real trunk with console access, never only over SSH (a bad apply drops the connection). No VM.

### Workflow Pipeline

Canonical order of a change; detail lives in the section named.

1. **Read state** - `context/index.md` (Start Here).
2. **Scope the change** with the user; confirm before coding (Testing Plan).
3. **Branch** (Branch Policy), then find the blast radius (Development Workflow).
4. **Code** - TDD, RED before GREEN.
5. **Code review** (Code Review Before Release).
6. **Update docs** (Change Checklist), after review so docs describe final code.
7. **Test** - `bash tests/unit.sh`.
8. **Commit** (Git Approvals).
9. **Merge** `--ff-only` to `main`, then re-run tests on `main`.
10. **Push** (Git Approvals).
11. **Release** (Git Approvals); hardware-validate first.
12. **Session hygiene** (Session Hygiene).

### Branch Policy

**Branch, not worktree.** A worktree needs explicit authorization (below); a branch doesn't.

- **Behavior changes to `dynavlan`** (new FR, config key, apply/rollback/detection logic) get a branch.
- **Docs-only or trivial fixes** land directly on `main`.
- **Review happens on the branch**, before merging - not after, not on a separate one.
- **A major-release review (X.0.0)** gets its own branch (e.g. `release/1.0.0-review`): it covers the accumulated surface across several features and may take multiple fix commits before one merge + tag.
- Solo-maintainer project: default to **Option 1 (merge locally)** from `superpowers:finishing-a-development-branch` unless the user asks for a PR.

**Worktree only for:**

1. A second Claude session is active on this repo.
2. `main` must stay deployable mid-work.
3. The change may be abandoned outright, and `git reset --hard` on the only checkout would be unwelcome.

Otherwise skip it, even though `superpowers:using-git-worktrees` fires automatically - a worktree omits untracked and `.git/info/exclude`-hidden files (`docs/superpowers/plans/` among them), and finishing requires an extra exit-and-merge step a branch doesn't.

### Task Tracking Granularity

Three layers, kept distinct - do not conflate them:

- **`context/todo.md`**: milestones only, one line each (`designed → planned → code-complete → hardware-validated → released`). Source of truth for project status.
- **Plan file** (`docs/superpowers/plans/YYYY-MM-DD-<feature>.md`): the task/step decomposition of one milestone.
- **In-session task tool** (TaskCreate/TaskUpdate): tracks plan tasks while executing, never per step; never mirrored into `context/todo.md`.

Placement test: would a fresh session need this line to know where the project stands? Yes -> `context/todo.md`. No -> the plan file.

### Code Review Before Release

- **Patch (x.y.Z)**: review only the changed units
- **Minor (x.Y.0)**: review all units added or modified in the release
- **Major (X.0.0)**: full review of the relevant surface

Address CRITICAL and HIGH issues before committing.

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
- version in the `dynavlan` script (`ver=` variable) - see **Version and build identity** below
- systemd units (`dynavlan.service`/`dynavlan-rescan.service`/`dynavlan.timer`) and `install.sh` if artifacts change
- **When adding a config key**: default + `in_list`/range validation in `load_config`, a commented template entry in `dynavlan.conf` at its default, and the FR/config-surface section in `docs/dynavlan-PRD.md`.
- **When adding a CLI mode/flag**: the dispatch in `main`, the Usage section in `README.md`, and the corresponding FR/AC in `docs/dynavlan-PRD.md`.

When making multiple changes, consider logical ordering: some changes should come before others (e.g. move code before updating references to it; validate inputs before using them).

### Version and build identity (FR-38) - MANDATORY

A box must always be able to answer "what code is running here" (incident record: `context/decisions.md`, 2026-07-25, FR-38).

**Every change to the `dynavlan` script:**

1. **Bump `ver=`** for any behavior, output, config, or generated-YAML change - patch/minor/major by semver. No bump is itself a decision: say so explicitly in the commit message, never leave it silent.
2. **Never touch `build=`.** `install.sh` stamps it by matching `/^build=/`; it must stay a single, unindented, literal assignment at column 0 (`tests/unit.sh` §1l enforces this).
3. **`--version` must work before `load_config` and before the root check** - an unprivileged shell or a broken config is exactly when it's needed.

**Every deploy to a box:** run `dynavlan --version` first and confirm the build is the one you intended, BEFORE drawing any conclusion from its behavior. A `-dirty` suffix means the tree had uncommitted changes and the build matches no commit.

## Git Approvals

Each step requires explicit user approval. Approval for one step does not imply approval for the next.

1. **Branch**: create one without asking - it's local, reversible, and the Branch Policy above already decides when one applies. Just report it. A **worktree** is different: ask first and get explicit authorization, for one of the three reasons in that policy.
2. **Commit**: propose the commit message and changed files, wait for approval before `git commit`.
3. **Push**: wait for explicit approval before `git push`.
4. **Release**: only the user can authorize a release. A release requires `git tag vX.Y.Z`, `git push origin vX.Y.Z`, and `gh release create vX.Y.Z` on `pereljon/dynavlan` (gh account: pereljon). Commit or push do not imply release.
   - **Immediately before `git tag`**, re-run `bash tests/unit.sh` and confirm `dynavlan --version` reports the expected version - never tag off a state that hasn't been freshly verified (see Version and build identity above; this is the same discipline, applied at the one moment it matters most).
   - **Release gate**: only tag a release if the deliverable script, its installer, or its packaged config/service templates changed since the last release - those are the only assets an install or upgrade actually consumes. Docs-only changes are already available via the repo and don't need a release.

After completing work, ask which steps the user wants: "Want to commit, push, or release?"

## Session Hygiene

Before starting a new task, close out the current one: update `context/` files (todo, decisions, open questions), commit, and compact or clear the session to start fresh. Stale context from a long session compounds errors.
