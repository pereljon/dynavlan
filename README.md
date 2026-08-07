# dynavlan

A self-configuring VLAN provisioner for headless Linux appliances. Built for monitoring and discovery platforms, but a general dynamic-VLAN tool at its core. dynavlan detects the active tagged VLANs on every trunk a box is plugged into, brings each one up with DHCP (address only, fully route/DNS-isolated by default), and restarts the services you nominate so any agent that enumerates interfaces at startup picks up the new subnets. No SSH, no hand-edited YAML.

> **v0.4.11**, hardware-validated on a Protectli/igb appliance with Meraki and UniFi switches. Full matrix and supported-hardware list: [Hardware validation](docs/hardware-validation.md).

## The problem

A box on a trunk port with multiple tagged VLANs only sees the VLANs it has been configured for. On a headless box at a remote site, adding a VLAN means someone SSHing in and editing netplan by hand, per site, every time the switch config changes. Get the YAML wrong and the box loses its uplink with no way back.

dynavlan removes the human from that loop. It discovers the VLANs from the wire, configures them itself on every trunk the box carries, and every change is validated and auto-reverted if it would break the box's route to the world.

## How it works

1. **Discover** every trunk on the box and its live tagged VLANs from kernel state and the wire (LLDP plus passive sniff; neither interface names, VLAN IDs, the native VLAN, nor which NIC is "the trunk" are hardcoded or selected - a box with two live trunks gets both provisioned). Two trunks sharing the same VLAN id provision as two distinct interfaces, not a collision.
2. **Isolate**: by default each VLAN comes up DHCP address-only with routes, DNS, NTP, and search domains all declined, so a discovered subnet can never hijack the box's uplink or resolver. An opt-in routed mode (`VLAN_ROUTES=true`) instead accepts DHCP routes per VLAN at deterministic per-VLAN metrics (starting from `VLAN_ROUTE_METRIC_START`, always above the uplink's metric - dynavlan refuses up front if they would collide); DNS/NTP stay declined either way.
3. **Apply with a safety net**: dynavlan owns exactly one generated netplan file and touches nothing else. Every change across every trunk goes through a single `netplan try` against a pre-apply default-route snapshot and **auto-reverts on a routing-health failure** - the box is never stranded.
4. **Restart** the services you configure, so the interface-enumerating agent re-enumerates and starts watching the new VLANs.

It runs at boot as a full reconcile (`--boot`: adds *and* removes VLANs to match every trunk), then on a systemd timer as a rescan (`--rescan`, default every 5 min) that brings up VLANs as they appear. A trunk that's carrier-up but shows no tags is preserved either way (a sniff can miss a real, silent VLAN, so absence of evidence there isn't evidence of absence). A trunk whose physical link goes down, though, is pruned - not preserved - once that's confirmed across two samples and the box still has a healthy uplink: a dead port cannot carry any VLAN, so there is nothing to protect. This runs at both boot and on the rescan timer, gated by `REMOVE_ON_CARRIER_LOSS` (default `true`); a brief flap shorter than the confirmation window is preserved, and it never touches anything if the box's own uplink has no redundant route.

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

