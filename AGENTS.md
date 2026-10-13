# AGENTS.md

Guidance for Claude Code when working in this repository. Shared workflow rules (working rules, testing, design docs, branches and approvals, Change Checklist gate, releases, session hygiene) live in `../AGENTS.md`; this file adds dynavlan specifics.

## Start Here

On a fresh session or after a compact: read `context/index.md` first - it owns the read-order and points at the live-state files (current status, next action, open questions). Do not trust status statements anywhere else.

**Override of `../AGENTS.md` Project state:** this project keeps state in `context/`, not `docs/ISSUES.md`. `context/todo.md` is the milestones layer and source of truth for project status (`designed → planned → code-complete → hardware-validated → released`, one line each); open questions go in `context/open_questions.md`, decisions in `context/decisions.md`. Wherever the shared file says `docs/ISSUES.md`, use these.

## Project

**dynavlan** -- a self-configuring VLAN provisioner for headless netplan/systemd-networkd Linux boxes. Single-file bash. It discovers the active tagged VLANs on every trunk the box is plugged into, brings each up with DHCP (address-only, fully route/DNS-isolated by default), and restarts the nominated snaps/services so an interface-enumerating agent picks up the new subnets, with no SSH and no hand-edited YAML. Runs at boot and on a timer. Deployment steps: `docs/deployment-guide.md`.

Audience: infrastructure tool for boxes that may be remote, headless, or unattended. Safety and recoverability dominate every decision; a bad apply that breaks the uplink may be unrecoverable without physical access.

## Commands

Single bash script, no build step. Dev loop:

```bash
bash tests/unit.sh          # Layer-1 unit suite; run before every commit (enforces the FR-38 version/build identity contract, §1k/1l)
bash githooks/install.sh    # once per clone: FR-38 version-gate hooks (refuses to replace a foreign hook)
bash -n dynavlan            # syntax-check the script
shellcheck -s bash <file>  # ShellCheck 0.11.0 is installed (Homebrew) and in use: run it on every shell file a change touches
./dynavlan --version        # print ver + build id; works with no root and no valid config
sudo ./dynavlan --dry-run   # preview detection + planned adds/removes, validate, NO apply
sudo ./dynavlan --status    # report owned vs detected-now trunks
```

ShellCheck is run by hand, not by the unit suite; compare against `git show HEAD:<file>` to find what the diff introduced. Known false positives: SC2329 (test stubs invoked indirectly), SC2034 (variables used across a `source` boundary), SC2016 (deliberately literal `${...}` text), and SC2086 on the deliberate token-list word splitting.

Install/first-run/removal live in `docs/deployment-guide.md`. Hardware testing is console-backed on the real appliance, never SSH-only (a bad apply drops the link).

## Design Principles

Infrastructure, not a framework. Never surprise the operator; never strand the box.

- **Never strand a headless box:** every apply is validated, health-checked against a pre-apply default-route snapshot, and auto-reverts (`netplan try`). Every failure path fails toward "no change, reachable, logged." Rollback is gated on a routing health check, never on an exit code.
- **Own one namespace, touch nothing else:** dynavlan owns exactly one generated netplan file and never modifies any other netplan file. Discovery makes no assumptions from base config; validation, the overlap check and `--dry-run` do read the merged netplan tree to detect conflicts.
- **Discover, don't assume:** interfaces, the trunk, and VLANs are all discovered from live kernel state and the wire. No hardcoded interface names, VLAN IDs, native VLAN, or base filenames.
- **Smallest thing that works:** no speculative backends, frameworks, or test infrastructure until a real second case exists. The backend seam is structured for portability but has one implementation.
- **Hardware- and vendor-agnostic:** no vendor or NIC-name assumptions in detection; works on a netplan/systemd-networkd box within the documented platform and interface-name limits (validated on a Protectli/igb appliance on Meraki and UniFi trunks).

`dynavlan` is intentionally a single self-contained file (design §1). Optimize for clarity: expanded multi-line guards over dense one-liners, never compressed to save lines.

## Documentation Roles

