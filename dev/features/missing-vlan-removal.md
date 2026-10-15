---
kind: feature
lifecycle: ready
status: drafted and approved 2026-10-15; no code yet
---

# Missing-VLAN removal: design

Owns: the design and decisions for removing owned VLANs that detection no longer sees on a trunk that still has carrier. Does not hold the general architecture (`dev/features/dynavlan.md`), the requirements text (`docs/dynavlan-PRD.md`), or the test cases (`dev/features/missing-vlan-removal-tests.md`).

Investigated against `main` at `f63e6c0` (dynavlan 1.0.0) and the test box running build `633f35e` on 2026-10-13 and 2026-10-15. Terms follow `dev/SKELETON.md`.

## 1. Problem

dynavlan 1.0.0 never removes a VLAN that the switch stops carrying while the trunk keeps carrier. Two cases fail.

**Case A: a trunk with carrier shows no tags.** Boot keeps every owned VLAN on that trunk (FR-23, AC-3). Rescan removes nothing on a trunk with carrier (FR-21, FR-41). The VLANs stay for as long as the trunk has carrier, across any number of reboots.

**Case B: a trunk with carrier shows some tags, but one owned VLAN is gone.** Boot removes the VLAN when it is absent from both boot passes. Rescan never removes it. On a box that does not reboot, the VLAN stays.

The test box shows Case A on both trunks. Tags on `enp2s0` were last seen at 08:28 UTC on 2026-10-13. A reboot at 18:57 UTC on 2026-10-15 logged `trunk enp2s0: empty detection in pass 1 or 2; preserving all owned VLANs` at `info` and changed nothing. All 14 VLAN interfaces remain, with no addresses.

The code matches the spec. The spec is the defect: FR-23 preserves the VLANs "for this boot", which assumes a later run cleans up, and no later run does. `README.md:24` and `README.md:134` also claim that boot removes "VLANs that are gone, on every trunk", which is false for Case A.

### Case C: a trunk port becomes an access port

The switch then sends only untagged frames. Sniff sees no tags, and LLDP reports only the PVID, which `detect_lldp` excludes. So Case C is Case A, and 1.0.0 keeps every owned VLAN on that trunk. The base interface's own DHCP config is not dynavlan's and is unaffected. If the new access VLAN has the same ID as an owned VLAN, the owned tagged VLAN interface is dead, and the base interface now carries that subnet.

## 2. Why the preserve rule exists

Sniff proves that a VLAN exists only when an inbound tagged frame arrives during the sample. A real VLAN with no traffic in the sample window looks exactly like a removed VLAN. Right after boot, the switch may still be converging (STP, LLDP), so a boot sample is the least reliable. FR-23 chose to preserve rather than remove a real but quiet VLAN.

A wrong removal does not strand the box. Rescan adds the VLAN back when traffic appears. The cost is a monitoring gap and an extra restart of the restart targets.

## 3. Design

Remove an owned VLAN when every trusted sample has missed it for `REMOVE_MISSING_MINUTES` (default 15). Boot and rescan both apply the rule, to Case A and Case B alike.

### 3.1 Missing-since state

- dynavlan records, per owned VLAN token, the time of the first trusted sample that missed it.
- The time is the system uptime in whole seconds, read from `/proc/uptime`.
- The state file is `/run/dynavlan/missing-since`, one `TOKEN UPTIME_SECONDS` line per VLAN. It sits next to `pending-delete` and `seen`.
- `/run` is cleared at reboot. The clock therefore restarts at boot, and a VLAN missing at boot is removed `REMOVE_MISSING_MINUTES` later, by a rescan.
- A sample that sees the VLAN deletes its line.
- A removal that is accepted deletes its line.
- A VLAN that is no longer owned has its line dropped on the next write.

**Decision (2026-10-15):** keep the state in `/run`, not `/var/lib`. Rejected: `/var/lib/dynavlan`, which survives reboot and would let a box that moved site remove VLANs on an old clock. Rejected: deriving absence from the journal, which is not a state store and can be rotated or set to volatile.

**Decision (2026-10-15, operator-approved):** the clock is uptime, not wall-clock epoch time. The state lives in `/run`, so uptime covers exactly the same span, and it never jumps. Rejected: epoch time, because the wall clock can jump forward when NTP syncs after boot, so a VLAN that just went missing would look overdue and be removed early. A recorded value above the current uptime is treated as malformed and restarted at the current uptime.

### 3.2 What counts as a miss

A miss is a run in which all of these are true for the VLAN's trunk:

- The trunk had carrier for the sample.
- The sample was trusted: no capture method failed (H1, `DETECT_INVALID`).
- The VLAN ID was absent from the sample.

A run that fails any of these is neither a miss nor a sighting. It leaves the clock alone. A carrier-down trunk stays with FR-41 and its debounce.

### 3.3 When a VLAN is removed

