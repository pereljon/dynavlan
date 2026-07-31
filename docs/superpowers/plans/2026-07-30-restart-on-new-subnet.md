# Restart-on-new-subnet (FR-40) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restart the nominated monitoring snaps/services whenever a new global-IPv4 subnet appears on the box (a late-plugged access/native interface, or the base uplink leasing after the agent started), not only when a tagged VLAN changes.

**Architecture:** A monotonic "seen this boot" set of `iface:subnet` tokens is kept in `/run/dynavlan/seen` (tmpfs, wiped on reboot). At the end of every `--boot`/`--rescan` run, `main` samples the current global-IPv4 subnets, and if any are new relative to `seen` it calls the existing `restart_targets` (once per run, deduped against any VLAN-driven restart `apply_change` already did), then grows `seen`. `apply_change` (the safety-critical accept/rollback chain) is untouched. Design spec: `docs/superpowers/specs/2026-07-30-restart-on-new-subnet-design.md`.

**Tech Stack:** Single-file POSIX-ish bash (`dynavlan`), `ip` from iproute2, plain-assert unit tests (`tests/unit.sh`), systemd service+timer.

## Global Constraints

- **Single self-contained file.** All script code lives in `./dynavlan`; no new script files, no build step. (design §1)
- **Indentation is TABS**, matching the existing script and `tests/unit.sh`.
- **No em-dashes** in any code, comment, or doc text. Use commas/colons/semicolons/periods.
- **Prefer expanded multi-line guards** over dense one-liners.
- **Every script edit runs `bash -n dynavlan` and `bash tests/unit.sh` before commit.** Both must pass. (§ Version and build identity)
- **Never touch the `build=` line.** It stays a single unindented `build=` assignment at column 0; `install.sh` stamps it and `tests/unit.sh` 1l enforces it.
- **`ver=` is at `dynavlan:15`, currently `0.2.1`.** This feature bumps it to `0.3.0` (minor: new behavior + new config key), once, in Task 2. Later script tasks do not re-bump.
- **Subnet tokens are strings** (`enp3s0:10.0.5.0/24`), so canonical ordering uses `emit_tokens` / `set_union` (lexical `sort -u`), NEVER `emit_set` (which is `sort -n` and is numeric-only).
- **`--dry-run` and `--status` stay side-effect-free:** they may read `/run/dynavlan/seen` but never write it and never restart.

---

### Task 1: `ipv4_network` pure helper

Reduces an IPv4 address + prefix to its network address, so a DHCP renewal within the same pool yields an identical subnet token. This is the only new pure logic; everything else reuses existing tested set helpers.

**Files:**
- Modify: `dynavlan` (add function in the pure-helpers area, alongside `emit_set`/`set_minus`, near `dynavlan:56-366`)
- Test: `tests/unit.sh` (new section `1q`, appended just before the final `printf '\n%s tests...` summary block at the end of the file)

