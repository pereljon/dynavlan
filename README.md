# dynavlan

A self-configuring VLAN provisioner for headless Linux appliances: designed for monitoring/discovery platforms (which is why isolation is its default), but a general dynamic-VLAN tool at its core. dynavlan detects the active tagged VLANs on every trunk a box is plugged into, brings each one up with DHCP (address only, fully route/DNS-isolated by default), and restarts the services you nominate so any agent that enumerates interfaces at startup picks up the new subnets. No SSH, no hand-edited YAML.

> **v0.3.0**, hardware-validated (Protectli/igb, dual trunks, Meraki + UniFi switches, 2026-07-30).

## The problem

A box on a trunk port with multiple tagged VLANs only sees the VLANs it has been configured for. On a headless box at a remote site, adding a VLAN means someone SSHing in and editing netplan by hand, per site, every time the switch config changes. Get the YAML wrong and the box loses its uplink with no way back.

dynavlan removes the human from that loop. It discovers the VLANs from the wire, configures them itself on every trunk the box carries, and every change is validated and auto-reverted if it would break the box's route to the world.

## How it works

1. **Discover** every trunk on the box and its live tagged VLANs from kernel state and the wire (LLDP plus passive sniff; neither interface names, VLAN IDs, the native VLAN, nor which NIC is "the trunk" are hardcoded or selected - a box with two live trunks gets both provisioned). Two trunks sharing the same VLAN id provision as two distinct interfaces, not a collision.
2. **Isolate**: by default each VLAN comes up DHCP address-only with routes, DNS, NTP, and search domains all declined, so a discovered subnet can never hijack the box's uplink or resolver. An opt-in routed mode (`VLAN_ROUTES=true`) instead accepts DHCP routes per VLAN at deterministic per-VLAN metrics (starting from `VLAN_ROUTE_METRIC_START`, always above the uplink's metric - dynavlan refuses up front if they would collide); DNS/NTP stay declined either way.
3. **Apply with a safety net**: dynavlan owns exactly one generated netplan file and touches nothing else. Every change across every trunk goes through a single `netplan try` against a pre-apply default-route snapshot and **auto-reverts on a routing-health failure** - the box is never stranded.
4. **Restart** the services you configure, so the interface-enumerating agent re-enumerates and starts watching the new VLANs.

It runs at boot and on a timer (systemd), reconciling as VLANs appear and disappear on any trunk.

## Isolated by default

By default every discovered VLAN comes up **address-only**: DHCP assigns an IP so the subnet is present and reachable on its own interface, but the VLAN installs **no default route, no DNS, no NTP, no search domains**, and IPv6 Router Advertisements are declined. This is deliberate, and it is the *opposite* of netplan's own `dhcp4: true` default (which accepts routes) - so if "enable a VLAN" makes you expect a fully routable interface, this is the surprising part, on purpose.

dynavlan grew out of monitoring/discovery use: it provisions VLANs so an agent can *see* each subnet, not so the box *routes through* it. Isolation keeps the box's uplink and resolver clean, and it is what the auto-revert safety net depends on - a VLAN that installs no default route cannot hijack the uplink, so the health check can treat "the default route moved" as a failure.

