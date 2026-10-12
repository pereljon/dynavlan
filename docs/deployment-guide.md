# dynavlan Deployment Guide

How to deploy dynavlan on a netplan/systemd-networkd Ubuntu box. This covers installation, configuration, the first (attended) run, and ongoing operation. What dynavlan is and how it works: `README.md`, `docs/dynavlan-PRD.md`.

> A bad apply can drop an SSH session, so if possible, run the first `--boot` with an out-of-band fallback (serial console, IPMI, or physical access). If that is not available, `--dry-run` previews the change without applying it (it does run detection, which brings physical NICs administratively up and leaves promiscuous mode on).

## 1. Prerequisites

- Ubuntu (or compatible) using **netplan with the systemd-networkd renderer**; netplan >= 0.106 (dynavlan checks and refuses below it). The check reads `netplan --version` where it exists (netplan >= 1.0) and otherwise falls back to `dpkg-query -W netplan.io`, which is how the Ubuntu 22.04 line (netplan 0.10x) reports itself.
- Root access.
- The box's trunk-facing NIC(s) patched to switch ports carrying tagged VLANs. dynavlan provisions every carrier-up trunk it finds, not one selected NIC - a box with two trunks gets both. No switch-side configuration is required beyond the trunk(s) themselves.
- `tcpdump` (sniff detection, default) and `lldpd` (LLDP detection). `install.sh` installs both if missing.
- Base uplink connectivity already working (dynavlan never touches base netplan files; it only adds its own).

## 2. Install

**Recommended: one-line install** (latest release, requires `curl`). On an
apt/dpkg system this adds the dynavlan APT repository and installs via
`apt`; on any other system it falls back to a tarball + `install.sh` install:

```
curl -fsSL https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh | sudo bash
```

**Via apt, by hand** (what the one-liner does automatically on an apt/dpkg
system; use this to add the repo to a box already running dynavlan from a
`.deb`, without re-running `get.sh`):

