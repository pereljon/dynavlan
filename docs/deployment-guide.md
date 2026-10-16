# dynavlan Deployment Guide

How to deploy dynavlan on a netplan/systemd-networkd Ubuntu box. This guide covers installation, configuration, the first attended run, and ongoing operation. For what dynavlan is and how it works, see `README.md` and `docs/dynavlan-PRD.md`.

> **Before the first `--boot`:** a bad apply can drop an SSH session. If you can, run the first `--boot` with an out-of-band fallback: a serial console, IPMI, or physical access. If you have none, run `--dry-run` first. It previews the change and applies nothing.
>
> **Detection side effect.** `--dry-run` and `--status` both run detection. Detection brings physical NICs administratively up and leaves promiscuous mode on. dynavlan does not change them back. Neither mode makes configuration, apply, deletion, or restart changes.

## 1. Prerequisites

- Ubuntu (or compatible) with **netplan and the systemd-networkd renderer**.
- netplan 0.106 or later. dynavlan refuses to run on an older netplan. It reads `netplan --version` where that flag exists (netplan 1.0 and later). Otherwise it reads `dpkg-query -W netplan.io`, which is how the Ubuntu 22.04 line (netplan 0.10x) reports its version.
- Root access.
- The box's trunk-facing NIC or NICs, patched to switch ports that carry tagged VLANs.
  - dynavlan provisions every carrier-up trunk that it finds, not one selected NIC. A box with two trunks gets both.
  - You need no switch-side configuration beyond the trunks themselves.
- `tcpdump` (sniff detection, the default) and `lldpd` (LLDP detection). `install.sh` installs both if they are missing.
- Base uplink connectivity that already works. dynavlan never touches your base netplan files. It only adds its own.

## 2. Install

**Recommended: one-line install of the latest release.** It needs `curl`.

- On an apt/dpkg system, the command adds the dynavlan APT repository and installs with `apt`.
- On any other system, it installs from the release tarball with `install.sh`.

```
curl -fsSL https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh | sudo bash
```

**Install with apt by hand.** This is what the one-liner does on an apt/dpkg system. Use it to add the repository to a box that already runs dynavlan from a `.deb`, without re-running `get.sh`:

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

### Upgrade policy

- **Manual and attended only.** Run `sudo apt update && sudo apt upgrade` yourself when you want the latest release. dynavlan does not support unattended-upgrades.
- **Conffile prompt.** A prompt can appear when both of these are true: the shipped default `/etc/dynavlan.conf` changed, and you edited your copy. The prompt can hang a headless upgrade. Do not run `apt upgrade` unattended on a remote box.
- **A box installed from a `.deb`** needs no reinstall. Add the keyring and the source. dpkg already knows the package.
- **A box installed with `install.sh`** is not in dpkg's database, so apt does not recognize it. `apt install dynavlan` migrates it. The package does these things, in this order:
  1. It records the state of the units (enabled or disabled, running or not).
  2. It takes over the units.
  3. It removes the old copies that `install.sh` left in `/etc/systemd/system`. Those copies would shadow the package's units.

### What an upgrade preserves

This applies to the package and to `install.sh`.

- `dynavlan.service` and `dynavlan.timer` each keep their own enabled or disabled state.
- Only a timer that was running is restarted.
- A unit that you disabled with `systemctl disable` stays disabled.
- A timer that was enabled but stopped stays stopped.
- Only a first-ever install enables both units by default. It never starts them.
- The package follows the same rules when you first install it over a manual `install.sh` deployment. It captures the state before it replaces anything.

### What an upgrade does before it replaces files

1. It stops the timer and verifies that the timer is inactive.
2. It waits up to 300 s for any run in progress to finish.
3. It replaces the script.

If the timer cannot be stopped and verified, or a run still holds the lock, the upgrade stops. It replaces nothing and puts the timer back.

A manual `dynavlan` run that starts between the lock wait and the file replacement is not prevented.

