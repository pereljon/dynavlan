# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Start Here

On a fresh session or after a compact: read `context/index.md` first - it owns the read-order and points at the live-state files (current status, next action, open questions). Do not trust status statements anywhere else; `context/todo.md` is the source of truth for project state.

## Project

**dynavlan** -- a self-configuring VLAN provisioning tool for headless netplan/systemd-networkd Linux boxes. Single-file bash. It discovers the active tagged VLANs on whatever trunk the box is plugged into, brings each up with DHCP (address-only, fully route/DNS-isolated by default), and restarts the nominated snaps/services (e.g. the Domotz agent snap) so an interface-enumerating agent picks up the new subnets, with no SSH and no hand-edited YAML. Runs at boot and on a timer. Deployment steps: `docs/deployment-guide.md`.

Audience: infrastructure tool for boxes that may be remote, headless, or unattended. Safety and recoverability dominate every decision; a bad apply that breaks the uplink may be unrecoverable without physical access.

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

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Conventions, checklists, guardrails for working in this repo |
| `context/index.md` | Read-order for a fresh session; pointers to the live-state files below |
| `context/todo.md` | Outstanding tasks and their state (source of truth for project status) |
| `context/decisions.md` | Dated log of decisions made and rejected |
| `context/open_questions.md` | Unresolved questions with status and resolution path |
| `dev/CODEMAP.md` | Where things live: per-function purposes, for locating code |
| `dev/SKELETON.md` | How it works: logic flow and key invariants (incl. the hardware-validated behaviors) |
| `dev/features/dynavlan.md` | Technical design: architecture, backend seam, apply/rollback state machine, module decomposition, systemd/install layout |
| `dev/features/dynavlan-tests.md` | Test plan: unit assert cases, `--dry-run` verification, hardware integration checklist |
| `docs/dynavlan-PRD.md` | Product requirements: authoritative FR/NFR/AC with severity+impact tags |
| `docs/deployment-guide.md` | Deployment guide: install, configure, first attended run, operation, removal |
| `README.md` | Landing page: what the project is and where the docs are |
| `CHANGELOG.md` | What changed per release |

Keep this table current; each file gets one clear role.

## Non-Obvious Behaviors

Hardware-validated netplan/NIC behaviors that strand the box or silently lose monitoring if violated live in `dev/SKELETON.md` (Key Invariants + the accept primitive). Read it before touching the apply, detection, or removal paths - these facts are not derivable from the code.

## Security Context

Runs as root, typically on a remote, headless, or unattended box. The threat model is accidental self-inflicted footguns (stranding the box, hijacking the uplink route, leaking network topology), not adversarial input. Recoverability outweighs everything: defensive code is warranted specifically around the apply/rollback path, not general input hardening. Captured VLAN IDs and subnets are confidentiality-sensitive: logs stay local, sniff uses a minimal snaplen and never persists frames.

## Development Workflow

- Before coding any change: read `dev/SKELETON.md` + `dev/CODEMAP.md` (and `dev/features/dynavlan.md` for design depth) to identify the blast radius, then locate the specific functions. Don't start editing until you know what's affected.
- New logic: TDD pure helpers in `tests/unit.sh` first (RED before GREEN, per `superpowers:test-driven-development`); wire integration code cohesively - the apply/rollback state machine is too coupled for subagent fan-out.
- There is no hot-reload: dynavlan installs as a systemd service + timer. Hardware testing happens on the real appliance on the real trunk with console access, never only over SSH (a bad apply drops the connection). No VM.

### Code Review Before Release

- **Patch (x.y.Z)**: review only the changed units
- **Minor (x.Y.0)**: review all units added or modified in the release
- **Major (X.0.0)**: full review of the relevant surface

Address CRITICAL and HIGH issues before committing.

## Git Approvals

Each step requires explicit user approval. Approval for one step does not imply approval for the next.

1. **Commit**: propose the commit message and changed files, wait for approval before `git commit`.
2. **Push**: wait for explicit approval before `git push`.
3. **Release**: only the user can authorize a release. A release requires `git tag vX.Y.Z`, `git push origin vX.Y.Z`, and `gh release create vX.Y.Z` on `pereljon/dynavlan` (gh account: pereljon). Commit or push do not imply release.

After completing work, ask which steps the user wants: "Want to commit, push, or release?"

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
- version in the `dynavlan` script (`ver=` variable) bump if needed (semver: patch/minor/major)
- systemd units (`dynavlan.service`/`dynavlan-rescan.service`/`dynavlan.timer`) and `install.sh` if artifacts change

When making multiple changes, consider logical ordering: some changes should come before others (e.g. move code before updating references to it; validate inputs before using them).
