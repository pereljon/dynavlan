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

The promise covers exactly these, and nothing else:

1. **Config keys** (names, accepted values, defaults)
2. **The generated `/etc/netplan/90-dynavlan.yaml` shape**
3. **CLI flags** (modes and their meaning)
4. **Exit codes**

**Not covered:** internal code layout, log message wording, the order of unrelated log
lines, journal tags, and anything the docs explicitly mark as a limitation. dynavlan is
single-file by design and its apply/rollback state machine is deliberately coupled;
internal refactors stay free even after `1.0`.

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
| `VLAN_IGNORE` | `""` | comma/space list of ids/ranges |
| `VLAN_WARN` | `32` | int >= 1 |
| `VLAN_LIMIT` | `64` | int; `0` = unlimited |
| `VLAN_LIMIT_MODE` | `refuse` | `refuse` \| `fill` |
| `SNIFF_SECONDS` | `60` | int >= 1 |
| `BOOT_SETTLE_SECONDS` | `20` | non-neg int (also the FR-41 carrier debounce; clamped up to 5 when `REMOVE_ON_CARRIER_LOSS=true`) |
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
exactly these keys, and a 22nd is a free minor addition.

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
| `--rescan` | timer reconcile (add as VLANs appear) |
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
| `2` | usage error (bad or missing mode) |

Full per-mode inventory, dispositions, and the rationale for keeping a reverted apply at
`1` (not `0`): [`docs/exit-codes.md`](docs/exit-codes.md).

## Documented limitations (out of scope for 1.0)

Stated plainly, not silently absent (detail in
[`docs/v1.0-definition.md`](docs/v1.0-definition.md)):

- **IPv4 only.** IPv6 provisioning and the FR-14a IPv6 health-check arm are post-1.0.
- **One validated non-Meraki vendor** (UniFi), not a broad matrix.
- **No per-VLAN MAC derivation** (the reserved key was removed, not frozen).
- **No automatic config-drift detection** on boot/rescan.

## Enforcement

The policy is documentation plus review discipline. What makes it enforceable is the FR-38
version/build identity contract and its version-gate git hooks (Gate 4): a change that
alters behavior cannot silently skip the `ver=` bump that signals it, so a
compatibility-relevant change is always visible in the version history.
