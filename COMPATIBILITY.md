# dynavlan compatibility contract

**Status: final text, in effect from the `1.0.0` tag.** This contract binds every release
from `1.0.0` on. It does not cover a build from before that tag. The policy is the one
approved in [`docs/v1.0-definition.md`](docs/v1.0-definition.md). This file is the
standalone promise that the README links to.

## What this promises

For the whole `1.x` line, dynavlan makes a **deprecate-with-warning** promise about its
external surface:

- You can upgrade within `1.x`.
- A breaking change never reaches you unless an earlier release warned about it.

This promise was chosen over strict semantic versioning. It lets the config surface change
during `1.x`. The cost is that each breaking change takes two releases (see
[The deprecate-with-warning process](#the-deprecate-with-warning-process)).

## Terms

- **Frozen surface:** one of the four surfaces in [Scope](#scope). The rules in this file
  govern them.
- **Breaking change:** a change in the list under [Breaking changes](#breaking-changes).
- **Confirmation window:** the time in which `netplan try` waits for dynavlan to confirm
  an applied change. If no confirmation arrives, netplan reverts the change.
- **Accepted:** a change is accepted when the post-apply health check passes and dynavlan
  confirms it inside the confirmation window. netplan then keeps the change.
- **Revert:** netplan restores the previous configuration after a change that was not
  accepted.

## Scope

### The four frozen surfaces

The rules in this file govern exactly these four surfaces:

1. **Config keys:** names, valid values, and defaults.
2. **The generated `/etc/netplan/90-dynavlan.yaml`:** its shape.
3. **CLI flags:** the modes and their meaning.
4. **Exit codes.**

### Integration identifiers

External tools bind to these names, so a rename would break them without any error. These
names are also frozen. A rename follows the same
[deprecate-with-warning process](#the-deprecate-with-warning-process) as a breaking change:

- the config path, `/etc/dynavlan.conf`
- the systemd unit names, `dynavlan.service` and `dynavlan-rescan.service`, and the timer
  name, `dynavlan.timer`
- the syslog identifier, `dynavlan` (`--status` tells operators to run
  `journalctl -t dynavlan`)

### Not covered

The promise does not cover these items:

- Internal code layout. dynavlan is a single file by design, and its apply and revert
  state machine is coupled on purpose. Internal refactors stay free after `1.0`.
- Log message text and log severities. Exit codes are the only outcome signal in this
  contract, so a change of log severity is free.
- The order of unrelated log lines.
- Structured journal fields.
- The state paths under `/run`.
- The backup directory.

## The rules

### Additions

An addition can ship in any `1.x` minor release, with no deprecation step. These are
additions:

- a new config key whose default keeps the current behavior
- a new CLI flag
- a new exit code (see [Exit codes](#4-exit-codes))
- a new log line

A new config key whose default changes behavior on an existing box is not an addition. It
changes a default, so it is a breaking change.

### Breaking changes

A breaking change is any of these:

- removing a config key, or giving it a different purpose
- removing a CLI flag
- changing a default in a way that changes behavior on an existing box
- changing the meaning of an exit code
- changing the generated YAML in a way that breaks the owned-set round-trip or an external
  consumer

**The owned-set round-trip.** dynavlan keeps its state in its own netplan file. It writes
the VLANs that it owns into that file, and on each run it reads them back from it. The
read gives two things: the `<iface>.<id>` names under `vlans:`, and in routed mode the
`route-metric` of each VLAN. A YAML change breaks the round-trip if a `1.x` release cannot
read back, unchanged, the owned set that an earlier `1.x` release wrote.

### The deprecate-with-warning process

A breaking change needs two releases:

1. A release that emits a **deprecation warning** when the old form is used. The old form
   still works and gives the same behavior. The warning names the replacement and links a
   migration note.
2. A **later** release that removes or changes the old form. It is at least the next minor
   release after step 1: never the same release, and never a patch release.

`2.0` is reserved for changes that the deprecate-with-warning process cannot handle.

## The frozen surfaces in detail

### 1. Config keys

dynavlan reads only the keys in this table (the `CONFIG_KEYS` allowlist). It refuses any
other key. The promise covers the name, the valid values, and the default of each key.

Value rules:

- A number is **canonical decimal** everywhere: `0`, or a non-zero digit followed by zero
  or more digits. dynavlan refuses a number with a leading zero (`05`, `018`). It does not
  convert it.
- A quoted value needs a matching closing quote. After the closing quote, only whitespace
  and an optional `#` comment can follow.

| Key | Default | Valid values |
|-----|---------|--------------|
| `DETECT_METHOD` | `both` | `both` \| `lldp` \| `sniff` |
| `VLAN_MIN` | `1` | canonical decimal int 1-4094 |
| `VLAN_MAX` | `1000` | int 1-4094, >= `VLAN_MIN` |
| `VLAN_IGNORE` | `""` | comma/space list of canonical ids/ranges within 1-4094 (no leading zeros, no empty elements) |
| `VLAN_WARN` | `32` | int >= 1 |
| `VLAN_LIMIT` | `64` | int; `0` = unlimited |
| `VLAN_LIMIT_MODE` | `refuse` | `refuse` \| `fill` |
| `SNIFF_SECONDS` | `60` | canonical decimal int >= 1 |
| `BOOT_SETTLE_SECONDS` | `20` | non-neg int (see the note below the table) |
| `CARRIER_WAIT_SECONDS` | `30` | non-neg int |
| `LEASE_SETTLE_SECONDS` | `30` | non-neg int |
| `RESCAN_MINUTES` | `5` | int >= 1 |
| `RESET_ON_BOOT` | `true` | `true` \| `false` |
| `REMOVE_ON_CARRIER_LOSS` | `true` | `true` \| `false` |
| `VLAN_ROUTES` | `false` | `true` \| `false` |
| `VLAN_ROUTE_METRIC_START` | `100` | int >= 1 |
| `RESTART_SNAPS` | `""` | space-separated snap names |
| `RESTART_SERVICES` | `""` | space-separated systemd units |
| `LOG_LEVEL` | `info` | `debug` \| `info` \| `notice` \| `warning` \| `err` |
| `BACKUP_KEEP` | `10` | int >= 1 |
| `RESTART_ON_NEW_SUBNET` | `true` | `true` \| `false` |

**`BOOT_SETTLE_SECONDS`.** dynavlan uses this value in two places:

- **Carrier-loss removal.** The interval between the two carrier samples derives from this
  value. When `REMOVE_ON_CARRIER_LOSS=true`, a value below 5 counts as 5 for this interval.
- **Boot re-detection.** The settle time before the second detection pass uses the value
  as set.

**Unknown keys.** The refusal of an unknown key is part of the contract. The frozen key
set is exactly the 21 keys in the table. A new key follows the rule in
[Additions](#additions).

**Config file permissions.** dynavlan refuses to run if `/etc/dynavlan.conf` is not owned
by root, or if its group or other users can write to it. This refusal is part of the
contract.

### 2. Generated `90-dynavlan.yaml` shape

The file path is `/etc/netplan/90-dynavlan.yaml`, with mode `600`. Each VLAN gets this
block:

```yaml
network:
  version: 2
  vlans:
    <iface>.<id>:
      id: <id>
      link: <iface>
      dhcp4: true
      accept-ra: false
      dhcp4-overrides:
        use-routes: false     # or `true` + `route-metric: <n>` when VLAN_ROUTES=true
        use-dns: false
        use-ntp: false
        use-domains: false
```

These invariants are frozen:

- **`<iface>.<id>` interface names.** The owned-set round-trip and external consumers
  depend on this naming scheme.
- **Isolation defaults:** `accept-ra: false`, and `use-dns`, `use-ntp` and `use-domains`
  set to `false`.
- **Exactly one comment line, at line 1.** The file always starts with one
  `# Managed by dynavlan ...` line. The `--reapply` comparison checks whether the
  generated file differs from the file on disk. It skips line 1 by position, not by
  content. A second header line, or no header line, breaks that comparison without any
  error. The count (one line) and the position (line 1) are frozen. The text of the line
  is not frozen: it is for information only, and it carries the version and build ID,
  which change in every release.
- **Empty owned set:** `network:` and `version: 2`, with no `vlans:` block.

### 3. CLI flags

Each run takes one mode. `-V` and `-h` are the only short aliases.

| Flag | Meaning |
|------|---------|
| `--boot` | full reconcile (add and remove) |
| `--rescan` | timer reconcile: add VLANs as they appear; remove the VLANs of a trunk whose carrier loss is confirmed |
| `--reapply` | operator re-apply of the current owned set |
| `--dry-run` | preview, no apply |
| `--status` | report of owned VLANs and VLANs detected now |
| `--reconfigure` | rewrite the systemd timer interval from the config |
| `--teardown` | attended removal of every owned VLAN: applies an empty VLAN set through the health-checked apply. Refuses unless `dynavlan.timer` and `dynavlan.service` are both disabled and inactive |
| `--version` / `-V` | print `dynavlan <ver> (build <id>)`; works before the config loads and without root |
| `-h` / `--help` | usage |

### 4. Exit codes

The set of exit codes is **`{0, 1, 2}`**, frozen as **open-ended**:

- A consumer must treat any unknown non-zero code as a failure.
- A consumer must not assume that `1` and `2` are the only failure codes.

Because the set is open-ended, a later release can add a new code as an addition.

| Code | Meaning |
|------|---------|
| `0` | Success, or a deliberate no-op. Exit 0 does not by itself prove routing health. Includes a requested `--help` or `-V`. |
| `1` | A refusal, a failure, or an interruption. The run may have done part of its work first. Exit 1 can follow a change that was not accepted, a change whose outcome is uncertain, or an interruption after the change was accepted. Exit 1 does not prove that a revert completed. |
| `2` | Usage error: no mode given, or an unknown mode. |

Exit 1 does not tell you the state of the box. A completed revert restores the
configuration, but not all kernel state. See [Documented limitations](#documented-limitations).

[`docs/exit-codes.md`](docs/exit-codes.md) lists the exits of each mode. It also explains
why a reverted apply exits `1`, not `0`.

## Supported platforms

This section is not part of the frozen surface. A `1.x` release can change it without the
deprecate-with-warning process. It is here so that the promise has a defined scope.

- **Validated:** Ubuntu 22.04 LTS (Server) with netplan 0.107.1 and the systemd-networkd
  renderer, on the reference box.
- **Expected to work, not tested:** any Linux system that has all of these:
  - networking managed by netplan 0.106 or later, with the systemd-networkd renderer
  - systemd
  - root
  - `tcpdump`, and `lldpd` for LLDP detection
- **Not supported:** netplan with the NetworkManager renderer (the usual Ubuntu Desktop
  setup), and systems that do not manage networking with netplan.

**netplan version check.** dynavlan checks the netplan version at start and refuses to run
below 0.106. netplan 1.0 and later reports its own version. On netplan 0.10x, dynavlan
reads the version from the package database (`dpkg-query`). On a netplan 0.10x system
without dpkg, dynavlan cannot check the version, so it refuses to run.

**Packages.** The `.deb` and the apt repository need a system with dpkg and apt.
`install.sh` installs dependencies only through apt.

## Documented limitations

These limitations are out of scope for 1.0. They are stated here so that they are not
silently absent. Details: [`docs/v1.0-definition.md`](docs/v1.0-definition.md).

- **IPv4 only.** IPv6 provisioning, and the IPv6 part of the post-apply health check, are
  planned after 1.0.
- **One validated vendor besides Meraki** (UniFi). There is no broad vendor matrix.
- **No per-VLAN MAC derivation.**
- **No automatic drift detection.** `--boot` and `--rescan` do not run the `--reapply`
  comparison. On a box whose VLAN set does not change, a change to the generated YAML
  reaches the box only when you run `--reapply`.
- **Validated on one reference box.** 1.0 is hardware-validated on one Protectli/igb
  appliance, with Meraki and UniFi switches. Validation at a second, independent site was
  waived for 1.0. It is planned as evidence after 1.0.
- **A completed revert restores the configuration, not all kernel state.** A revert can
  leave behind a VLAN link that only the reverted change created. The link keeps its DHCP
  address and connected route, and dynavlan treats its VLAN as managed elsewhere. The link
  stays until you remove it by hand or reboot. For recovery steps, see
  [After a stopped or reverted apply](docs/deployment-guide.md#after-a-stopped-or-reverted-apply)
  (deployment guide, section 5).
- **A stop after the change is accepted keeps the change.**
- **Exit 1 does not prove that a revert completed.** After an interrupted or failed run,
  the recovery can be uncertain.
- **Not every revert path is hardware-tested.** A stop during the confirmation window was
  tested on hardware (HV-01). A revert after a timeout, a revert after a failed health
  check, and a revert in routed mode were not tested on hardware.
- **`VLAN_LIMIT=0` (unlimited) has frozen meaning, but is not validated at scale.** A large
  owned set puts load on the fixed 30-second confirmation window (`TRY_TIMEOUT`). The
  window does not grow with the number of VLANs. It was not hardware-validated at high
  VLAN counts. A value of `0` turns off the count guard, and the operator takes this
  timing risk.

## Enforcement

The policy depends on documentation and review. Git hooks in `githooks/` add a check at
commit time. They protect the version and build identity of the script (FR-38). Install
them once per clone with `bash githooks/install.sh`.

- `pre-commit` refuses a staged `dynavlan` script unless it has exactly one valid `ver=`
  line and exactly one unindented `build="source"` line.
- `commit-msg` refuses a change to `dynavlan` that does not raise `ver=`. The exception is
  a commit message with exactly one `Version-Bump: none (<reason>)` trailer.
- `commit-msg` never allows a lower `ver=`, with or without the trailer.

The hooks catch accidental omissions. They do not prove that a change is
behavior-neutral: the trailer is a declaration that review must check. Review still
decides whether a change needed a version bump.