### If configuration fails after the files are unpacked

dpkg leaves the package half-configured. This is not a rollback.

- A timer that was running is restarted.
- The recorded state is kept.
- Run `sudo dpkg --configure dynavlan` to retry from that state.

Two cases cannot restore the exact running state. The upgrade output says so in both:

- **An upgrade from a package older than 0.4.1.** That package never recorded the state. The upgrade assumes that the timer was running if it is enabled.
- **No usable state record exists.** The upgrade output says that the timer's earlier running state is unknown. The upgrade leaves the timer as found and does not restart it.

### Other ways to install

- **Pin a specific version.** This bypasses apt and always installs from the tarball:
  ```
  curl -fsSL https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh | sudo bash -s -- v1.1.1
  ```
- **No apt or dpkg** (any other netplan/systemd-networkd distribution), or you want full manual control over what you transfer. Clone, SCP, or download a ZIP of the repository, then run the installer:
  ```
  scp dynavlan dynavlan.conf dynavlan.service dynavlan-rescan.service dynavlan.timer install.sh <user>@<box>:
  ssh <user>@<box>
  sudo bash install.sh
  ```

Run `sudo bash install.sh`, not `sudo ./install.sh`. Some transfers do not keep Unix modes: a GitHub ZIP download, `rsync` without `-p`, or a filesystem with no permission bits. They remove the executable bit, and `./install.sh` then fails with "Permission denied". Calling the interpreter avoids this. The mode of `dynavlan` itself does not matter, because the installer places it with `install -m 0755`.

`install.sh` does these things:

- It installs the script to `/usr/local/sbin/dynavlan`.
- It installs the config template to `/etc/dynavlan.conf`. It never overwrites an existing config.
- It installs the three systemd units and a persistent-journald drop-in, so that run history survives reboots.
- It makes sure that `tcpdump` and `lldpd` are present.
- It enables `dynavlan.service` (boot reconcile) and `dynavlan.timer` (periodic rescan) **for the next boot**.

Install changes nothing on the network. The first apply happens only when you run `--boot` yourself or when the box next reboots.

## 3. Configure

Every key in `/etc/dynavlan.conf` ships commented out, at its built-in default. Uncomment a key to override it. An invalid value makes dynavlan refuse to run and log at `err`. dynavlan never silently replaces a wrong value with a default.

The keys that most deployments change:

```
# VLAN_MIN=1 / VLAN_MAX=1000       # discovery range
# VLAN_IGNORE=""                   # VLAN IDs never added, e.g. "5,20-25"
# RESTART_SNAPS="..."              # snaps to restart after a VLAN change
# RESTART_SERVICES=""              # systemd services to restart after a VLAN change
# RESTART_ON_NEW_SUBNET=true       # also restart on a new IPv4 subnet
# RESCAN_MINUTES=5                 # rescan timer interval
# REMOVE_ON_CARRIER_LOSS=true      # prune a trunk's VLANs when its link stays down
# REMOVE_MISSING_MINUTES=15        # remove a VLAN that a trunk with link has stopped carrying; 0 = off
# VLAN_ROUTES=false                # opt in to routed mode
```

- **Range.** The discovery range includes VLAN ID 1. To skip IDs inside the range, list them in `VLAN_IGNORE`.
- **Restart targets.** Set `RESTART_SNAPS` and `RESTART_SERVICES` to the agent that must read its interfaces again after a VLAN change. With `RESTART_ON_NEW_SUBNET` (default on), dynavlan also restarts them when a new IPv4 subnet appears on any interface. Two examples: an access port plugged in after boot, or an agent that starts before the base interface gets its DHCP address. See README, "Service-restart integration".
- **Rescan interval.** After you change `RESCAN_MINUTES`, run `sudo dynavlan --reconfigure`.
- **Carrier loss.** `REMOVE_ON_CARRIER_LOSS` is described under "Ongoing operation".
- **Missing VLANs.** `REMOVE_MISSING_MINUTES` is described under "Ongoing operation".
- **Routed mode.** Leave `VLAN_ROUTES` off unless the box must route through the discovered VLANs. The default is full route and DNS isolation.