```
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

Upgrades are **manual and attended only** - run `sudo apt update && sudo apt
upgrade` yourself when you want the latest release; dynavlan is not
structured for unattended-upgrades. A conffile prompt can appear if both the
shipped `/etc/dynavlan.conf` default changed and you edited yours - this can
hang a headless upgrade, so don't run `apt upgrade` unattended on a remote
box. A box already installed via a `.deb` needs no reinstall: adding the keyring
+ source is enough, since dpkg knows the package. A box installed with
`install.sh` is not in dpkg's database, so apt does not recognize it; `apt install
dynavlan` migrates it instead (the package records the unit posture first, takes
over the units, and removes the old copies `install.sh` left in
`/etc/systemd/system` that would shadow the package's).

An upgrade preserves the timer/service state you left them in, for both the
package and `install.sh`: each of `dynavlan.service` and `dynavlan.timer` keeps
its own enabled/disabled state, and only a timer that was running is restarted. A
unit you `systemctl disable`d is not re-enabled, and a timer that was enabled but
stopped is not started. Only a first-ever install enables both units by default
(and never starts them). The same holds when the package is first installed over
a manual `install.sh` deployment: its posture is captured before anything is
replaced.

Before replacing the script, the upgrade stops the timer, verifies it is inactive,
and waits (up to 300 s) for any in-flight run to finish; if the timer cannot be
stopped and verified, or a run still holds the lock, the upgrade stops without
replacing anything and puts the timer back. If configuration fails after the files
are unpacked, dpkg leaves the package half-configured (this is not a rollback): a
previously running timer is restarted, the recorded state is kept, and
`sudo dpkg --configure dynavlan` retries from it. Two cases cannot restore an
exact running state, and both say so in the upgrade output: an upgrade from a package
older than 0.4.1 (which never recorded it) estimates the timer was running if it is
enabled; and if a recording package left no usable record, the timer's prior run
state is reported as unknown and the timer is left as found, not restarted.) A manual `dynavlan`
run started between the lock wait and the file replacement is not prevented.

**Alternatives**, for cases apt doesn't cover:

- **Pin a specific version** (bypasses apt, always a tarball install):
  ```
  curl -fsSL https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh | sudo bash -s -- v0.4.0
  ```
- **No apt/dpkg at all** (any other netplan/systemd-networkd distro), or you
  want full manual control over what's transferred: clone, SCP, or ZIP the
  repo and run the installer directly:
  ```
  scp dynavlan dynavlan.conf dynavlan.service dynavlan-rescan.service dynavlan.timer install.sh <user>@<box>:
  ssh <user>@<box>
  sudo bash install.sh
  ```

`sudo bash install.sh` rather than `sudo ./install.sh` on purpose: transfers that do not carry Unix modes (a GitHub ZIP download, `rsync` without `-p`, anything routed through a filesystem with no permission bits) strip the executable bit, and `./install.sh` then fails with "Permission denied". Invoking the interpreter sidesteps it. The mode of `dynavlan` itself does not matter, since the installer places it with `install -m 0755`.

`install.sh`:

- installs the script to `/usr/local/sbin/dynavlan` and the config template to `/etc/dynavlan.conf` (never clobbers an existing config)
- installs the three systemd units and a persistent-journald drop-in (so run history survives reboots)
- ensures `tcpdump` and `lldpd` are present
- enables `dynavlan.service` (boot reconcile) and `dynavlan.timer` (periodic rescan) **for the next boot**

Install changes nothing on the network. The first apply happens only when you run `--boot` yourself or on the next reboot.

## 3. Configure

Every key in `/etc/dynavlan.conf` is shipped commented at its built-in default; uncomment to override. Invalid values refuse to run (logged at `err`) - dynavlan never silently substitutes a default for a value you set wrong.

The keys most deployments touch:

```
# VLAN_MIN=1 / VLAN_MAX=1000       # discovery range (VLAN 1 included; skip IDs via VLAN_IGNORE)
# VLAN_IGNORE=""                   # VLANs never ADDED, e.g. "5,20-25" (does not remove ones already owned)
# RESTART_SNAPS="..."              # snaps to restart after a VLAN change
# RESTART_SERVICES=""              # systemd services to restart after a VLAN change
# RESTART_ON_NEW_SUBNET=true       # also restart targets when a new IPv4 subnet appears, not only on a VLAN change
# RESCAN_MINUTES=5                 # timer interval (run --reconfigure after changing)
# REMOVE_ON_CARRIER_LOSS=true      # prune a trunk's VLANs once its link stays down (see "Steady state")
# VLAN_ROUTES=false                # opt-in: accept DHCP routes per VLAN at per-VLAN metrics
```

Set `RESTART_SNAPS`/`RESTART_SERVICES` to whatever agent should re-enumerate interfaces after a VLAN change; with `RESTART_ON_NEW_SUBNET` (default on) dynavlan also restarts them when a new IPv4 subnet appears on any interface, e.g. an access port plugged in after boot or the agent starting before base-interface DHCP completes (see README "Service-restart integration"). Leave `VLAN_ROUTES` off unless you specifically want the box routing via discovered VLANs; the default is full route/DNS isolation.

**Number and quote rules (0.4.18).** Numbers are whole decimal numbers with no leading zero (`5`, not `05`); `VLAN_IGNORE` may not contain an empty element (`"1,"`, `",1"`, `"1,,3"`); a quoted value needs a matching closing quote followed only by an optional `#` comment. A config that breaks these is refused at load with the key named; correct the value, there is no automatic migration.

**`VLAN_IGNORE` and the range only stop NEW VLANs.** A VLAN dynavlan already owns is kept even if you later add it to `VLAN_IGNORE` or narrow `VLAN_MIN`/`VLAN_MAX` past it; `dynavlan --status` lists those as `owned-ignored` / `owned-out-of-range`. To remove one deliberately: remove it from the switch trunk, run `sudo dynavlan --dry-run`, then run an attended two-pass `sudo dynavlan --boot` reconcile with console access. Changes to what dynavlan generates (for example `VLAN_ROUTES`) reach already-owned VLANs only through an attended `sudo dynavlan --reapply`; changing `VLAN_ROUTE_METRIC_START` affects only future metric assignments (including already-owned VLANs that lack a persisted metric during an isolated-to-routed `--reapply`) and never renumbers an existing persisted assignment.