No dependency on NIC names, native VLAN, switch vendor, or the contents/filenames of any base netplan config. (One naming caveat: a NIC whose name plus the `.<vlan-id>` suffix would exceed the kernel's 15-char limit - e.g. a MAC-derived `enx001122334455` - has those VLANs skipped with a warning rather than provisioned into a name the kernel rejects; short standard names like `enp1s0`/`eth0` are unaffected.)

## Install

Before your first `dynavlan --boot`, read [Safety](#safety): a bad apply can strand a headless box, so run the first attended with an out-of-band console.

**Recommended: one-line install** (latest release; on an apt/dpkg system this
adds the dynavlan APT repository and installs via `apt`, so future releases
arrive with `sudo apt upgrade` - on any other system it falls back to a
tarball + `install.sh` install):

```sh
curl -fsSL https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh | sudo bash
```

Upgrades are manual and attended by design (`sudo apt upgrade`) - dynavlan
deliberately does not support unattended-upgrades; auto-deploying a
network-touching tool to remote headless boxes at once is the exact
recoverability footgun the project exists to avoid.

To add the apt repository by hand instead of via `get.sh` (e.g. to add it to
a box already running dynavlan from a `.deb`):

```sh
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL https://pereljon.github.io/dynavlan/dynavlan-archive-keyring.gpg \
  -o /etc/apt/keyrings/dynavlan.gpg
echo "Types: deb
URIs: https://pereljon.github.io/dynavlan
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/dynavlan.gpg" | sudo tee /etc/apt/sources.list.d/dynavlan.sources
sudo apt update && sudo apt install dynavlan
```

**Alternatives**, for cases the one-liner doesn't cover:

- **Pin a specific version** (bypasses apt, always a tarball install):
  ```sh
  curl -fsSL https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh | sudo bash -s -- v0.4.0
  ```
- **Don't want to pipe `curl` into `sudo bash`, or need to transfer a file to
  an offline/air-gapped box**: download the `.deb` from a
  [GitHub release](https://github.com/pereljon/dynavlan/releases) and install
  it directly:
  ```sh
  sudo dpkg -i dynavlan_0.4.0_all.deb
  sudo apt-get install -f   # if dependencies are missing
  ```
- **No apt/dpkg at all** (any other netplan/systemd-networkd distro): clone
  the repo and run the installer directly:
  ```sh
  sudo bash install.sh
  ```

Installs the script to `/usr/local/sbin/dynavlan`, the config template to `/etc/dynavlan.conf`, the systemd units, and a persistent-journald drop-in. It enables the boot service and rescan timer for the next boot but changes nothing on the network itself. Configure via `/etc/dynavlan.conf` (every key is documented at its default).

## Usage

```
dynavlan --boot         # reconcile at boot (add + remove VLANs to match every trunk)
dynavlan --rescan       # reconcile across every trunk: adds VLANs, prunes a debounced carrier-down trunk (what the timer runs)
dynavlan --reapply      # regenerate + apply the current VLAN set with this build's config,
                        #   only if it differs from what's on disk (use after an upgrade or a
                        #   config change like VLAN_ROUTES; no-ops if nothing changed)
dynavlan --dry-run      # show the diff without applying anything
dynavlan --status       # owned and detected VLANs per trunk (read-only, no apply;
                        #   exits non-zero if a detection tool is missing)
dynavlan --reconfigure  # rewrite the timer drop-in after changing RESCAN_MINUTES
dynavlan --version      # print version + build id (works unprivileged; safe with a broken config)
```

## Safety

dynavlan is built for boxes that may be remote, headless, or unattended, where a bad apply that breaks the uplink could be unrecoverable. Every design choice favors recoverability:

- Every apply is validated and health-checked against a pre-apply default-route snapshot; a routing failure auto-reverts via `netplan try`. Rollback is gated on the health check, never on an exit code.
- dynavlan owns one generated netplan file and never reads or writes any other config.
- Boot reconcile never reads "detected nothing" as "remove everything": a carrier-up trunk with no tags is preserved (detection is uncertain), while a carrier-down trunk is pruned only after a two-sample debounce and only if the box still has a healthy uplink route. Detection has no distinct failure signal, so zero detection blocks additions, but the carrier signal (independent of detection) still governs pruning.

A bad apply can drop an SSH session, so if possible, run the first `--boot` with an out-of-band fallback (serial console, IPMI, or physical access). If that is not available, `--dry-run` previews the change without applying it, and exits non-zero if the candidate config fails validation, so it doubles as a scripted pre-flight check.

## Report your setup

dynavlan makes no vendor assumptions: it reads live 802.1Q tags off the wire (primary) and LLDP where a switch advertises the VLAN table (supplement). Detection is validated on Meraki and UniFi edge switches; the core switch and upstream firewall/router do not affect detection (LLDP is single-hop, so only the directly-attached edge switch matters, and 802.1Q tagging is a standard).

If dynavlan works on your gear, a short report helps confirm the range of switches it covers. Please [open an issue](https://github.com/pereljon/dynavlan/issues) with:

- **Edge switch** (the one the box plugs into): vendor and model.
- **Detection**: did LLDP advertise the tagged VLANs, or did sniff carry it? (`dynavlan --status` shows what was detected; set `LOG_LEVEL=debug` to see per-method results.)
- **Scale**: number of VLANs detected, and `SNIFF_SECONDS` if you changed it.
- **Environment**: `dynavlan --version`, `netplan --version`, and the NIC driver (`ethtool -i <iface>`).

No MACs, hostnames, or subnets are needed. A "didn't work" report is just as useful as a success.

## Documentation

| File | Purpose |
|------|---------|
| `docs/dynavlan-PRD.md` | Product requirements (authoritative behavior) |
| `dev/features/dynavlan.md` | Technical design: architecture, apply/rollback state machine, systemd/install layout |
| `dev/SKELETON.md` | How it works: logic flow, key invariants, hardware-validated behaviors |
| `dev/CODEMAP.md` | Where things live: per-function map for navigating the script |
| `dev/features/dynavlan-tests.md` | Test plan: unit asserts, `--dry-run`, hardware integration checklist |
| `dynavlan.conf` | Config reference (every key documented at its default) |
| `docs/deployment-guide.md` | Deployment guide: install, configure, first attended run, operation, removal |

## License

MIT - see [LICENSE](LICENSE).