File-to-role map (what each doc is for): `context/index.md` (## File roles). Keep it current; each file gets one clear role.

## Non-Obvious Behaviors

Hardware-validated netplan/NIC behaviors that strand the box or silently lose monitoring if violated live in `dev/SKELETON.md` (Key Invariants + the accept primitive). Read it before touching the apply, detection, or removal paths. Before coding any change, also read `dev/CODEMAP.md` (and `dev/features/dynavlan.md` for design depth) to find the blast radius.

## Security Context

Runs as root, typically on a remote, headless, or unattended box. The threat model is accidental self-inflicted mistakes (stranding the box, hijacking the uplink route, leaking network topology), not adversarial input. Recoverability outweighs everything: defensive code is warranted specifically around the apply/rollback path, not general input hardening. Captured VLAN IDs and subnets are confidentiality-sensitive: logs stay local, sniff uses a minimal snaplen and never persists frames.

Public repo; the shared PII rule applies. Specifics: the only personal identifier allowed is the maintainer's name (Jonathan Perel); the Debian `Maintainer` field uses a GitHub noreply address. Redact real MACs to an RFC 7042 documentation value (`00:00:5e:00:53:xx`) before committing. IP addresses and VLAN IDs are not PII.

## Testing

Never claim a feature works until it has run on the box. There is no hot-reload and no VM: dynavlan installs as a systemd service + timer, and hardware testing happens on the real appliance on the real trunk with console access.

New logic: TDD pure helpers in `tests/unit.sh` first (RED before GREEN); wire integration code cohesively - the apply/rollback state machine is too coupled for subagent fan-out.

## Workflow Pipeline

1. **Read state** - `context/index.md`.
2. **Scope the change** with the user; confirm the test plan before coding.
3. **Branch**, then find the blast radius (Non-Obvious Behaviors).
4. **Code** - TDD, RED before GREEN.
5. **Code review** on the branch.
6. **Update docs** (Change Checklist), after review so docs describe final code.
7. **Test** - `bash tests/unit.sh`.
8. **Commit** on the branch.
9. **Merge** `--ff-only` to `main` (approval), then re-run tests on `main`.
10. **Push** (approval).
11. **Release** (approval); hardware-validate first.
12. **Session hygiene** - update `context/` files, then clear.

## Change Checklist

Project rows, in addition to the shared gate and generic items in `../AGENTS.md`:

- `dynavlan.conf` template (new config settings)
- `docs/dynavlan-PRD.md` (requirement changes: FR/NFR/AC)
- `dev/features/dynavlan.md` (design: architecture, state machine, module changes)
- `dev/features/dynavlan-tests.md` (new/changed test cases)
- `context/` files (todo, decisions, open questions) - stale context compounds errors downstream
- version in the `dynavlan` script (`ver=` variable) - see **Version and build identity**
- systemd units (`dynavlan.service`/`dynavlan-rescan.service`/`dynavlan.timer`) and `install.sh` if artifacts change
- **When adding a config key**: default + `in_list`/range validation in `load_config`, **the key added to the `CONFIG_KEYS` allowlist** (H2: config is parsed against that allowlist, so a key defaulted but not allowlisted would make its own config line refuse to run), a commented template entry in `dynavlan.conf` at its default, and the FR/config-surface section in `docs/dynavlan-PRD.md`. Removing a documented key later needs a `postinst` conffile migration (an old conffile still carrying it would otherwise refuse after upgrade).
- **When adding a CLI mode/flag**: the dispatch in `main`, the Usage section in `README.md`, and the corresponding FR/AC in `docs/dynavlan-PRD.md`.

## Version and build identity (FR-38) - MANDATORY

A box must always be able to answer "what code is running here" (incident record: `context/decisions.md`, 2026-07-25, FR-38). The shared build-identity rule applies; dynavlan specifics:

1. **Bump `ver=`** for any behavior, output, config, or generated-YAML change.
2. **Never touch `build=`.** `install.sh` stamps it by matching `/^build=/`; it must stay a single, unindented, literal assignment at column 0 (`tests/unit.sh` §1l enforces this).
3. **Commit-time guard:** the `githooks/` hooks refuse a script change without a higher `ver=`. For a reviewed behavior-neutral change (comments only), add one `Version-Bump: none (<reason>)` trailer instead; the trailer is a declaration that review must check, not proof.
4. **Every deploy to a box:** run `dynavlan --version` first. A `-dirty` suffix means the tree had uncommitted changes and the build matches no commit.

## Releases

On `pereljon/dynavlan` (gh account: pereljon). Deliverables for the release gate: the script, its installer, and its packaged config/service templates. Before `git tag`: `bash tests/unit.sh` and `dynavlan --version` reports the expected version.