### Number and quote rules

- A number is a whole decimal number with no leading zero: `5`, not `05`.
- `VLAN_IGNORE` may not contain an empty element: `"1,"`, `",1"`, and `"1,,3"` are invalid.
- A quoted value needs a matching closing quote. Only an optional `#` comment may follow it.

dynavlan refuses a config that breaks these rules, and names the key. Correct the value. There is no automatic migration.

### `VLAN_IGNORE` and the range stop only new VLANs

dynavlan keeps a VLAN that it already owns in these cases:

- You later add the VLAN to `VLAN_IGNORE`.
- You later narrow `VLAN_MIN` or `VLAN_MAX` past the VLAN.

`dynavlan --status` lists these VLANs as `owned-ignored` or `owned-out-of-range`.

To remove one on purpose:

1. Remove the VLAN from the switch trunk.
2. Run `sudo dynavlan --dry-run`.
3. Attended, at the console, run `sudo dynavlan --boot`. The reconcile makes two passes per trunk.

### What changes reach VLANs that dynavlan already owns

- A change to what dynavlan generates (for example `VLAN_ROUTES`) reaches owned VLANs only through an attended `sudo dynavlan --reapply`.
- A change to `VLAN_ROUTE_METRIC_START` affects only future metric assignments. This includes owned VLANs that have no saved metric when you run `--reapply` to go from isolated mode to routed mode. It never renumbers a saved assignment.

### What "isolated by default" means

In isolated mode (the default), each discovered VLAN comes up with DHCP **address only**:

- The VLAN gets an IP address, so the subnet is present and reachable on its own interface.
- It installs **no default route, no DNS, no NTP, and no search domains**.
- It declines IPv6 Router Advertisements.

This is intentional. It overrides netplan's own `dhcp4: true` behavior, which accepts routes. The box's single uplink stays the only default route, and its resolver stays clean.

Isolation also makes the auto-revert safe. A dynavlan VLAN installs no default route, so "the default route moved" is always a failure, and the health check can revert on it.

### Making the VLAN interfaces routable (opt-in)

If the box must route through the discovered VLANs, enable routed mode. Set these keys:

```
VLAN_ROUTES=true                  # accept each VLAN's DHCP default route
VLAN_ROUTE_METRIC_START=100       # first metric
```

`VLAN_ROUTE_METRIC_START` must stay above the uplink's metric.

Then push the change to the VLANs already on the box:

```
sudo dynavlan --reapply
```

`--reapply` regenerates the owned VLAN set with the current settings. It applies the result through the same `netplan try` and health-check path. It applies only if the generated config differs from the file on disk, so it is a safe no-op when nothing changed.

Run `sudo dynavlan --dry-run` first. It prints the assigned `id:metric` map and flags any conflict.

How metrics work in routed mode:

- Each VLAN accepts its DHCP default route at its own metric: 100, 101, 102, and so on.
- dynavlan gives new metrics only to VLANs that have no saved metric. It assigns them in lexical order of the full `iface.id` token, so `enp1s0.10` comes before `enp1s0.2`.
- One ascending sequence is shared across every trunk on the box. Existing VLANs are never renumbered.
- The route with the lowest metric wins. This is normally the untagged uplink, at its own metric.
- If an assigned metric would match or beat the uplink's metric, dynavlan **refuses before it touches the disk** and names the fix: raise `VLAN_ROUTE_METRIC_START`. Applying such a metric would guarantee a revert loop.
- DNS, NTP, search domains, and IPv6 RA stay declined. Routed mode changes routes only.

Routed mode makes the interfaces routable. The box still has one active default path at a time, the one with the lowest metric. dynavlan does not test or use each VLAN's gateway on its own. It does no per-VLAN reachability testing.

