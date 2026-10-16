# dynavlan

dynavlan finds the tagged VLANs on each trunk port of a headless Linux box and configures them for you. Each VLAN gets a DHCP address. By default, it gets no routes and no DNS. After a change, dynavlan restarts the services that you name, so your monitoring agent sees the new subnets. You do not need SSH or hand-edited YAML.

dynavlan was built for monitoring and discovery platforms, but it is a general tool for dynamic VLANs.

> **1.1.1.** Validated on one reference Protectli/igb appliance with Meraki and UniFi switches. Compatibility promise for 1.x: [COMPATIBILITY.md](COMPATIBILITY.md). Full matrix: [Hardware validation](docs/hardware-validation.md).

## The problem

A box on a trunk port sees only the VLANs that it is configured for. To add a VLAN to a headless box at a remote site, someone must connect with SSH and edit the netplan YAML by hand. They must do this at each site, each time the switch configuration changes. If the YAML is wrong, the box can lose its uplink, and nobody can reach it again.

dynavlan does this work for you. It reads the VLANs from the wire and configures them on each trunk. Before it keeps a change, it checks the box's route to the network. If the change breaks that route, dynavlan reverts it automatically.

## How it works

1. **Discover.** dynavlan finds each trunk on the box and the tagged VLANs that are live on it. It uses two methods: LLDP and a passive sniff of 802.1Q tags. Nothing is hardcoded: not interface names, VLAN IDs, the native VLAN, or which NIC is the trunk. A box with two live trunks gets VLANs on both. If both trunks carry the same VLAN ID, dynavlan creates two separate interfaces.
2. **Isolate.** By default, each VLAN gets an address only, with no routes and no DNS. A discovered subnet cannot take over the box's uplink or resolver. See [Isolated by default](#isolated-by-default).
3. **Apply with a safety net.** dynavlan writes exactly one netplan file and changes no other netplan file. It applies all changes for all trunks in one `netplan try`. Before the apply, it records the box's default route. If the default route is not healthy after the apply, netplan reverts the change, so the box stays reachable.
4. **Restart.** dynavlan restarts the services that you configure. Your agent then reads the interface list again and starts to monitor the new VLANs.

dynavlan runs at two times:

- **At boot** (`--boot`): a full reconcile. It adds VLANs that appear and removes VLANs that are gone, on every trunk.
- **On a timer** (`--rescan`, every 5 minutes by default): it adds VLANs as they appear. It removes the VLANs of a trunk that lost link, and it removes a VLAN that a trunk with link has stopped carrying.

Three rules control removal:

- **A trunk that has link but does not show a VLAN:** a sniff can miss a VLAN that is silent, so one missed sample does not remove it. dynavlan records when the first trusted sample missed the VLAN, and a rescan removes the VLAN once every sample has missed it for `REMOVE_MISSING_MINUTES`. The default is 15 minutes, or twice `RESCAN_MINUTES` if that is larger. This applies when the trunk shows no tags at all and when it shows other tags but not this one. A sighting resets the clock. A failed capture does not count as a miss. The clock counts time since boot, so it restarts at reboot. `--boot` only starts the clock; the next rescan removes the VLAN, and only when the box has a working default route. Set `REMOVE_MISSING_MINUTES=0` to turn the rule off.
- **A trunk that loses link:** dynavlan removes its VLANs. A trunk with no link cannot carry a VLAN. dynavlan removes them only when two samples confirm the link loss and the box still has a working default route. A short flap between the two samples does not remove anything. `REMOVE_ON_CARRIER_LOSS` (default `true`) controls this rule, on both runs.

## Isolated by default

By default, each VLAN gets a DHCP address and nothing else. It does not install a default route, DNS servers, NTP servers, or search domains. It also ignores IPv6 Router Advertisements. The subnet is present and reachable on its own interface.

This default is the opposite of netplan's own `dhcp4: true`, which accepts routes. If you expect "enable a VLAN" to give a fully routed interface, this behavior will surprise you. It is intentional.

dynavlan provisions VLANs so that an agent can *see* each subnet, not so that the box can *route through* it. Isolation keeps the box's uplink and resolver clean. The safety net also depends on it: a VLAN cannot install a default route, so any change to the default route after an apply is a failure.

**Routed mode** is an opt-in alternative (`VLAN_ROUTES=true`). Each VLAN accepts its DHCP default route, at a fixed metric per VLAN. The metrics start at `VLAN_ROUTE_METRIC_START` and are always above the uplink's metric. dynavlan refuses to run if they would collide. DNS, NTP and search domains stay declined. For setup, `--reapply`, and how metrics are assigned, see [Making the VLAN interfaces routable](docs/deployment-guide.md#making-the-vlan-interfaces-routable-opt-in) in the deployment guide.

## Service-restart integration

Most monitoring and discovery agents read the interface list once, at startup. Examples are network scanners, SNMP pollers, and asset-discovery daemons. They do not see interfaces that are added later. After a successful VLAN change, dynavlan restarts the targets that you list. The agent then reads its interfaces again and monitors the new subnets.

Two config keys set the targets. Both are optional:

