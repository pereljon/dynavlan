# Design: restart monitoring agent on a newly-appeared IPv4 subnet (FR-40)

Date: 2026-07-30
Status: approved, ready for planning
Version impact: minor bump (new behavior + new config key)

## Problem

dynavlan restarts the nominated snaps/services (e.g. Domotz) only when it adds or
removes a **tagged VLAN**. Two real situations are therefore missed:

1. **A non-dynavlan interface comes up after the agent launched.** An access port,
   or a trunk carrying only a native/untagged VLAN, is plugged in after boot. It
   gets a DHCP lease and a real subnet, but dynavlan detects no *tagged* VLAN on it
   (native/access ports yield an empty tag set), so nothing changes and the agent is
   never restarted. The agent, which enumerates interfaces/subnets only at launch,
   never sees the new subnet.
2. **The agent starts before DHCP is ready at boot.** The monitoring snap can start
   before `systemd-networkd` finishes leasing the base/untagged interface, so at
   launch the interface has no usable IPv4 address and the agent enumerates nothing.
   dynavlan's boot run is deliberately **not** ordered after `network-online.target`
   (FR-29), so the base lease may not be present when dynavlan runs either.

The unifying observation: the agent cares about **IPv4 subnets it can scan**, not
about link state or VLAN tags. The trigger for a restart should be "a new IPv4
subnet became available," from any source, including dynavlan's own VLANs.

## Non-goals

- Not watching carrier/link state. Carrier without an address gives the agent
  nothing to enumerate (see Decision 1).
- Not managing base/native/access interface addressing. That stays networkd's job;
  dynavlan only observes the resulting addresses.
- Not blocking boot on DHCP. FR-29 stands: a no-uplink box must still boot. Late
  base leases are caught by the next rescan (see Limitation).
- Not restarting on subnet **loss**. The growth-check fires only on new subnets;
  a disappearing subnet gives the agent nothing to do.

## Decisions

### Decision 1: trigger on gained global-IPv4 subnet, not carrier

Restart when an interface has a global-scope IPv4 **subnet** on this run that was
not present before. Carrier-up fires too early: link comes up in well under a
second, but the DHCP lease (DISCOVER/OFFER/REQUEST/ACK, plus STP settling) can take
several seconds. Restarting on carrier relaunches the agent against an
address-less interface, so it enumerates nothing and the subnet is still missed.
Gained-IPv4 fires exactly when there is a subnet to scan. It also unifies with the
existing VLAN path, which already waits for a lease before restarting.

### Decision 2: token is `interface:subnet`, keyed on the subnet, not the host address

The watched set is one token per interface + subnet, e.g. `enp3s0:10.0.5.0/24`,
`enp1s0.100:192.168.100.0/24`.

- **Interface is part of the key**: the same subnet can appear on two interfaces
  (multi-homing), and those are distinct enumeration targets; the agent enumerates
  per-interface anyway.
- **Keyed on the subnet (network address + prefix), NOT the box's own host
  address**: a DHCP renewal or re-lease within the same pool (`10.0.5.55` →
  `10.0.5.56`) yields the same token and does not restart. Only a genuinely
  different subnet does. This is what neutralises lease-timeout churn.

### Decision 3: monotonic "seen this boot" set, flap-safe

The stored set is the **union of every subnet seen since boot**, not just the last
sample. Restart fires when `current − seen` is non-empty, then `seen` grows to
include `current`. Consequences:

- A link that flaps down and back up does not re-trigger (its subnet is already in
  `seen`).
- A reboot wipes `seen`, which is correct: the agent relaunches and re-enumerates
  everything, so the baseline must reset to empty.

### Decision 4: unified rule, no boot special-case ("empty seen at boot")

Every run (boot and rescan) applies the same rule:

```
seen    = read /run/dynavlan/seen      # absent on first run of an uptime -> empty
current = current global-IPv4 subnet tokens
new     = current - seen               # set_minus
if new is non-empty and not already_restarted_this_run:
    restart_targets
    already_restarted_this_run = true
write seen = seen ∪ current             # set_union
```

On boot the file is absent, so `seen` is empty and `new = current`: if any real
subnet is present, the agent is restarted once after the network has settled,
regardless of whether it started before or after DHCP. This is the fix for problem
2, and it falls out of the rule with no boot-specific code.

### Decision 5: `apply_change` is untouched; growth-check is an additive, deduped second trigger

`apply_change` is the safety-critical accept/rollback chain, and its
restart-after-VLAN-apply is load-bearing at boot (the agent snap can start before
dynavlan finishes provisioning VLANs). It is left exactly as-is: VLAN changes still
`wait_leases` → `restart_targets` on ACCEPT, in every mode.

The growth-check runs as a new post-step at the end of `do_boot` and `do_rescan`,
**after** `apply_change` returns, so freshly-provisioned VLAN subnets are already in
`current` and get folded into `seen` (no redundant restart next run). A per-run
`already_restarted_this_run` flag, set whenever `restart_targets` is called
(including from `apply_change`), dedups: **at most one restart per run**.

### Decision 6: state lives in `/run/dynavlan/seen`, not in the netplan YAML

- **Correct lifetime**: `/run` is tmpfs, wiped on reboot, which is exactly the
  seen-set's required semantics. The netplan YAML persists across reboots; storing
  `seen` there would leave it populated after reboot and break the boot restart.
