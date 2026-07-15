# Implementation Spec

Owns: architecture, configuration reference, design decisions, and deprecation policy. The authoritative "why it is built this way" document.
Maintain: update when architecture, settings, or behavior changes.

## Architecture

Domotz monitoring agents run on Protectli boxes imaged with Ubuntu Server. Each box is provisioned by hand per `docs/deployment-guide.md`: minimal Ubuntu Server install, LVM auto-partition, hardened SSH (key-only, from a provisioning GitHub account), UFW firewall, Domotz agent via snap, iPerf3 for throughput testing, and a static netplan config trunking multiple VLANs off a single physical interface (`enp1s0`).

## Config Reference

- User: a dedicated admin account, password in your password manager, SSH key-only auth (no password login).
- Hostname: per-site.
- SSH key source: your provisioning GitHub account (`https://github.com/<your-tech-account>.keys`).
- Firewall (UFW): allow SSH, allow 3000 (Domotz agent), allow 5210 (iPerf3).
- Domotz snap: `domotzpro-agent-publicstore`, with plugs connected: firewall-control, network-observe, raw-usb, shutdown, system-observe. Requires `tun` kernel module loaded and persisted in `/etc/modules`.
- Packages installed: `ufw`, `iperf3`, `apt-utils`, `iputils-ping`, `net-tools`, `nano`, `lldpd`, `screen`. `needrestart` is explicitly removed.
- Netplan (`/etc/netplan/01-netcfg.yaml`): two physical ethernet interfaces (`enp1s0`, `enp2s0`) plus 7 VLAN interfaces (IDs 1, 11, 19, 20, 21, 22, 23) all trunked on `enp1s0`, each with DHCP and an increasing route-metric (10/20/100/200/300/400/500/600/700) so the lowest-numbered/most-specific route wins. File permissions locked down with `chmod go-r` after editing (netplan configs can contain secrets in other setups; here it's mostly precautionary). Full content in `docs/deployment-guide.md`.
- The base deployment uses an untagged native VLAN on `enp1s0` (whatever the switch port's native VLAN is), so `enp1s0`'s own untagged DHCP request (no `vlanN` interface, just `enp1s0` itself) is what lands the monitor on the native VLAN. Additional VLANs (an example set: 1, 11, 19, 20, 21, 22, 23) are then trunked as explicitly tagged VLANs on top of that same physical port via the `vlanN` netdev entries.

## Design Decisions

## Deprecation Policy