- `RESTART_SNAPS`: snap names, separated by spaces (`snap restart`)
- `RESTART_SERVICES`: systemd units, separated by spaces (`systemctl restart`)

If a restart fails, dynavlan logs it and continues. The VLAN change stays. With these keys, dynavlan can work with any agent and needs no knowledge of it. The reference deployment restarts the Domotz agent snap. The same keys work for any tool that reads interfaces at startup, for example LibreNMS, Zabbix, netdisco, or a custom collector.

dynavlan also restarts the targets when a new IPv4 subnet appears on any interface, not only after a VLAN change. Two examples: an access port is plugged in after boot, or the agent starts before the base interface gets its DHCP address. `RESTART_ON_NEW_SUBNET` (default `true`) controls this.

## Requirements

- **netplan with the systemd-networkd renderer.** Validated on Ubuntu 22.04 LTS Server. Other distributions that use netplan and systemd-networkd are expected to work, but are not tested. The NetworkManager renderer, which Ubuntu Desktop usually uses, is not supported. Details: [COMPATIBILITY.md](COMPATIBILITY.md#supported-platforms).
- **netplan 0.106 or later.** This is the validated baseline. dynavlan refuses to run on an older netplan. It also checks that `netplan try` works, and it never falls back to `netplan apply`, which cannot revert. Netplan has a `--version` flag only from 1.0. On netplan 0.10x, dynavlan reads the version from the package database (`dpkg-query`). It refuses to run on a netplan 0.10x box without dpkg.
- **root.**
- **`tcpdump`** for sniff detection (on by default), and **`lldpd`/`lldpctl`** for LLDP detection.

dynavlan does not depend on NIC names, the native VLAN, the switch vendor, or the names or contents of your base netplan files.

One naming limit applies. The kernel limits an interface name to 15 characters. A VLAN interface name is the NIC name plus `.<vlan-id>`. If that name is too long, dynavlan skips the VLAN and logs a warning. This can happen with a name based on a MAC address, such as `enx001122334455`. Short standard names such as `enp1s0` and `eth0` are not affected.

## Install

Read [Safety](#safety) before your first `dynavlan --boot`. A bad apply can disconnect a headless box.

**Recommended: one-line install of the latest release.**

```sh
curl -fsSL https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh | sudo bash
```

On a system with apt and dpkg, this adds the dynavlan APT repository and installs with `apt`. You then get new releases with `sudo apt upgrade`. On other systems, it installs from the release tarball with `install.sh`.

Upgrades are manual and attended, by design. dynavlan does not support unattended-upgrades. An automatic upgrade of a network tool on many remote headless boxes at once is the risk that this project exists to prevent.

To add the APT repository by hand instead of with `get.sh` (for example, on a box that already runs dynavlan from a `.deb`):

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

**Other ways to install:**

- **Install a specific version.** This always installs from the tarball and does not use apt:
  ```sh
  curl -fsSL https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh | sudo bash -s -- v1.1.1
  ```
- **Install from a `.deb` file.** Use this if you do not want to pipe `curl` into `sudo bash`, or if the box is offline. Download the `.deb` from a [GitHub release](https://github.com/pereljon/dynavlan/releases), then install it:
  ```sh
  sudo dpkg -i dynavlan_1.1.1_all.deb
  sudo apt-get install -f   # if dependencies are missing
  ```
- **Install without apt or dpkg** (other netplan/systemd-networkd distributions). Clone the repository and run the installer:
  ```sh
  sudo bash install.sh
  ```

**What gets installed.** The package and `install.sh` both install:

- the script, to `/usr/local/sbin/dynavlan`
- the config file, to `/etc/dynavlan.conf`
- the systemd units: the package puts them in `/lib/systemd/system`, and `install.sh` puts them in `/etc/systemd/system`
- a drop-in that makes the journal persistent

**What install and upgrade do.**

- A first install enables the boot service and the rescan timer for the next boot. It starts neither of them, and it changes nothing on the network.
- An upgrade keeps each unit enabled or disabled, as you left it. It restarts the timer only if the timer was running. It does not restore the running state of the boot service.

To configure dynavlan, edit `/etc/dynavlan.conf`. Each key is documented there, at its default value.

**Removal** has two steps:

1. Remove the network state that dynavlan owns, with an attended `dynavlan --teardown`.
2. Remove the software (`apt remove` or `apt purge`, or the steps for a source install).

If you only remove the software, the units stop, but the VLANs and `/etc/netplan/90-dynavlan.yaml` stay. See Removal in `docs/deployment-guide.md`.

## Usage

```
dynavlan --boot         # full reconcile at boot: add and remove VLANs to match every trunk
dynavlan --rescan       # what the timer runs: add new VLANs, and remove the VLANs of a
                        #   trunk that has lost link (confirmed by two samples) or that has been
                        #   missing from a trunk with link for REMOVE_MISSING_MINUTES
dynavlan --reapply      # regenerate and apply the current VLAN set with this build and config,
                        #   only if the result differs from the file on disk. Use it after an
                        #   upgrade or after a config change such as VLAN_ROUTES.
dynavlan --dry-run      # show the planned changes; apply nothing
dynavlan --status       # show owned and detected VLANs, one row per trunk; apply nothing.
                        #   Exits non-zero if a detection tool is missing or a detector failed.
dynavlan --reconfigure  # rewrite the timer drop-in after you change RESCAN_MINUTES
dynavlan --teardown     # remove every VLAN that dynavlan owns, through a health-checked
                        #   netplan try. Attended, from a console. --dry-run does not preview it.
dynavlan --version      # print the version and build ID (no root needed; works with a broken config)
```

`--dry-run` and `--status` both run detection. Detection sets the physical NICs administratively up and turns on promiscuous mode. dynavlan does not change them back.

For `--teardown`, see Removal in `docs/deployment-guide.md`. Run it from a console, not over SSH. A management VLAN that is not the default route can carry your SSH session, and the default-route check cannot see that.

## Safety

dynavlan is built for boxes that can be remote, headless, or unattended. On such a box, a bad apply that breaks the uplink can be impossible to fix without a site visit. Each design decision puts recovery first:

- **Each apply is checked.** dynavlan validates each change, then applies it with `netplan try`. After the apply, it compares the default route with the route that it recorded before. If the route is not healthy, netplan reverts the change. The route check decides the rollback, not an exit code.
- **One file only.** dynavlan writes one netplan file and no other netplan file. `--reconfigure` also writes the systemd timer drop-in. dynavlan does not depend on your base netplan files. It reads them only to find conflicts, during validation, the overlap check, and `--dry-run`.
- **"Detected nothing" never means "remove everything."** Removal rules are in [How it works](#how-it-works). If a detector fails, dynavlan does not remove VLANs based on that sample.

A bad apply can disconnect your SSH session. For the first `--boot`, have a console that does not depend on the network, if you can: a serial console, IPMI, or physical access. If you do not have one, run `--dry-run` first. It shows the change without applying it. It exits non-zero if the new configuration fails validation, so you can also use it as a scripted pre-flight check.

## Limitations

- IPv4 only. IPv6 provisioning is planned after 1.0.
- Validated on one reference box, with two switch vendors. Validation at a second, independent site is planned after 1.0.
- A reverted change can leave a VLAN link behind. If the change created the link, the link can stay with its DHCP address and route after the revert. It stays until you remove it by hand or reboot. See the deployment guide, section 5.
- If dynavlan is stopped after a change is accepted, the change stays. A run that is interrupted or that fails does not prove that a revert completed.
- The full list is in [COMPATIBILITY.md](COMPATIBILITY.md).

## Report your setup

dynavlan makes no assumptions about the switch vendor. It reads live 802.1Q tags from the wire, which is the main method. It also reads LLDP, when a switch advertises its VLAN table. Detection is validated on Meraki and UniFi edge switches. Only the edge switch that the box connects to matters. LLDP reaches one hop only, and 802.1Q tagging is a standard, so the core switch and the upstream firewall or router do not affect detection.

If dynavlan works on your hardware, a short report helps to show which switches it supports. Please [open an issue](https://github.com/pereljon/dynavlan/issues) with:

- **Edge switch** (the switch that the box connects to): vendor and model.
- **Detection**: did LLDP advertise the tagged VLANs, or did the sniff find them?
- **Scale**: the number of VLANs detected, and `SNIFF_SECONDS` if you changed it.
- **Environment**: the output of `dynavlan --version`, `netplan --version`, and `ethtool -i <iface>` (the NIC driver).

To see what was detected, run `dynavlan --status`. Each run also logs one line per trunk, `trunk <iface>: N tags detected [ids]`. That line combines all enabled methods. dynavlan does not log the result of each method separately, and `LOG_LEVEL=debug` adds no detail. To compare the methods, run `dynavlan --dry-run` two times: one time with `DETECT_METHOD=lldp`, and one time with `DETECT_METHOD=sniff`.

Do not send MACs, hostnames, or subnets. A report that says "it did not work" is as useful as a success.

## Documentation

| File | Purpose |
|------|---------|
| `docs/dynavlan-PRD.md` | Product requirements (the authority on behavior) |
| `dev/features/dynavlan.md` | Technical design: architecture, apply/rollback state machine, systemd and install layout |
| `dev/SKELETON.md` | How it works: logic flow, key invariants, hardware-validated behaviors |
| `dev/CODEMAP.md` | Where things are: a map of each function in the script |
| `dev/features/dynavlan-tests.md` | Test plan: unit tests, `--dry-run`, hardware integration checklist |
| `dynavlan.conf` | Config reference (each key documented at its default) |
| `docs/deployment-guide.md` | Deployment guide: install, configure, first attended run, operation, removal |
| `COMPATIBILITY.md` | The 1.x compatibility contract, effective from the 1.0.0 tag: config keys, generated YAML, CLI flags, exit codes |
| `docs/exit-codes.md` | Exit codes for each mode, and the frozen table |
| `docs/hardware-validation.md` | Validated hardware and the record of console-backed validation |

## License

MIT. See [LICENSE](LICENSE).
