# dynavlan

Self-configuring VLAN discovery for headless Linux appliances. dynavlan detects the active tagged VLANs on whatever trunk a box is plugged into, brings each one up with DHCP (address only, fully route/DNS-isolated), and restarts the services you nominate so any agent that enumerates interfaces at startup picks up the new subnets. No SSH, no hand-edited YAML.

> **Status: pre-release (v0.1.0), initial testing.** Code-complete and reviewed; not yet exercised end-to-end on hardware. Do not run it on a box you cannot reach at the console. See [Safety](#safety) below.

## The problem

A network-monitoring or discovery appliance on a trunk port only sees the VLANs it has been configured for. On a headless box at a remote site, adding a VLAN means someone SSHing in and editing netplan by hand, per site, every time the switch config changes. Get the YAML wrong and the box loses its uplink with no way back.

dynavlan removes the human from that loop. It discovers the VLANs from the wire, configures them itself, and every change is validated and auto-reverted if it would break the box's route to the world.

## How it works

1. **Discover** the trunk and its live tagged VLANs from kernel state and the wire (LLDP plus passive sniff; neither interface names, VLAN IDs, nor the native VLAN are hardcoded).
2. **Isolate**: each VLAN comes up DHCP address-only with routes, DNS, NTP, and search domains all declined, so a monitored subnet can never hijack the box's uplink or resolver.
3. **Apply with a safety net**: dynavlan owns exactly one generated netplan file and touches nothing else. Every apply goes through `netplan try` against a pre-apply default-route snapshot and **auto-reverts on a routing-health failure** - the box is never stranded.
4. **Restart** the services you configure, so the monitoring/discovery agent re-enumerates and starts watching the new VLANs.

It runs at boot and on a timer (systemd), reconciling as VLANs appear and disappear on the trunk.

## Service-restart integration

Most monitoring and discovery agents (network scanners, SNMP pollers, asset-discovery daemons) read the interface list once at startup and do not notice interfaces added later. After a successful VLAN change, dynavlan restarts the targets you list so the agent re-reads its interfaces and begins monitoring the new subnets. Two config keys, both optional:

- `RESTART_SNAPS` - space-separated snap names (`snap restart`)
- `RESTART_SERVICES` - space-separated systemd units (`systemctl restart`)

A restart that fails is logged and non-fatal; the VLAN change still stands. This is the seam that makes dynavlan useful to a specific agent without knowing anything about it. The reference deployment restarts the Domotz agent snap, but the same hook drives any interface-enumerating tool (LibreNMS, Zabbix, netdisco, a custom collector).

## Requirements

- Ubuntu (or any distro) using **netplan with the systemd-networkd renderer**
- **netplan >= 0.106** (validated baseline; refuses to run below it, and capability-probes `netplan try` - no silent fallback to an un-revertable `netplan apply`)
- root
- `tcpdump` when sniff detection is enabled (default), `lldpd`/`lldpctl` for LLDP detection

No dependency on NIC names, native VLAN, switch vendor, or the contents/filenames of any base netplan config.

## Install

```sh
sudo ./install.sh
```

Installs the script to `/usr/local/sbin/dynavlan`, the config template to `/etc/dynavlan.conf`, the systemd units, and a persistent-journald drop-in. It enables the boot service and rescan timer for the next boot but changes nothing on the network itself. Configure via `/etc/dynavlan.conf` (every key is documented at its default).

## Usage

```
dynavlan --boot         # reconcile at boot (add + remove VLANs to match the trunk)
dynavlan --rescan       # add-only reconcile (what the timer runs)
dynavlan --dry-run      # show the diff without applying anything
dynavlan --status       # current managed VLANs and their leases
dynavlan --reconfigure  # rewrite the timer drop-in after changing RESCAN_MINUTES
```

## Safety

dynavlan targets appliances at client sites with no remote console, where a bad apply that breaks the uplink is unrecoverable. Every design choice favors recoverability:

- Every apply is validated and health-checked against a pre-apply default-route snapshot; a routing failure auto-reverts via `netplan try`. Rollback is gated on the health check, never on an exit code.
- dynavlan owns one generated netplan file and never reads or writes any other config.
- Boot reconcile aborts and changes nothing if it detects no carrier, no tags, or zero VLANs (it never reads "detected nothing" as "remove everything").

Exercise it on the real hardware with console access before trusting it unattended. A bad apply can drop an SSH session, so the first `--boot` must be at the console.

## Documentation

| File | Purpose |
|------|---------|
| `docs/dynavlan-PRD.md` | Product requirements (authoritative behavior) |
| `dev/features/dynavlan.md` | Technical design: architecture, apply/rollback state machine, systemd/install layout |
| `dev/features/dynavlan-tests.md` | Test plan: unit asserts, `--dry-run`, hardware integration checklist |
| `dynavlan.conf` | Config reference (every key documented at its default) |
| `docs/deployment-guide.md` | The manual Domotz-on-Ubuntu appliance runbook dynavlan builds on |

The repo also holds the base Domotz-on-Ubuntu deployment runbook (`docs/deployment-guide.md`) that dynavlan was first built for; dynavlan itself is hardware- and vendor-agnostic.