To go back to isolated mode, set `VLAN_ROUTES=false` and run `sudo dynavlan --reapply` again.

## 4. First run (attended, at the console)

Use a console for the first `--boot` if you can. dynavlan does not require one.

1. **Confirm the build that you installed.** Do this after every deploy, before you draw any conclusion from behavior:

   ```
   dynavlan --version
   ```

   The output is `dynavlan <version> (build <commit>)`.
   - A `-dirty` suffix means the source tree had uncommitted changes. The build matches no commit.
   - `unknown` means dynavlan was installed from something other than a git checkout.

   A deploy that lands in the middle of an edit looks like a failed fix unless you can name the running build. The same identity appears on every `run start:` line in the journal, so you can also find it later.

2. **Preview.** Detection plus the intended diff. It changes no configuration and does not apply, delete, or restart anything. For the detection side effect, see the note at the top of this guide.

   ```
   sudo dynavlan --dry-run
   ```

   Check the detected VLAN list against what the trunk carries. For example, run `tcpdump -i <iface> -e -nn vlan` by hand. Confirm that the output shows `validate: OK`.

3. **First apply.** Work at the console. Watch the journal in a second terminal:

   ```
   sudo journalctl -t dynavlan -f     # terminal 2
   sudo dynavlan --boot               # terminal 1 (console)
   ```

   Every apply goes through `netplan try`, with a health check against the default route from before the apply. On failure, dynavlan reverts automatically and the box keeps its uplink.

4. **Verify.**

   ```
   sudo dynavlan --status
   ip addr        # each discovered VLAN has a lease
   ip route       # default route unchanged (isolated mode: no routes on VLANs)
   ```

5. **Start the rescan timer.** It arms on the next reboot. To start it now:

   ```
   sudo systemctl start dynavlan.timer
   ```

6. **Confirm that the timer will fire.** A systemd timer can stay `active` with `Result=success` and never elapse. Nothing logs an error when this happens.

   ```
   systemctl list-timers dynavlan.timer
   ```

   `NEXT` and `LEFT` must show a real time. If every column shows `n/a`, the timer has no scheduled elapse and periodic rescans never run. Run `sudo dynavlan --reconfigure` again and restart the timer.

   To confirm that a rescan runs, wait longer than `RESCAN_MINUTES`. Then check that a rescan appears in `journalctl -t dynavlan`.

## 5. Ongoing operation

**After every upgrade, run `sudo dynavlan --reapply`.**

- dynavlan rewrites its netplan file only when the VLAN *set* changes.
- A new build can generate a different config (for example an isolation key or a security fix). On a box whose VLANs are stable, that config would never be written. The fix would be installed and have no effect.
- `--reapply` regenerates the owned set with the running build. It applies the result through the usual `netplan try` and health-check path. If the config already matches, it does nothing.
- It never adds or removes a VLAN, and it never runs detection.

| Task | Command |
|------|---------|
| Check which build is installed | `dynavlan --version` (no root needed) |
| Apply a new build's config to existing VLANs | `sudo dynavlan --reapply` (run after every upgrade) |
| See owned and detected VLANs | `sudo dynavlan --status` |
| Preview what a reconcile would do | `sudo dynavlan --dry-run` |
| Force a rescan now | `sudo systemctl start dynavlan-rescan.service` |
| Full reconcile (adds and removals) | `sudo dynavlan --boot` (or reboot) |
| Change the rescan interval | Edit `RESCAN_MINUTES`, then run `sudo dynavlan --reconfigure` |
| Run history | `journalctl -t dynavlan` |

Steady state needs no action from you:

- **Boot.** dynavlan reconciles the VLAN set against every trunk on the box. It makes two passes per trunk. Guards stop it from removing anything when detection is faulty.
- **Timer.** dynavlan adds newly appearing VLANs on any trunk between boots. It also removes VLANs that a trunk with link has stopped carrying (see "Ongoing operation").

