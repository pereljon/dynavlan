# SKELETON - how it works

Owns: the logic flow and key invariants of the codebase, as prose or pseudocode. Does NOT hold per-function purposes (dev/CODEMAP.md).
Maintain: update when control flow, call sequences, or invariants change.

## Logic Flow

Provisioning sequence for a new Protectli box (see `docs/deployment-guide.md` for exact commands):

1. Install Ubuntu Server (minimal, LVM auto-partition, create an admin account, set a hostname, SSH key pulled from a provisioning GitHub account, no SSH password auth, no extra services).
2. SSH in with the tech RSA key.
3. Update OS (remove `needrestart` first so `dist-upgrade` doesn't hang on service-restart prompts, then upgrade, then autoremove).
4. Install and enable UFW, allowing SSH.
5. Install the Domotz agent snap and connect its required plugs; enable the `tun` kernel module (needed for Domotz's VPN-based remote access); open UFW port 3000.
6. Install iPerf3; open UFW port 5210.
7. Install supporting CLI tools (ping, net-tools, nano, lldpd, screen).
8. Write the netplan VLAN config, lock down its file permissions, apply it.

## Key Invariants

- SSH is key-only from first boot; password auth is disabled during OS install, not as a later hardening step.
- `needrestart` is removed before any upgrade to avoid interactive prompts during unattended dist-upgrade.
- UFW is enabled before the Domotz/iPerf3 ports are opened, and only the specific ports each service needs are opened (3000 for Domotz, 5210 for iPerf3), on top of SSH.
- Netplan config trunks all VLANs off a single physical uplink (`enp1s0`); `enp2s0` is a separate untagged interface, not part of the VLAN trunk.
- `enp1s0` untagged = the switch port's native VLAN. `enp1s0`'s own DHCP lease is the native-VLAN address; additional tagged VLANs (example set: 1, 11, 19, 20, 21, 22, 23) ride the same port.