Routed mode is a first-class, opt-in alternative (`VLAN_ROUTES=true`) that accepts each VLAN's DHCP default route at deterministic per-VLAN metrics above the uplink's, with DNS/NTP/domains still declined. Setup, `--reapply`, and the metric mechanics live in [Making the VLAN interfaces routable](docs/deployment-guide.md#making-the-vlan-interfaces-routable-opt-in) in the deployment guide.

## Service-restart integration

Most monitoring and discovery agents (network scanners, SNMP pollers, asset-discovery daemons) read the interface list once at startup and do not notice interfaces added later. After a successful VLAN change, dynavlan restarts the targets you list so the agent re-reads its interfaces and begins monitoring the new subnets. Two config keys, both optional:

- `RESTART_SNAPS` - space-separated snap names (`snap restart`)
- `RESTART_SERVICES` - space-separated systemd units (`systemctl restart`)

A restart that fails is logged and non-fatal; the VLAN change still stands. This is the seam that makes dynavlan useful to a specific agent without knowing anything about it. The reference deployment restarts the Domotz agent snap, but the same hook drives any interface-enumerating tool (LibreNMS, Zabbix, netdisco, a custom collector).

dynavlan also restarts those targets when a new IPv4 subnet simply *appears* on any interface - an access port plugged in after boot, or the agent starting before the base interface finishes DHCP - not only on a tagged-VLAN change. Controlled by `RESTART_ON_NEW_SUBNET` (default `true`).

## Requirements

- Ubuntu (or any distro) using **netplan with the systemd-networkd renderer**
- **netplan >= 0.106** (validated baseline; refuses to run below it, and capability-probes `netplan try` - no silent fallback to an un-revertable `netplan apply`). netplan only grew a `--version` flag in 1.0, so on the 0.10x line the version is read from the package database (`dpkg-query`); a netplan 0.10x box with no dpkg cannot be version-checked and is refused.
- root
- `tcpdump` when sniff detection is enabled (default), `lldpd`/`lldpctl` for LLDP detection

No dependency on NIC names, native VLAN, switch vendor, or the contents/filenames of any base netplan config.

## Install

Before your first `dynavlan --boot`, read [Safety](#safety): a bad apply can strand a headless box, so run the first attended with an out-of-band console.

One-line install (latest release):

```sh
curl -fsSL https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh | sudo bash
```

Or a specific version:

```sh
curl -fsSL https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh | sudo bash -s -- v0.3.0
```

From a `.deb` (attached to each [GitHub release](https://github.com/pereljon/dynavlan/releases)):

```sh
sudo dpkg -i dynavlan_0.3.0_all.deb
sudo apt-get install -f   # if dependencies are missing
```

From a local clone:

```sh
sudo bash install.sh
```

Installs the script to `/usr/local/sbin/dynavlan`, the config template to `/etc/dynavlan.conf`, the systemd units, and a persistent-journald drop-in. It enables the boot service and rescan timer for the next boot but changes nothing on the network itself. Configure via `/etc/dynavlan.conf` (every key is documented at its default).

## Usage

```
dynavlan --boot         # reconcile at boot (add + remove VLANs to match every trunk)
dynavlan --rescan       # add-only reconcile across every trunk (what the timer runs)
dynavlan --reapply      # regenerate + apply the current VLAN set with this build's config,
                        #   only if it differs from what's on disk (use after an upgrade or a
                        #   config change like VLAN_ROUTES; no-ops if nothing changed)
dynavlan --dry-run      # show the diff without applying anything
dynavlan --status       # current managed VLANs and their leases
dynavlan --reconfigure  # rewrite the timer drop-in after changing RESCAN_MINUTES
dynavlan --version      # print version + build id (works unprivileged; safe with a broken config)
```

## Safety

dynavlan is built for boxes that may be remote, headless, or unattended, where a bad apply that breaks the uplink could be unrecoverable. Every design choice favors recoverability:

- Every apply is validated and health-checked against a pre-apply default-route snapshot; a routing failure auto-reverts via `netplan try`. Rollback is gated on the health check, never on an exit code.
- dynavlan owns one generated netplan file and never reads or writes any other config.
- Boot reconcile aborts and changes nothing if it detects no carrier, no tags, or zero VLANs (it never reads "detected nothing" as "remove everything").

A bad apply can drop an SSH session, so if possible, run the first `--boot` with an out-of-band fallback (serial console, IPMI, or physical access). If that is not available, `--dry-run` previews the change without applying it.

## Documentation

| File | Purpose |
|------|---------|
| `docs/dynavlan-PRD.md` | Product requirements (authoritative behavior) |
| `dev/features/dynavlan.md` | Technical design: architecture, apply/rollback state machine, systemd/install layout |
| `dev/features/dynavlan-tests.md` | Test plan: unit asserts, `--dry-run`, hardware integration checklist |
| `dynavlan.conf` | Config reference (every key documented at its default) |
| `docs/deployment-guide.md` | Deployment guide: install, configure, first attended run, operation, removal |

## License

MIT - see [LICENSE](LICENSE).
