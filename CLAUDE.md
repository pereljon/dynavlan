---
title: Development Project
description: Self-bootstrapping scaffold for a software project. Behavioral directives, folder structure, and live-state context files are created on first run.
template_version: 1
---


# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Start Here

On a fresh session or after a compact: read `context/index.md` first (read-order + live state). dynavlan is code-complete (reviewed, NOT yet exercised on hardware); before coding a change read `dev/SKELETON.md` (logic flow + invariants), then `docs/dynavlan-PRD.md` (authoritative requirements) and `dev/features/dynavlan.md` (technical design) for the affected area. The current next action is in `context/todo.md` (Step 5, hardware checklist). `dev/CODEMAP.md` maps every function for locating code.

## Project

**dynavlan** -- a self-configuring VLAN provisioning tool for headless netplan/systemd-networkd Linux boxes (hardware- and vendor-agnostic; validated on a Protectli/igb appliance). Single-file bash. It discovers the active tagged VLANs on whatever trunk the box is plugged into, brings each up with DHCP (address-only, fully route/DNS-isolated by default), and restarts the nominated snaps/services (e.g. the Domotz agent snap) so an interface-enumerating agent picks up the new subnets, with no SSH and no hand-edited YAML. Runs at boot and on a timer. Deployment steps: `docs/deployment-guide.md`.

Audience: infrastructure tool that runs unattended on client sites with no remote console. Safety and recoverability dominate every decision; a bad apply that breaks the uplink is unrecoverable remotely.

## Design Principles

Infrastructure, not a framework. Never surprise the operator; never strand the box.

- **Never strand a headless box:** every apply is validated, health-checked against a pre-apply default-route snapshot, and auto-reverts (`netplan try`). Every failure path fails toward "no change, reachable, logged." Rollback is gated on a routing health check, never on an exit code.
- **Own one namespace, touch nothing else:** dynavlan owns exactly one generated netplan file and never reads base config for assumptions nor modifies any other file.
- **Discover, don't assume:** interfaces, the trunk, and VLANs are all discovered from live kernel state and the wire. No hardcoded interface names, VLAN IDs, native VLAN, or base filenames.
- **Smallest thing that works:** no speculative backends, frameworks, or test infrastructure until a real second case exists. The backend seam is structured for portability but has one implementation.
- **Company- and hardware-agnostic:** works on any netplan/systemd-networkd Ubuntu box, any switch vendor, any VLAN scheme.

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
- `dynavlan` is intentionally a single self-contained file (design §1); file-size caps from global rules (e.g. an 800-line limit) do NOT apply here. Optimize for clarity, never compress logic or drop comments to hit a line count. Expanded multi-line guards are preferred over dense one-liners.

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
| `dev/features/dynavlan.md` | dynavlan technical design: architecture, backend seam, apply/rollback state machine, module decomposition, systemd/install layout |
| `dev/features/dynavlan-tests.md` | dynavlan test plan: unit assert cases (1a-1f), `--dry-run` verification, hardware integration checklist |
| `docs/dynavlan-PRD.md` | dynavlan product requirements (v3.2): authoritative FR/NFR/AC with severity+impact tags |
| `docs/deployment-guide.md` | dynavlan deployment guide: install, configure, first attended run, operation, removal |
| `README.md` | Landing page: what the project is and where the docs are |
| `CHANGELOG.md` | What changed per release |

Keep this table current; each file gets one clear role. The `dev/features/<feature>.md` + `<feature>-tests.md` convention is in use for dynavlan.

## Non-Obvious Behaviors

Hardware/netplan behaviors validated on a real Protectli/igb Ubuntu 22.04 box. These are not derivable from reading code; getting them wrong strands the box or silently loses monitoring. Full design in `dev/features/dynavlan.md`, requirements in `docs/dynavlan-PRD.md`.

