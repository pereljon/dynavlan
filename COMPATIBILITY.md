# dynavlan compatibility contract

**Status: DRAFT.** This contract takes effect when `1.0.0` is tagged. Until then the
surface below is still free to change. The policy is the approved one from
[`docs/v1.0-definition.md`](docs/v1.0-definition.md) (Gate 4); this file is where it
graduates into the standalone, README-linked promise.

## What this promises

For the whole `1.x` line, dynavlan makes a **deprecate-with-warning** promise about its
external surface: you can upgrade within `1.x` and a breaking change will never reach you
without a prior release that warned about it. Chosen over strict semver so the config
surface can still evolve during `1.x`, at the cost of a two-step process for any break.

## Scope: the four frozen surfaces

The deprecate-with-warning rules below govern exactly these four evolving surfaces:

1. **Config keys** (names, accepted values, defaults)
2. **The generated `/etc/netplan/90-dynavlan.yaml` shape**
3. **CLI flags** (modes and their meaning)
4. **Exit codes**

**Also frozen (integration identifiers).** These are names an external consumer binds to,
so a rename would break silently: the config path `/etc/dynavlan.conf`, the systemd unit
and timer names (`dynavlan.service`, `dynavlan-rescan.service`, `dynavlan.timer`), and the
`dynavlan` syslog identifier (`--status` tells operators to run `journalctl -t dynavlan`).

**Not covered:** internal code layout, log message text **and severities** (exit codes are
the only contractual outcome signal, so a severity change like 0.4.12's is free), the order
of unrelated log lines, structured journal fields, `/run` state paths, and the backup
directory. dynavlan is single-file by design and its apply/rollback state machine is
deliberately coupled; internal refactors stay free even after `1.0`.

## The rules

- **Additions are always free in a minor.** A new config key that defaults to current
  behavior, a new CLI flag, a new exit code (see below), or a new log line may land in any
  `1.x` minor with no deprecation cycle.
- **Breaking changes ship in two steps, never one.** A breaking change is: removing or
  repurposing a config key, removing a CLI flag, changing a default in a way that alters
  behavior on an existing box, changing an exit code's meaning, or changing the generated
  YAML in a way that breaks the owned-set round-trip or an external consumer. Such a change
  requires:
  1. A release that emits a **deprecation warning** on the old form. The old form still
     works and produces the same behavior. The warning names the replacement.
  2. A **later** release (never the same one) that removes or changes it.
- **`2.0` is reserved** for changes that cannot be done via the two-step path.

## Frozen surface

### 1. Config keys

The parser honors only these keys (the `CONFIG_KEYS` allowlist); any other key is refused.
The promise covers each key's **name, accepted values, and default**.

| Key | Default | Accepted values |
|-----|---------|-----------------|
| `DETECT_METHOD` | `both` | `both` \| `lldp` \| `sniff` |
| `VLAN_MIN` | `1` | int 1-4094 |
| `VLAN_MAX` | `1000` | int 1-4094, >= `VLAN_MIN` |
| `VLAN_IGNORE` | `""` | comma/space list of ids/ranges within 1-4094 |
| `VLAN_WARN` | `32` | int >= 1 |
| `VLAN_LIMIT` | `64` | int; `0` = unlimited |
| `VLAN_LIMIT_MODE` | `refuse` | `refuse` \| `fill` |
| `SNIFF_SECONDS` | `60` | int >= 1 |
| `BOOT_SETTLE_SECONDS` | `20` | non-neg int (the FR-41 carrier-sample interval derives from it and is floored at 5 when `REMOVE_ON_CARRIER_LOSS=true`; the sniff-comparison settle uses the raw value) |
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

The "unknown key is refused" behavior is itself part of the contract: the frozen set is
exactly these keys, and a 22nd is a free minor addition. `dynavlan` also refuses to run if
`/etc/dynavlan.conf` is not root-owned or is group/other-writable; that refusal is
contractual, not an incidental check.

### 2. Generated `90-dynavlan.yaml` shape

File path `/etc/netplan/90-dynavlan.yaml`, mode `600`. Per-VLAN block:

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

Frozen invariants:

- **`<iface>.<id>` interface naming.** The owned-set round-trip and any external consumer
  key off this scheme.
- **Isolation defaults** (`accept-ra: false`, `use-dns`/`use-ntp`/`use-domains: false`).
- **Exactly one comment line, at line 1.** The file always begins with a single
  `# Managed by dynavlan ...` line. The drift comparison strips exactly line 1 positionally
  (FR-39); a second header line, or none, silently breaks it. The line's *text* is
  informational (it carries `ver`+`build`, which change every release) and is not frozen;
  its count (1) and position (line 1) are.
- Empty owned set: `network:` / `version: 2` with no `vlans:` block.

### 3. CLI flags

One mode per invocation. `-V` is the only short alias.

| Flag | Meaning |
|------|---------|
| `--boot` | full reconcile (add + remove) |
| `--rescan` | timer reconcile (add as VLANs appear; prune a confirmed carrier-down trunk) |
| `--reapply` | operator re-apply of the current owned set |
| `--dry-run` | preview, no apply |
| `--status` | owned vs detected-now report |
| `--reconfigure` | rewrite the systemd timer interval from config |
| `--version` / `-V` | print `dynavlan <ver> (build <id>)`; works pre-config and non-root |
| `-h` / `--help` | usage |

### 4. Exit codes

The vocabulary is **`{0, 1, 2}`**, frozen as **open-ended**: a consumer must treat any
unknown non-zero as failure, never assume `{1,2}` exhaustive. This is what lets a new code
be added later as a free minor addition.

| Code | Meaning |
|------|---------|
| `0` | success, or a deliberate no-op that left the box unchanged and healthy |
| `1` | refused or failed before changing anything, OR an apply that was safely reverted |
| `2` | usage text was printed: help requested (`-h`/`--help`), or a bad/missing mode |

Full per-mode inventory, dispositions, and the rationale for keeping a reverted apply at
`1` (not `0`): [`docs/exit-codes.md`](docs/exit-codes.md).

> **Open pre-freeze decision:** an explicitly requested `--help` currently exits `2`
> alongside genuine usage errors. If a requested help should instead exit `0`, that is a
> free change now but an exit-code-meaning break after `1.0`. Decide before the freeze.

## Documented limitations (out of scope for 1.0)

Stated plainly, not silently absent (detail in
[`docs/v1.0-definition.md`](docs/v1.0-definition.md)):

- **IPv4 only.** IPv6 provisioning and the FR-14a IPv6 health-check arm are post-1.0.
- **One validated non-Meraki vendor** (UniFi), not a broad matrix.
- **No per-VLAN MAC derivation** (the reserved key was removed, not frozen).
- **No automatic config-drift detection** on boot/rescan.
- **`VLAN_LIMIT=0` (unlimited) is frozen semantics but unvalidated at scale.** A large
  owned set stresses the fixed `TRY_TIMEOUT` (30s) apply window, which is not scaled by
  VLAN count and not hardware-validated at high counts. `0` opts out of the guard; the
  operator assumes that timing risk.

## Enforcement

The policy is documentation plus review discipline. It will be reinforced by the FR-38
version/build identity contract's version-gate git hooks once Gate 4 lands them (they are
designed but not yet built): a change that alters behavior cannot silently skip the `ver=`
bump that signals it, so a compatibility-relevant change stays visible in the version
history. Until those hooks exist, the `ver=` bump is enforced by review discipline alone.