- **Keeps the safety-critical file untouched**: the owned YAML is written only by
  `backend_generate_config` inside generate → validate → `netplan try` →
  accept/rollback. Storing `seen` there would force either regenerating/validating
  the file every rescan (churn on the safety path, fights FR-39) or an out-of-band
  in-place edit (a partial write can strand a headless box).
- **Blast radius**: a corrupt/missing `seen` costs at most one spurious restart
  (empty → restart). A botched YAML edit can strand the box.
- **Flash wear**: `seen` updates as often as every rescan; `/run` is RAM.
- **Precedent**: dynavlan already keeps runtime state in `/run` (`/run/dynavlan.lock`).
  This is the same category, distinct from the "no sidecar config/state files"
  invariant, which is about persistent state.

### Decision 7: config key `RESTART_ON_NEW_SUBNET`, default on

A new validated boolean in `dynavlan.conf`. Reuses the existing `RESTART_SNAPS` /
`RESTART_SERVICES` target lists; no new target config. It is a no-op when those
lists are empty. Default **on**: the box exists to have its monitoring agent see the
network, and "on" is what activates the boot-race fix. Existing installs gain the
boot restart and subnet-appearance restarts.

## Edge cases

| Situation | Behaviour |
|-----------|-----------|
| Access/native port plugged in after boot, gets a lease | Next rescan: new `iface:subnet` token → restart once |
| DHCP renewal, same address | No token change → no restart |
| Re-lease, different host address, same subnet | Same subnet token → no restart |
| Re-lease onto a different subnet (renumber) | New token → restart; old token lingers harmlessly in `seen` |
| Lease expires, no replacement | Subnet leaves `current`; growth-check never fires on loss → no restart |
| Link flap, same subnet returns | Already in `seen` → no restart |
| No DHCP, no IPv4 at all on boot | No token; ignored. Lease later → restart (boot if in time, else next rescan) |
| Self-assigned `169.254.x.x` only | Excluded by global-scope filter → no token; does not poison `seen` |
| Static-IP base interface | Token present at boot snapshot → covered by the boot restart |
| Agent starts before DHCP at boot | Empty `seen` at boot → restart after settle (Decision 4) |
| Slow base lease lands after dynavlan's boot run | Caught at first rescan (~2 min) as growth; may be a second restart around boot |

## Limitation

Because dynavlan will not block on `network-online` (FR-29), a base lease that lands
after dynavlan's boot run is not seen at boot. It is caught at the first rescan
(~2 min after boot; timer then every 5 min). Worst case for a slow base lease is one
rescan tick of latency, and a box that boots then leases slowly may do a boot
restart plus a ~2-min rescan restart. Accepted: a monitoring-agent restart is cheap,
and the alternative (waiting on base DHCP) violates FR-29 and can hang a no-uplink
boot.

## Implementation shape

New pure helper (TDD, RED first):

- `ipv4_network ADDR PREFIX` → network address, e.g. `ipv4_network 10.0.5.55 24`
  → `10.0.5.0`. The only real logic; reduces an address to its subnet so a renewal
  within a pool produces an identical token. Unit-tested across octet-aligned and
  non-octet prefixes (`/24`, `/25`, `/16`, `/8`, `/32`).

Reused (already present and tested): `set_minus` for `current − seen`, `set_union`
for the monotonic grow, `emit_set` for canonical ordering.

New impure glue (exercised on hardware, not unit-tested):

- `current_subnets` — sample `ip -4 -o addr show scope global`, drop loopback and
  link-local, map each address to `iface:$(ipv4_network …)`, emit as a sorted set.
- `read_seen` / `write_seen` — read/write `/run/dynavlan/seen` (mkdir `/run/dynavlan`
  if absent; absent file = empty set).
- `maybe_restart_on_new_subnet` — the Decision 4 rule; honors the per-run
  `already_restarted_this_run` dedup flag; gated by `RESTART_ON_NEW_SUBNET`.

Wiring: call `maybe_restart_on_new_subnet` at the end of `do_boot` and `do_rescan`,
after `apply_change`. `restart_targets` sets the dedup flag so a VLAN-driven restart
suppresses a second one.

## Testing

- **Unit** (`tests/unit.sh`, new section): `ipv4_network` cases above.
- **`--dry-run` / `--status`**: *report* the would-restart delta ("new subnets since
  seen: […]") for operator visibility; never restart, never write `/run` (both stay
  side-effect-free).
- **Hardware**: (a) plug an access port in after boot → next rescan restarts the
  agent once; (b) same-subnet lease renewal → no restart; (c) agent starting before
  DHCP at boot → agent restarted after settle.

## Docs / invariants / version

- **`SKELETON.md` invariant amended**: "State lives in the owned YAML" scoped to
  *persistent configuration* state; the seen-set is *ephemeral runtime scratch* in
  `/run`, wiped on reboot, never configuration.
- **PRD**: new **FR-40** with the subnet-not-address, monotonic-seen, and
  empty-seen-at-boot semantics as acceptance criteria.
- **Change-checklist fan-out**: `dynavlan.conf` template, `README.md`, PRD,
  `dev/features/dynavlan.md`, `dev/features/dynavlan-tests.md`, `dev/CODEMAP.md`,
  `dev/SKELETON.md`, `CHANGELOG.md`.
- **Version**: minor bump (`ver=`), per FR-38.