Removals depend on why a VLAN went away:

- **A VLAN is absent from a trunk that still has link.** The switch stopped trunking the VLAN, or the trunk now shows no tags at all, but the port is up. dynavlan records the uptime of the first trusted sample that missed the VLAN. A failed capture does not count as a miss, and a sighting resets the clock. The rescan timer removes the VLAN once `REMOVE_MISSING_MINUTES` have passed and the box has a healthy default route. The default is 15 minutes, or twice `RESCAN_MINUTES` if that is larger. A boot only starts the clock and never removes by this rule, and the clock restarts at reboot. Set `REMOVE_MISSING_MINUTES=0` to turn the rule off. `dynavlan --status` and `--dry-run` print the minutes left for each missing VLAN.
- **The whole trunk lost carrier.** The cause can be an unplugged cable, a disabled switch port, or a pulled cable. dynavlan prunes the trunk's entire owned set, at boot or on the timer, when both of these are true:
  - The link stayed down across a two-sample debounce.
  - The box still has a healthy default route.

  `REMOVE_ON_CARRIER_LOSS` (default `true`) controls this. Set it to `false` to keep those VLANs indefinitely. A brief flap does not trigger removal. A box with no working uplink of its own does not trigger it either: if the dead trunk was the only route out, dynavlan keeps everything.
- **Carrier is up but nothing is detected.** This can be a quiet trunk or a slow-to-converge trunk. A single run keeps everything: uncertain detection never removes anything by itself. The missing-VLAN clock above still runs, so a VLAN that stays unseen for `REMOVE_MISSING_MINUTES` is removed.

### After a stopped or reverted apply

A stop or a revert during `netplan try` restores the configuration. A VLAN link that only the reverted change created can stay in the kernel, with its DHCP address and connected route. While that link exists, dynavlan treats the VLAN as managed elsewhere and does not add it.

Never delete a link that any netplan file defines. Never remove links in bulk.

To recover, work at the console:

1. Check the configuration first. `/etc/netplan/90-dynavlan.yaml` must match the last good state, and `netplan get network.vlans` must not list the VLAN.
2. Identify the leftover link exactly. It appears in `ip -d link show type vlan`, it is not in any netplan file, and `networkctl list` shows it as `unmanaged`.
3. Remove only that link: `sudo ip link delete <trunk>.<id>`. Alternatively, reboot during an authorized window.

## 6. Files on the box

| Path | What |
|------|------|
| `/usr/local/sbin/dynavlan` | The tool |
| `/etc/dynavlan.conf` | Configuration |
| `/etc/netplan/90-dynavlan.yaml` | The only netplan file that dynavlan owns. Do not edit it; dynavlan regenerates it. |
| `/var/backups/dynavlan/` | Timestamped backups of the owned file (the last `BACKUP_KEEP`) |
| `/etc/systemd/system/dynavlan.{service,timer}`, `dynavlan-rescan.service` | Units from an `install.sh` install. A package install puts them in `/lib/systemd/system` instead. |
| `/etc/systemd/system/dynavlan.timer.d/interval.conf` | Timer interval drop-in that `dynavlan --reconfigure` writes (both install paths) |
| `/run/dynavlan.lock` | Run lock (held by file descriptor; safe to ignore) |
| `/run/dynavlan/missing-since` | Runtime scratch, one `TOKEN UPTIME_SECONDS` line per owned VLAN that the last trusted sample missed. It is deleted at reboot, which restarts every clock. Safe to delete. |

## 7. Removal

Removal has two separate parts: take down the network state that dynavlan owns (attended), then remove the software. Do them in that order. If you remove only the software, the VLANs stay in place.

### A. Tear down the owned VLANs (attended, at the console)

Run `dynavlan --teardown` at the console, not over SSH. A management VLAN that is not the default route can carry your SSH session, and the default-route check cannot see that.