A VLAN is removed in a run when all of these are true:

- `REMOVE_MISSING_MINUTES` is not 0.
- The current run's sample is a miss (3.2).
- `now - missing_since >= REMOVE_MISSING_MINUTES * 60`.
- The box has healthy routing (`have_routing`), as FR-41 requires.

Removals join the run's one change. They go through the normal validate, `netplan try`, health check and revert chain. `ip link delete` runs only after accept (FR-24).

### 3.4 Boot

Boot keeps its two-pass, detection-diff removal for Case B. Boot also updates the missing-since state from its two passes. Boot does not remove a Case A trunk immediately. Its clock starts at boot and a rescan removes the VLANs later.

**Decision (2026-10-15):** no immediate Case A removal at boot. The boot window is the least reliable sample (section 2). Rejected: remove all of a tagless trunk's VLANs at boot. A quiet trunk at boot would lose every VLAN on every reboot.

### 3.5 Logging

- Each run logs, at `warning`, each VLAN that is missing but not yet removed, with the minutes left.
- A removal logs at `notice`, which is the codebase's level for a state change.
- `--status` and `--dry-run` show each missing VLAN and its time left.

### 3.6 Config key

| Key | Default | Valid values |
|-----|---------|--------------|
| `REMOVE_MISSING_MINUTES` | `15`, raised to `RESCAN_MINUTES * 2` when that is larger | `0` (off), or an integer from `RESCAN_MINUTES * 2` to `1440` |

The lower bound makes sure that at least two rescan samples confirm a miss. The range check applies only to a value the operator sets. An unset key takes the larger of `15` and `RESCAN_MINUTES * 2`, even above `1440`.

**Decision (2026-10-15, operator-approved):** the unset default follows `RESCAN_MINUTES`. Why: a fixed default of `15` is below the floor on any box with `RESCAN_MINUTES` of 8 or more, so `load_config` would refuse after the upgrade and the box would stop reconciling. An explicit value keeps the strict check, because no existing conffile sets the new key. Rejected: clamping an explicit value with a warning, which hides an operator's mistake.

**Decision (2026-10-15):** on by default, at 15 minutes (3 rescans at the default interval). Rejected: 60 minutes, which leaves stale VLANs for too long. Rejected: off by default, which keeps the defect on every existing box.

**Compatibility.** `COMPATIBILITY.md` says that a new key whose default changes behavior on an existing box is a breaking change. **Decision (2026-10-15, operator-approved):** treat the change as a fix of FR-23 and AC-3, whose intent was a temporary preserve, so it ships on by default in 1.x without the two-release process. `REMOVE_MISSING_MINUTES=0` restores the 1.0.0 behavior. The release records this reasoning in `context/decisions.md`. Rejected: the deprecate-with-warning process, which would leave the defect on every box for one more release.

### 3.7 `RESET_ON_BOOT`

`RESET_ON_BOOT=false` disables boot's detection-diff removals today. `REMOVE_MISSING_MINUTES` is independent of it, as `REMOVE_ON_CARRIER_LOSS` is (FR-25).

**Decision (2026-10-15):** the new key alone controls missing-VLAN removal. Rejected: letting `RESET_ON_BOOT=false` turn it off, which would tie a rescan-time rule to a boot-only key.

## 4. Requirement changes

- FR-23 and AC-3: replace "preserved for this boot" with the missing-since rule.
- FR-21: rescan gains a second removal path.
- FR-25: state how `RESET_ON_BOOT` relates to the new key.
- New FR and AC for `REMOVE_MISSING_MINUTES`.
- `README.md`: the removal rules (lines 24, 27-30, 134) and the config table.
- `dynavlan.conf`: a commented entry at the default.
- `COMPATIBILITY.md`: the new key row.
- `dev/SKELETON.md`: the removal invariant. `dev/CODEMAP.md`: rows for new functions.

## 5. Code touch points

- `do_rescan` (`dynavlan:2285`): a missing-VLAN removal path beside the FR-41 path, before the combine at `dynavlan:2360`.
- `do_boot` (`dynavlan:2093`): update the missing-since state after pass 2.
- New pure helpers, unit-tested first: one that updates the state from a sample, and one that returns the VLANs due for removal.
- `load_config` and `CONFIG_KEYS`: the new key, its default and range check.
- `do_status` (`dynavlan:2769`) and `do_dryrun` (`dynavlan:2400`): the missing VLANs.

## 6. Resolved questions

All resolved 2026-10-15 by the operator.

- Q1: `RESET_ON_BOOT=false` does not turn off missing-VLAN removal (section 3.7).
- Q2: No active check before removal in this release. An ARP request to the VLAN's DHCP server could prove a VLAN is live, but it adds a dependency (`arping`) and a code path. Revisit if a false removal is reported.
- Q3: The release is 1.1.0, because it adds a config key.