**Interfaces:**
- Consumes: nothing.
- Produces: `ipv4_network ADDR PREFIX` -> prints the dotted-quad network address. Examples: `ipv4_network 10.0.5.55 24` -> `10.0.5.0`; `ipv4_network 10.0.5.200 25` -> `10.0.5.128`; `ipv4_network 172.16.9.4 12` -> `172.16.0.0`; `ipv4_network 10.0.5.55 32` -> `10.0.5.55`; `ipv4_network 10.11.12.13 8` -> `10.0.0.0`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/unit.sh` immediately before the final summary block (`printf '\n%s tests, %s failures\n' ...`):

```bash
# ---------------------------------------------------------------------------
# 1q. ipv4_network - address+prefix -> network address (FR-40 subnet keying)
#     Keying subnet tokens on the network (not the host address) is what makes a
#     same-pool DHCP renewal produce an identical token, so it must NOT restart.
call ipv4_network 10.0.5.55 24;   ok "1q /24 zeroes the last octet"        "10.0.5.0"
call ipv4_network 10.0.5.200 25;  ok "1q /25 non-octet boundary (.128)"    "10.0.5.128"
call ipv4_network 10.0.5.55 26;   ok "1q /26 non-octet boundary (.0)"      "10.0.5.0"
call ipv4_network 172.16.9.4 12;  ok "1q /12 masks into the third octet"   "172.16.0.0"
call ipv4_network 10.11.12.13 8;  ok "1q /8 keeps only first octet"        "10.0.0.0"
call ipv4_network 10.0.5.55 32;   ok "1q /32 is the host itself"           "10.0.5.55"
call ipv4_network 192.168.1.1 0;  ok "1q /0 is all-zero network"           "0.0.0.0"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/unit.sh`
Expected: FAIL lines for the `1q` cases (`ipv4_network: command not found` / empty output, non-zero).

- [ ] **Step 3: Write the minimal implementation**

Add to `dynavlan` in the pure-helpers block (e.g. just after `emit_set`'s closing brace near `dynavlan:59`):

```bash
# Network address for an IPv4 ADDR under PREFIX (0-32), as a dotted quad. Pure.
# Subnet tokens key on this, not the host address, so a same-pool DHCP renewal
# maps to an identical token and does not trigger a restart (FR-40).
ipv4_network() { # ADDR PREFIX -> network dotted-quad
	local addr="$1" prefix="$2"
	local o1 o2 o3 o4 ip mask net
	IFS=. read -r o1 o2 o3 o4 <<<"$addr"
	ip=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
	if [ "$prefix" -le 0 ]; then
		mask=0
	elif [ "$prefix" -ge 32 ]; then
		mask=4294967295
	else
		mask=$(( (4294967295 << (32 - prefix)) & 4294967295 ))
	fi
	net=$(( ip & mask ))
	printf '%d.%d.%d.%d\n' \
		$(( (net >> 24) & 255 )) \
		$(( (net >> 16) & 255 )) \
		$(( (net >> 8) & 255 )) \
		$(( net & 255 ))
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/unit.sh`
Expected: all `1q` lines `ok`, final line `N tests, 0 failures`.
Also run: `bash -n dynavlan` -> no output (syntax OK).

- [ ] **Step 5: Commit**

No `ver=` bump: an inert pure helper, not yet wired into any run, changes no behavior/output/config surface. State that explicitly in the message.

```bash
git add dynavlan tests/unit.sh
git commit -m "feat: ipv4_network pure helper for FR-40 subnet keying

Inert helper only; not yet wired. No ver= bump (no behavior/output/config change).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TMSULr57Pohsdd7EeQREh1"
```

---

### Task 2: `RESTART_ON_NEW_SUBNET` config key + version bump

Adds the boolean that gates the feature (default on), with the same strict-validation pattern as the other booleans, plus the config template entry. Bumps `ver=` for the whole feature here, since a new config key is a config-surface change (FR-38).

**Files:**
- Modify: `dynavlan` (default near `dynavlan:429`; validation near `dynavlan:523-530`; `ver=` at `dynavlan:15`)
- Modify: `dynavlan.conf` (template entry after the `PER_VLAN_MAC` line, `dynavlan.conf:29`)

**Interfaces:**
- Consumes: nothing.
- Produces: global `RESTART_ON_NEW_SUBNET` (string `true`/`false`, default `true`) validated by `load_config`; consumed by Task 3's `maybe_restart_on_new_subnet` and Task 4's reporting.

- [ ] **Step 1: Add the default**

In `load_config`'s defaults block, immediately after `PER_VLAN_MAC=false` (`dynavlan:429`):

```bash
	PER_VLAN_MAC=false
	RESTART_ON_NEW_SUBNET=true
```

- [ ] **Step 2: Add the validation**

In `load_config`, immediately after the `PER_VLAN_MAC` implemented-guard block (after `dynavlan:530`, before `return 0`):

```bash
	in_list "$RESTART_ON_NEW_SUBNET" "true false" || {
		log err "invalid RESTART_ON_NEW_SUBNET=$RESTART_ON_NEW_SUBNET"
		return 1
	}
```

- [ ] **Step 3: Bump the version**

At `dynavlan:15`, change:

```bash
ver="0.2.1"
```
to:
```bash
ver="0.3.0"
```

- [ ] **Step 4: Add the config template entry**

In `dynavlan.conf`, after the `PER_VLAN_MAC` line (`dynavlan.conf:29`), matching the existing `# KEY=default   # comment` column style:

```bash
# RESTART_ON_NEW_SUBNET=true                     # restart RESTART_SNAPS/SERVICES when a new IPv4 subnet appears on any interface (base/native/access or a dynavlan VLAN), not only on a tagged-VLAN change; no-op if no restart targets are set (FR-40)
```

- [ ] **Step 5: Verify syntax, tests, and validation behavior**

Run: `bash -n dynavlan` -> no output.
Run: `bash tests/unit.sh` -> `N tests, 0 failures` (1l still sees exactly one `ver=` and one `build=` line; the bump only changes the value).
Run the negative-validation smoke check:

```bash
RESTART_ON_NEW_SUBNET=maybe bash -c 'source ./dynavlan; CONF_FILE=/nonexistent load_config; echo rc=$?' 2>&1 | tail -2
```
Expected: an `invalid RESTART_ON_NEW_SUBNET=maybe` err line and `rc=1`.
Run the default-accepts check:

```bash
bash -c 'source ./dynavlan; CONF_FILE=/nonexistent load_config && echo "default ok: $RESTART_ON_NEW_SUBNET"'
```
Expected: `default ok: true`.

- [ ] **Step 6: Commit**

```bash
git add dynavlan dynavlan.conf
git commit -m "feat: RESTART_ON_NEW_SUBNET config key (default on), bump 0.3.0

New config surface for FR-40; ver bump minor per FR-38. Runtime behavior lands next task.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TMSULr57Pohsdd7EeQREh1"
```

---

### Task 3: subnet snapshot, seen-set, and the growth-triggered restart

The behavior-bearing task: sample current global-IPv4 subnets, diff against the monotonic `/run` seen-set, restart once on growth (deduped against `apply_change`'s VLAN restart), and grow the seen-set. Wired into `main` after the boot/rescan dispatch so it runs on every internal exit path of both modes but not for dry-run/status/reapply. This is cohesive integration code touching the run lifecycle; execute it inline, not fanned out (CLAUDE.md).

**Files:**
- Modify: `dynavlan` (new functions near `restart_targets` at `dynavlan:1093-1109`; one-line dedup flag inside `restart_targets`; wiring in `main` at `dynavlan:1673`)

**Interfaces:**
- Consumes: `ipv4_network` (Task 1); `emit_tokens`, `set_minus`, `set_union` (existing); `restart_targets`, `RESTART_SNAPS`, `RESTART_SERVICES` (existing); `RESTART_ON_NEW_SUBNET` (Task 2); `log` (existing).
- Produces:
  - `current_subnets` -> sorted set of `iface:network/prefix` tokens for every global-scope IPv4 address now on the box.
  - `read_seen` -> contents of `/run/dynavlan/seen` (empty string if absent).
  - `write_seen SET` -> writes SET to `/run/dynavlan/seen` (creates `/run/dynavlan`).
  - `maybe_restart_on_new_subnet` -> the FR-40 rule; restarts at most once per run, honoring `RESTARTED_THIS_RUN`.
  - global `RESTARTED_THIS_RUN` (set to `1` by `restart_targets`).
  - Task 4 reuses `current_subnets` and `read_seen`.

- [ ] **Step 1: Add the dedup flag to `restart_targets`**

At the top of `restart_targets` (`dynavlan:1093`), record that a restart happened this run so the growth-check does not fire a second time:

```bash
restart_targets() {
	local s
	RESTARTED_THIS_RUN=1
	for s in $RESTART_SNAPS; do
```

- [ ] **Step 2: Add the seen-set and snapshot helpers**

Insert after `restart_targets`'s closing brace (`dynavlan:1109`):

```bash
# FR-40 ephemeral state: subnets the agent is known to have seen THIS uptime.
# /run is tmpfs, wiped on reboot, which is exactly the required lifetime (on
# reboot the agent relaunches and re-enumerates, so the baseline must reset).
# This is runtime scratch, NOT persistent config: config state still lives only
# in the owned netplan file.
SEEN_FILE="${SEEN_FILE:-/run/dynavlan/seen}"

# Current global-scope IPv4 subnets as sorted `iface:network/prefix` tokens.
# `scope global` excludes loopback (127/8, scope host) and IPv4 link-local
# (169.254/16, scope link): a link-local address means DHCP FAILED and must not
# count as a subnet. The token keys on the network, so a same-pool renewal is a
# no-op (see ipv4_network).
current_subnets() {
	local idx ifc fam cidr rest addr prefix net out=""
	while read -r idx ifc fam cidr rest; do
		# Skip non-CIDR field-4 forms: a peer/point-to-point line renders as
		# `inet 10.8.0.1 peer 10.8.0.2/32 scope global`, where the LOCAL address
		# in field 4 carries no /prefix. Without this, `${cidr#*/}` would yield
		# the whole address as the "prefix" and ipv4_network would error on every
		# run (tun/ppp/VPN interfaces on a monitored box hit this).
		case "$cidr" in
			*/*) ;;
			*) continue ;;
		esac
		addr=${cidr%/*}
		prefix=${cidr#*/}
		net=$(ipv4_network "$addr" "$prefix")
		out="$out ${ifc}:${net}/${prefix}"
	done < <(ip -4 -o addr show scope global 2>/dev/null)
	emit_tokens $out
}

read_seen() { # -> seen-set contents, empty if the file is absent
	cat "$SEEN_FILE" 2>/dev/null || true
}

write_seen() { # SET
	mkdir -p "$(dirname "$SEEN_FILE")" 2>/dev/null || true
	printf '%s\n' "$1" >"$SEEN_FILE" 2>/dev/null \
		|| log warning "could not write $SEEN_FILE; next run may restart again"
}

# FR-40 rule, run once at the end of every --boot/--rescan (see main). On the
# first run of an uptime SEEN_FILE is absent, so `seen` is empty and every
# current subnet is "new": the agent is restarted once after the network has
# settled, regardless of whether it started before or after DHCP. A per-run
# RESTARTED_THIS_RUN flag dedups against any VLAN restart apply_change already did.
maybe_restart_on_new_subnet() {
	[ "$RESTART_ON_NEW_SUBNET" = true ] || return 0
	local current seen new
	current=$(current_subnets)
	seen=$(read_seen)
	new=$(set_minus "$current" "$seen")
	if [ -n "$new" ]; then
		if [ "${RESTARTED_THIS_RUN:-0}" = 1 ]; then
			log info "new IPv4 subnet(s) [$new]; agent already restarted this run"
		else
			log notice "new IPv4 subnet(s) [$new]; restarting monitoring targets"
			restart_targets
		fi
	fi
	write_seen "$(set_union "$seen" "$current")"
}
```

- [ ] **Step 3: Wire it into `main`**

At `dynavlan:1673`, in the `--boot | --rescan` arm, call the growth-check after the mode returns (still under the flock, so it stays serialized), before the `run end` log:

```bash
		if [ "$mode" = --boot ]; then do_boot; else do_rescan; fi
		rc=$?
		maybe_restart_on_new_subnet
		log info "run end: mode=${mode#--} rc=$rc"
		return $rc
```

- [ ] **Step 4: Verify syntax and unit tests**

Run: `bash -n dynavlan` -> no output.
Run: `bash tests/unit.sh` -> `N tests, 0 failures` (pure-helper suite unchanged; new glue is impure and not asserted here).

- [ ] **Step 5: Behavioral smoke test with a temp seen-file (no root, no restart targets)**

With `RESTART_SNAPS`/`RESTART_SERVICES` empty, `restart_targets` is a no-op, so this is safe to run locally. It exercises the seen-set diff logic against a fake current set:

```bash
tmp=$(mktemp -d)
bash -c '
	source ./dynavlan
	SEEN_FILE="'"$tmp"'/seen"
	RESTART_ON_NEW_SUBNET=true
	RESTART_SNAPS=""; RESTART_SERVICES=""
	current_subnets() { printf "enp3s0:10.0.5.0/24\n"; }   # stub live state
	echo "run1:"; maybe_restart_on_new_subnet; echo "  seen=[$(cat "$SEEN_FILE")] flag=${RESTARTED_THIS_RUN:-0}"
	RESTARTED_THIS_RUN=0
	echo "run2 (same subnet):"; maybe_restart_on_new_subnet; echo "  flag=${RESTARTED_THIS_RUN:-0}"
	RESTARTED_THIS_RUN=0
	current_subnets() { printf "enp3s0:10.0.5.0/24\nenp4s0:10.0.9.0/24\n" | tr "\n" " " | sed "s/ $//"; }
	echo "run3 (new subnet appears):"; maybe_restart_on_new_subnet 2>&1 | grep -o "new IPv4 subnet.*restarting monitoring targets"
' 2>&1
rm -rf "$tmp"
```
Expected: run1 logs a restart and seeds `seen=[enp3s0:10.0.5.0/24]`; run2 (same subnet) does NOT log a restart and leaves the flag `0`; run3 logs `new IPv4 subnet(s) [enp4s0:10.0.9.0/24]; restarting monitoring targets`.

- [ ] **Step 6: Commit**

No `ver=` re-bump (already `0.3.0` from Task 2); this is the runtime half of the same version.

```bash
git add dynavlan
git commit -m "feat: restart monitoring on a newly-appeared IPv4 subnet (FR-40)

Monotonic /run seen-set; growth-check runs after boot/rescan, deduped against
apply_change's VLAN restart. apply_change untouched.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TMSULr57Pohsdd7EeQREh1"
```

---

### Task 4: `--dry-run` and `--status` report the would-restart delta

Operator visibility: show which subnets would trigger a restart, reading the seen-set without ever writing it or restarting.

**Files:**
- Modify: `dynavlan` (`do_dryrun` near its end around `dynavlan:1450`; `do_status` near its end around `dynavlan:1560`)

**Interfaces:**
- Consumes: `current_subnets`, `read_seen`, `set_minus` (Task 3); `RESTART_ON_NEW_SUBNET` (Task 2).
- Produces: printed report lines only; no new callable surface, no writes.

- [ ] **Step 1: Add a shared report line to `do_dryrun`**

Near the end of `do_dryrun`, after the existing additions/removals print block (before its final `return`), add:

```bash
	if [ "$RESTART_ON_NEW_SUBNET" = true ]; then
		local cur_sn new_sn
		cur_sn=$(current_subnets)
		new_sn=$(set_minus "$cur_sn" "$(read_seen)")
		printf '  new IPv4 subnets since last seen (would restart): [%s]\n' "${new_sn:-none}"
	fi
```

- [ ] **Step 2: Add the same report to `do_status`**

Near the end of `do_status`, after its per-trunk report loop (before its final `return`), add:

```bash
	if [ "$RESTART_ON_NEW_SUBNET" = true ]; then
		local cur_sn new_sn
		cur_sn=$(current_subnets)
		new_sn=$(set_minus "$cur_sn" "$(read_seen)")
		printf 'new IPv4 subnets since last seen (would restart): [%s]\n' "${new_sn:-none}"
	fi
```

- [ ] **Step 3: Verify syntax, tests, and that the seen-file is not written**

Run: `bash -n dynavlan` -> no output.
Run: `bash tests/unit.sh` -> `N tests, 0 failures`.
Confirm read-only reporting logic writes nothing:

```bash
tmp=$(mktemp -d)
bash -c '
	source ./dynavlan
	SEEN_FILE="'"$tmp"'/seen"; RESTART_ON_NEW_SUBNET=true
	current_subnets() { printf "enp3s0:10.0.5.0/24\n"; }
	cur_sn=$(current_subnets); new_sn=$(set_minus "$cur_sn" "$(read_seen)")
	printf "would restart: [%s]\n" "${new_sn:-none}"
	[ -e "$SEEN_FILE" ] && echo "BUG: seen file written" || echo "ok: no seen file written"
'
rm -rf "$tmp"
```
Expected: `would restart: [enp3s0:10.0.5.0/24]` then `ok: no seen file written`.

- [ ] **Step 4: Commit**

```bash
git add dynavlan
git commit -m "feat: report would-restart subnet delta in --dry-run and --status (FR-40)

Read-only: samples current subnets vs the seen-set, never writes or restarts.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TMSULr57Pohsdd7EeQREh1"
```

---

### Task 5: Documentation, PRD, invariants, changelog

Bring every context/design/requirement doc in line with the shipped behavior, per the CLAUDE.md Change Checklist. No code changes.

**Files:**
- Modify: `docs/dynavlan-PRD.md` (new FR-40)
- Modify: `dev/SKELETON.md` (amend the "state lives in the owned YAML" invariant; add the growth-check to the run lifecycle / side-effects notes)
- Modify: `dev/CODEMAP.md` (rows for `ipv4_network`, `current_subnets`, `read_seen`, `write_seen`, `maybe_restart_on_new_subnet`)
- Modify: `dev/features/dynavlan.md` (design: the seen-set, `/run` storage rationale, where the growth-check hooks into `main`)
- Modify: `dev/features/dynavlan-tests.md` (the `1q` unit cases; the FR-40 hardware checklist items)
- Modify: `README.md` (mention restart-on-new-subnet in the behavior/config summary)
- Modify: `dynavlan.conf` is already done in Task 2 (no action; listed for completeness)
- Modify: `CHANGELOG.md` (0.3.0 entry)
- Modify: `context/todo.md` (FR-40 milestone), `context/decisions.md` (dated entry pointing at the spec)

**Interfaces:** none (documentation).

- [ ] **Step 1: PRD - add FR-40**

In `docs/dynavlan-PRD.md`, after FR-39, add FR-40 with the severity/impact tag style used by neighboring FRs. Content: "Restart the nominated `RESTART_SNAPS`/`RESTART_SERVICES` when a new global-scope IPv4 subnet appears on any interface (base/native/access or a dynavlan VLAN), gated by `RESTART_ON_NEW_SUBNET` (default true)." Acceptance criteria to state explicitly:
  - Token is `interface:subnet`, keyed on the network address + prefix, not the box's host address; a same-pool DHCP renewal does not restart.
  - Seen-set is monotonic per uptime, stored in `/run/dynavlan/seen`, wiped on reboot; a flap of the same subnet does not restart.
  - On boot the empty seen-set makes any present subnet "new", so the agent is restarted once after settle (fixes the agent-started-before-DHCP race); at most one restart per run (deduped against the VLAN restart).
  - `169.254/16` and loopback are excluded (a link-local address is not a usable subnet).
  - `--dry-run`/`--status` report the delta and never restart or write the seen-set.

- [ ] **Step 2: SKELETON - amend the invariant and note the growth-check**

In `dev/SKELETON.md`:
  - Under "Key invariants", change the "State lives in the owned YAML" bullet to scope it: *persistent configuration* state lives in the owned YAML and there are no sidecar config/state files; the FR-40 seen-set is *ephemeral runtime scratch* in `/run/dynavlan/seen`, wiped on reboot, never configuration.
  - Under the run lifecycle / "Side effects are change-gated" note, add that `--boot`/`--rescan` also run a subnet growth-check after `apply_change` that can restart targets once (deduped) when a new global-IPv4 subnet appears, and that this is the one restart trigger not gated on the VLAN token set. Note explicitly that `apply_change` is unchanged.
  - State explicitly that the growth-check runs on EVERY boot/rescan exit path regardless of the mode's return code, so it may restart on the base uplink subnet even when the VLAN apply health-FAILed and reverted, or was refused by the `VLAN_LIMIT` gate. This is intended: subnet appearance is independent of VLAN provisioning success, it is at most one cheap restart, and it is exactly the agent-started-before-DHCP boot-race fix.

- [ ] **Step 3: CODEMAP - add the function rows**

In `dev/CODEMAP.md`: add `ipv4_network` to the pure-helpers table (with test ref `1q`); add `current_subnets`, `read_seen`, `write_seen`, `maybe_restart_on_new_subnet` to the change-gated side-effects section (near `wait_leases`/`restart_targets`), one-line purpose each.

- [ ] **Step 4: Design doc - the mechanism**

In `dev/features/dynavlan.md`: add a short subsection describing the seen-set (`iface:subnet`, monotonic, `/run`), why `/run` and not the YAML (lifetime + safety-critical-file avoidance), the empty-seen-at-boot rule, the dedup flag, and the `main` hook point after `do_boot`/`do_rescan`.

- [ ] **Step 5: Test plan - unit + hardware**

In `dev/features/dynavlan-tests.md`: record the `1q` `ipv4_network` assert cases, and add FR-40 hardware checklist items: (a) plug an access port in after boot, confirm the next rescan restarts the agent exactly once and seeds the subnet; (b) force a same-subnet DHCP renewal, confirm no restart; (c) boot with the agent starting before DHCP, confirm it is restarted after settle; (d) confirm `--dry-run`/`--status` show the delta and write no `/run/dynavlan/seen`.

- [ ] **Step 6: README + CHANGELOG + context**

  - `README.md`: one line in the behavior/config summary noting restart-on-new-subnet and the `RESTART_ON_NEW_SUBNET` default.
  - `CHANGELOG.md`: a `0.3.0` entry summarizing FR-40 (restart on a newly-appeared IPv4 subnet; new `RESTART_ON_NEW_SUBNET` key, default on; also covers the agent-started-before-DHCP boot race).
  - `context/todo.md`: add the FR-40 milestone at its current state (`code-complete`, pending hardware validation).
  - `context/decisions.md`: dated entry summarizing the seven decisions, pointing at `docs/superpowers/specs/2026-07-30-restart-on-new-subnet-design.md`.

- [ ] **Step 7: Commit**

```bash
git add docs/dynavlan-PRD.md dev/SKELETON.md dev/CODEMAP.md dev/features/dynavlan.md dev/features/dynavlan-tests.md README.md CHANGELOG.md context/todo.md context/decisions.md
git commit -m "docs: FR-40 restart-on-new-subnet across PRD, design, context, changelog

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TMSULr57Pohsdd7EeQREh1"
```

---

## Post-plan: verification and release

- **Code review before release** (CLAUDE.md): this is a minor (x.Y.0), so review all units added or modified. Address CRITICAL/HIGH before committing the release.
- **Hardware validation is mandatory before claiming it works** (CLAUDE.md Testing Plan): run the Task 5 Step 5 hardware checklist on the Protectli box with console access. Until then the FR-40 milestone stays `code-complete`, not `hardware-validated`.
- **Release** is user-authorized only: `git tag v0.3.0`, push the tag, `gh release create v0.3.0` on `pereljon/dynavlan`.

## Self-Review

- **Spec coverage:** Decision 1 (gained-IPv4) -> Task 3 `maybe_restart_on_new_subnet`. Decision 2 (iface:subnet, network-keyed) -> Task 1 `ipv4_network` + Task 3 `current_subnets`. Decision 3 (monotonic seen) -> Task 3 `set_union` grow. Decision 4 (empty-seen-at-boot) -> Task 3 `read_seen` absent=empty + `main` wiring. Decision 5 (apply_change untouched, deduped) -> Task 3 `RESTARTED_THIS_RUN` in `restart_targets`, growth-check in `main` not in `apply_change`. Decision 6 (`/run` storage) -> Task 3 `SEEN_FILE`. Decision 7 (`RESTART_ON_NEW_SUBNET` default on) -> Task 2. Edge cases (renewal/renumber/loss/flap/self-assigned/no-IP/static/boot-race) all fall out of network-keying + monotonic seen + `scope global`, exercised by Task 3 Step 5 and the Task 5 hardware checklist. Docs/version/invariant -> Tasks 2 and 5.
- **Placeholder scan:** every code step has literal bash; every test step has literal commands and expected output. No TBD/TODO.
- **Type consistency:** `ipv4_network ADDR PREFIX` used identically in Tasks 1 and 3. `current_subnets`/`read_seen`/`set_minus` signatures match between Tasks 3 and 4. `RESTARTED_THIS_RUN` set in `restart_targets` (Task 3 Step 1) and read in `maybe_restart_on_new_subnet` (Task 3 Step 2). `SEEN_FILE` defined once (Task 3) and reused read-only in Task 4. Subnet-token ordering uses `emit_tokens`/`set_union` throughout, never `emit_set`.