### What "isolated by default" means

By default each discovered VLAN comes up DHCP **address-only**: it gets an IP (so the subnet is present and reachable on its own interface) but installs **no default route, no DNS, no NTP, no search domains**, and declines IPv6 Router Advertisements. This is intentional and it overrides netplan's own `dhcp4: true` behaviour (which would accept routes). The box's single uplink stays the only default route, and its resolver stays clean. It is also what makes the auto-revert safe: because a dynavlan VLAN installs no default route, "the default route moved" is an unambiguous failure the health check can revert on.

### Making the VLAN interfaces routable (opt-in)

If this box should actually route via the discovered VLANs, enable routed mode:

```
VLAN_ROUTES=true                  # accept each VLAN's DHCP default route
VLAN_ROUTE_METRIC_START=100       # first metric; MUST stay above the uplink's metric.
                                  # New metrics are assigned in lexical full-token (iface.id) order, one shared ascending
                                  # sequence across every trunk on the box; existing VLANs never renumber.
```

Then push the change to the VLANs already on the box:

```
sudo dynavlan --reapply
```

`--reapply` regenerates the owned VLAN set with the current settings and applies it through the same `netplan try` + health-check path, but only if the generated config actually differs from what is on disk (so it is a safe no-op if nothing changed). Preview first with `sudo dynavlan --dry-run`, which prints the assigned id:metric map and flags any conflict.

Each VLAN then accepts its DHCP default route at a distinct metric (100, 101, 102, ... in lexical full `iface.id` token order within the assignment batch of VLANs that lack a persisted metric, so `enp1s0.10` precedes `enp1s0.2`; one shared sequence across every trunk on the box), so the table is deterministic and the lowest-metric route - normally the untagged uplink at its own metric - still wins. If any assigned metric would match or beat the uplink's, dynavlan **refuses before touching disk** and names the remedy (raise `VLAN_ROUTE_METRIC_START`); applying it would guarantee a revert loop. DNS/NTP/domains and IPv6 RA stay declined even here - routed mode changes routes only.

To go back to isolation: set `VLAN_ROUTES=false` and `sudo dynavlan --reapply` again.

Caveat: routed mode makes the interfaces routable, but the box still has one active default path at a time (lowest metric). It does not test or use each VLAN's gateway independently; that (per-VLAN reachability testing) is not something dynavlan does today.

## 4. First run (attended, at the console)

0. **Confirm what you just installed** - after every deploy, before drawing any conclusion from behavior:

   ```
   dynavlan --version
   ```

   Prints `dynavlan <version> (build <commit>)`. A `-dirty` suffix means the source tree had uncommitted changes and the build matches NO commit; `unknown` means it was installed from something other than a git checkout. Worth ten seconds: a deploy that lands mid-edit is indistinguishable from a failed fix unless you can name the running build. The same identity appears on every `run start:` line in the journal, so it is also recoverable after the fact.

1. **Preview** - detection plus the intended diff, with no configuration, apply, deletion, or restart changes (detection still brings NICs up and leaves promiscuous mode on):

   ```
   sudo dynavlan --dry-run
   ```

   Sanity-check the detected VLAN list against what the trunk actually carries (e.g. a manual `tcpdump -i <iface> -e -nn vlan`). Confirm `validate: OK`.

2. **First apply** - at the console, watching the journal in a second terminal:

   ```
   sudo journalctl -t dynavlan -f     # terminal 2
   sudo dynavlan --boot               # terminal 1 (console)
   ```

   Every apply goes through `netplan try` with a health check against the pre-apply default route; on failure it auto-reverts and the box keeps its uplink.

3. **Verify**:

   ```
   sudo dynavlan --status
   ip addr        # each discovered VLAN has a lease
   ip route       # default route unchanged (isolation mode: no routes on VLANs)
   ```