- **VLAN removal needs explicit `ip link delete`**: dropping a VLAN's stanza from netplan and running `netplan apply` leaves the interface up with its lease until reboot. Removals must delete the interface explicitly, and ONLY after `netplan try` ACCEPT (never on revert, or netplan's file-revert cannot recreate the destroyed interface).
- **Full VLAN isolation needs four keys**: `use-routes/use-dns/use-ntp/use-domains` all false. `use-routes: false` alone still lets networkd pin the VLAN's DHCP DNS/NTP servers (observed: public OpenDNS) as host routes on the interface.
- **Passive sniff needs promisc ON**: promiscuous mode bypasses the NIC's `rx-vlan-filter` (on+fixed on igb) so unconfigured VLANs are visible. `rx-vlan-offload` is already off on igb, so no tag stripping and no `ethtool -K` needed.
- **Rollback is health-check-gated, not exit-code-gated**: `netplan apply`/`try` exit codes do not reliably reflect routing health. Snapshot the pre-apply default route (iface/gw/metric); after apply, PASS iff the lowest-metric default still egresses the snapshot interface (compare iface only). `netplan try` is the revert mechanism, driven headlessly via a fifo.
- **flock must be an open fd**: kernel-released on process death. A manual lockfile with unlink-on-exit would leave a dead run's lock in place and freeze the tool permanently in "skipped, run in progress."
- **LLDP on Meraki advertises only the native/pvid VLAN**, not the tagged table. Sniff is the primary detector; `DETECT_METHOD=both` is the default for that reason.
- **Boot reconcile has a zero-detection guard**: no carrier / no tags / zero detected must ABORT and change nothing (never interpret "detected nothing" as "remove everything").

## Security Context

Runs as root on a headless appliance at client sites with no remote console. The threat model is accidental self-inflicted footguns (stranding the box, hijacking the uplink route, leaking client network topology), not adversarial input. Recoverability outweighs everything: defensive code is warranted specifically around the apply/rollback path, not general input hardening. Captured client VLAN IDs and subnets are confidentiality-sensitive: logs stay local, sniff uses a minimal snaplen and never persists frames.

## Working Rules

- **Keep context files current**: update `context/` files whenever a task, decision, or open question changes. Stale context compounds errors downstream.

(General working style is in **How I Work** above.)

## Development Workflow

dynavlan is code-complete (built TDD-first per `superpowers:test-driven-development`, four review rounds folded in) but NOT yet exercised on hardware; do not claim any feature works until it has run on the box. Changes follow the same pattern: TDD new pure helpers in `tests/unit.sh` (RED first), wire cohesively (the apply/rollback state machine is too coupled for subagent fan-out), review scoped to the change. There is no hot-reload: it installs as a systemd service + timer; exercise it on the actual Protectli appliance on the live Meraki trunk with console access, never only over SSH (a bad apply drops the connection). No VM: real hardware on the real trunk is the test bed. The outstanding hardware pass is `context/todo.md` Step 5 (checklist rows L3-1..L3-23).

Before coding any change once code exists: read `dev/SKELETON.md` + `dev/CODEMAP.md` (and `dev/features/dynavlan.md` for design depth) to identify the blast radius, then locate the specific functions. Don't start editing until you know what's affected.

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
3. **Release**: only the user can authorize a release. A release requires `git tag vX.Y.Z`, `git push origin vX.Y.Z`, and `gh release create vX.Y.Z` on `pereljon/dynavlan` (gh account: pereljon). Commit or push do not imply release.

After completing work, ask which steps the user wants: "Want to commit, push, or release?"

## Testing Plan

Before coding a new feature or change, review with the user: happy path, edge cases, flag/config conflicts, data/schema migration, interface or prompt updates. Get confirmation before writing code.

Exercise the feature in the real environment before claiming success. Type checking and tests verify code correctness, not feature correctness. If you can't test it, say so explicitly rather than claiming it works.

## Change Checklist

**GATE: Do NOT suggest commit, push, or release until every item below has been checked and all affected files are updated.**

After any code change, check whether these need updating:

- `README.md`
- `/etc/dynavlan.conf` template (new config settings)
- `docs/dynavlan-PRD.md` (requirement changes: FR/NFR/AC)
- `dev/features/dynavlan.md` (design: architecture, state machine, module changes)
- `dev/features/dynavlan-tests.md` (new/changed test cases)
- `dev/CODEMAP.md` / `dev/SKELETON.md` (new/renamed functions, logic-flow or invariant changes)
- `context/` files (todo, decisions, open questions)
- `CLAUDE.md` (if key behaviors changed)
- `CHANGELOG.md` (new features, fixes, removals per release)
- version in the `dynavlan` script (`ver=` variable) bump if needed (semver: patch/minor/major)
- systemd units (`dynavlan.service`/`dynavlan-rescan.service`/`dynavlan.timer`) and `install.sh` if artifacts change

When making multiple changes, consider logical ordering: some changes should come before others (e.g. move code before updating references to it; validate inputs before using them).