`--dry-run` does **not** preview `--teardown`. A dry run previews a normal reconcile, not an empty target.

1. Take both units out of service and verify. Then neither the timer nor a reboot can add the VLANs again:
   ```
   sudo systemctl disable dynavlan.service dynavlan.timer
   sudo systemctl stop dynavlan.timer dynavlan.service
   systemctl is-enabled dynavlan.timer dynavlan.service     # both: disabled
   systemctl is-active  dynavlan.timer dynavlan.service     # neither: active
   ```
2. Run `sudo dynavlan --teardown`. It does these things, in order:
   1. It waits for the run lock.
   2. It refuses to continue unless both units are disabled and inactive.
   3. It retries any pending deletes.
   4. It applies an empty configuration through the same health-gated `netplan try` as a normal change.
   5. After `netplan try` accepts the change, it deletes the VLAN links.

   Results:
   - On success, it says that the owned file now defines no VLANs.
   - If a link is still present after an **accepted** teardown, it exits 1 and prints `ip link delete <name>` for that link. Run those commands at the console.
   - If the apply was not accepted or ended uncertain, it exits 1 with **no** delete advice. The previous owned file was restored, so do not delete links by hand.
   - dynavlan restarts the monitoring agent as it does for any accepted change. A failed restart only logs a warning.
3. Optional: run `sudo rm /etc/netplan/90-dynavlan.yaml`. The file defines no VLANs now, so you do not need `netplan apply`.

### B. Remove the software

**Package:**

- `sudo apt remove dynavlan` stops the timer, waits for any run, and disables the service and the timer. It keeps `/etc/dynavlan.conf` and the generated timer drop-in.
- `sudo apt purge dynavlan` also removes the config, the journald drop-in, and the generated interval drop-in.
- Neither command touches `/etc/netplan` or any live interface.

**Source install (`install.sh`):** finish step A first. Never run `rm -rf` on the drop-in directories. Then run these commands in this order:

```
sudo systemctl stop dynavlan.timer && systemctl is-active dynavlan.timer       # must NOT print active
sudo flock -w 300 /run/dynavlan.lock true                                      # waits for a run in progress
sudo systemctl disable dynavlan.timer dynavlan.service                         # the two enableable units
sudo rm /etc/systemd/system/dynavlan.service /etc/systemd/system/dynavlan-rescan.service /etc/systemd/system/dynavlan.timer
sudo rm -f /etc/systemd/system/dynavlan.timer.d/interval.conf
sudo rmdir /etc/systemd/system/dynavlan.timer.d                                # only if empty
sudo rm -f /etc/systemd/journald.conf.d/00-dynavlan-persistent.conf
sudo rmdir /etc/systemd/journald.conf.d                                        # only if empty; may fail harmlessly
sudo systemctl daemon-reload
sudo rm /usr/local/sbin/dynavlan /etc/dynavlan.conf
```

**Reinstalling after `apt remove`.** The removed package keeps its config but has no record of the earlier state of the units. A reinstall leaves both units **disabled and inactive**. The install log says that it found no earlier-state record.

1. Arm the next boot without starting anything now:
   ```
   sudo systemctl enable dynavlan.service dynavlan.timer    # no --now
   ```
2. Follow section 4: run `--dry-run`, then run `--boot` at the console.
3. Only then run `sudo systemctl start dynavlan.timer`.

### C. If you remove the software without tearing down

Nothing is removed from the network:

- `/etc/netplan/90-dynavlan.yaml` and the VLAN links stay.
- netplan re-creates the links at boot, and nothing manages them.
- Removing the YAML and running `netplan apply` does **not** drop the links, because netplan does not delete interfaces.

To clear that state later, use one of these methods:

- Reinstall dynavlan and run step A.
- At the console, delete the owned file and reboot.
- Delete the file, then delete each link by hand with `ip link delete`.

Base networking is untouched throughout. dynavlan never modified it.