4. The rescan timer arms on the next reboot, or start it now:

   ```
   sudo systemctl start dynavlan.timer
   ```

5. **Confirm the timer will actually fire.** A systemd timer can sit `active` and `Result=success` forever without ever elapsing, and nothing logs an error when it does:

   ```
   systemctl list-timers dynavlan.timer
   ```

   `NEXT` and `LEFT` must show a real time. `n/a` in every column means the timer has no scheduled elapse and periodic rescans will never run; re-run `sudo dynavlan --reconfigure` and restart the timer. Confirm properly by waiting past `RESCAN_MINUTES` and checking a rescan appears in `journalctl -t dynavlan`.

## 5. Ongoing operation

**After every upgrade, run `sudo dynavlan --reapply`.** dynavlan rewrites its netplan file only when the VLAN *set* changes, so a new build that generates a different config (an isolation key, a security fix) would otherwise never reach a box whose VLANs are stable - the fix would be installed and inert. `--reapply` regenerates the owned set with the running build and applies it through the usual `netplan try` + health-check path, or does nothing at all if the config already matches. It never adds or removes a VLAN, and never runs detection.


| Task | Command |
|------|---------|
| Check which build is installed | `dynavlan --version` (no root needed) |
| Apply a new build's config to existing VLANs | `sudo dynavlan --reapply` (run after every upgrade) |
| See owned vs detected VLANs | `sudo dynavlan --status` |
| Preview what a reconcile would do | `sudo dynavlan --dry-run` |
| Force a rescan now | `sudo systemctl start dynavlan-rescan.service` |
| Full reconcile (adds + removals) | `sudo dynavlan --boot` (or reboot) |
| Change the rescan interval | edit `RESCAN_MINUTES`, then `sudo dynavlan --reconfigure` |
| Run history | `journalctl -t dynavlan` |

Steady state is hands-off: boot reconciles the VLAN set against every trunk the box carries (two-pass per trunk, with guards against removing anything on faulty detection); the timer adds newly appearing VLANs on any trunk between boots.

Removals depend on *why* a VLAN went away:

- **Individually absent from a still-live trunk** (the switch stopped trunking it, but the port is up): removed at the next boot reconcile, never by the timer.
- **The whole trunk went carrier-down** (unplugged, switch port disabled, cable pulled): the trunk's entire owned set is pruned, at boot *or* on the timer, once the link has stayed down across a two-sample debounce and the box still has a healthy default route. Governed by `REMOVE_ON_CARRIER_LOSS` (default `true`); set it to `false` for the pre-v0.4.0 behavior of keeping those VLANs indefinitely. A brief flap does not trigger it, and neither does a box with no working uplink of its own - if the dead trunk was the only route out, everything is preserved.
- **Carrier is up but nothing is detected** (a quiet or slow-to-converge trunk): preserved. Detection uncertainty never removes anything.

### After a stopped or reverted apply

A stop or revert during `netplan try` restores the configuration, but a VLAN link that only the reverted change created can stay in the kernel with its DHCP address and connected route. While it exists, dynavlan treats that VLAN as managed elsewhere and does not add it. To recover, from a console:

1. Check the configuration first: `/etc/netplan/90-dynavlan.yaml` matches the last good state and `netplan get network.vlans` does not list the VLAN.
2. Identify the leftover link exactly: it appears in `ip -d link show type vlan`, is not in any netplan file, and shows as `unmanaged` in `networkctl list`.
3. Remove only that link: `sudo ip link delete <trunk>.<id>`. Alternatively, reboot during an authorized window.

Never delete a link that any netplan file defines, and never remove links in bulk.

## 6. Files on the box

| Path | What |
|------|------|
| `/usr/local/sbin/dynavlan` | the tool |
| `/etc/dynavlan.conf` | configuration |
| `/etc/netplan/90-dynavlan.yaml` | the ONE netplan file dynavlan owns (do not edit; regenerated) |
| `/var/backups/dynavlan/` | timestamped backups of the owned file (last `BACKUP_KEEP`) |
| `/etc/systemd/system/dynavlan.{service,timer}`, `dynavlan-rescan.service` | units from an `install.sh` install (a package install puts them in `/lib/systemd/system` instead) |
| `/etc/systemd/system/dynavlan.timer.d/interval.conf` | timer interval drop-in written by `dynavlan --reconfigure` (both install paths) |
| `/run/dynavlan.lock` | run lock (fd-held; safe to ignore) |

## 7. Removal

Removal is two separate things: taking down the network state dynavlan owns (attended), and removing the software. Do them in that order; removing the software alone leaves the VLANs in place.

### A. Tear down the owned VLANs (attended, at the console)

`dynavlan --teardown` is attended: run it at the console, not over SSH. A management VLAN that is not the default route can still carry your session, and the default-route guard cannot see that. `--dry-run` does **not** preview it (dry-run previews a normal reconcile, not an empty target).

1. Take both units out of service and verify, so neither the timer nor a reboot can re-add the VLANs:
   ```
   sudo systemctl disable dynavlan.service dynavlan.timer
   sudo systemctl stop dynavlan.timer dynavlan.service
   systemctl is-enabled dynavlan.timer dynavlan.service     # both: disabled
   systemctl is-active  dynavlan.timer dynavlan.service     # neither: active
   ```
2. Run `sudo dynavlan --teardown`. It waits for the run lock, refuses unless both units are disabled and inactive, retries any pending deletes, then applies an empty configuration through the same health-gated `netplan try` as a normal change. Only after that is accepted does it delete the VLAN links.
   - Success: it says the owned file now defines no VLANs.
   - It exits 1 and prints `ip link delete <name>` for any link still present after an **accepted** teardown: run those at the console.
   - It exits 1 with **no** delete advice when the apply was not accepted or ended uncertain: the previous owned file was restored, so do not delete links by hand.
   - The monitoring agent is restarted as for any accepted change; a failed restart only warns.
3. Optional: `sudo rm /etc/netplan/90-dynavlan.yaml`. It now defines no VLANs, so no `netplan apply` is needed.

### B. Remove the software

- **Package:** `sudo apt remove dynavlan` stops the timer, waits for any run, and disables the service and timer; it keeps `/etc/dynavlan.conf` and the generated timer drop-in. `sudo apt purge dynavlan` also removes the config, the journald drop-in and the generated interval drop-in. Neither touches `/etc/netplan` or any live interface.
- **Source install** (`install.sh`), in this order (after step A; never `rm -rf` the drop-in directories):
  ```
  sudo systemctl stop dynavlan.timer && systemctl is-active dynavlan.timer       # must NOT print active
  sudo flock -w 300 /run/dynavlan.lock true                                      # waits out any in-flight run
  sudo systemctl disable dynavlan.timer dynavlan.service                         # the two enableable units only
  sudo rm /etc/systemd/system/dynavlan.service /etc/systemd/system/dynavlan-rescan.service /etc/systemd/system/dynavlan.timer
  sudo rm -f /etc/systemd/system/dynavlan.timer.d/interval.conf
  sudo rmdir /etc/systemd/system/dynavlan.timer.d                                # only if empty
  sudo rm -f /etc/systemd/journald.conf.d/00-dynavlan-persistent.conf
  sudo rmdir /etc/systemd/journald.conf.d                                        # only if empty (may fail harmlessly)
  sudo systemctl daemon-reload
  sudo rm /usr/local/sbin/dynavlan /etc/dynavlan.conf
  ```

### C. If you remove the software without tearing down

Nothing is removed from the network: `/etc/netplan/90-dynavlan.yaml` and the VLAN links stay, and netplan re-creates them at boot, with nothing managing them. Removing the YAML and running `netplan apply` does **not** drop the links (netplan does not delete interfaces). To clear that state later: reinstall and run step A; or, at the console, delete the owned file and reboot; or delete the file and each link by hand with `ip link delete`.

Base networking is untouched throughout - dynavlan never modified it.
