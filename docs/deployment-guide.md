# dynavlan Deployment Guide

How to deploy dynavlan on a netplan/systemd-networkd Ubuntu box. This covers installation, configuration, the first (attended) run, and ongoing operation. What dynavlan is and how it works: `README.md`, `docs/dynavlan-PRD.md`.

> **Pre-release note:** dynavlan is in initial testing. Perform the first apply at the console (physical or serial), not over SSH alone - a bad apply can drop the connection, and the console is the recovery path.

## 1. Prerequisites

- Ubuntu (or compatible) using **netplan with the systemd-networkd renderer**; netplan >= 0.106 (dynavlan checks and refuses below it). The check reads `netplan --version` where it exists (netplan >= 1.0) and otherwise falls back to `dpkg-query -W netplan.io`, which is how the Ubuntu 22.04 line (netplan 0.10x) reports itself.
- Root access.
- The box's trunk-facing NIC patched to a switch port carrying tagged VLANs. No switch-side configuration is required beyond the trunk itself.
- `tcpdump` (sniff detection, default) and `lldpd` (LLDP detection). `install.sh` installs both if missing.
- Base uplink connectivity already working (dynavlan never touches base netplan files; it only adds its own).

## 2. Install

Copy the six artifacts to the box and run the installer:

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
# VLAN_IGNORE=""                   # VLANs never to configure, e.g. "5,20-25"
# RESTART_SNAPS="..."              # snaps to restart after a VLAN change
# RESTART_SERVICES=""              # systemd services to restart after a VLAN change
# RESCAN_MINUTES=5                 # timer interval (run --reconfigure after changing)
# VLAN_ROUTES=false                # opt-in: accept DHCP routes per VLAN at per-VLAN metrics
```

Set `RESTART_SNAPS`/`RESTART_SERVICES` to whatever agent should re-enumerate interfaces after a VLAN change (see README "Service-restart integration"). Leave `VLAN_ROUTES` off unless you specifically want the box routing via discovered VLANs; the default is full route/DNS isolation.

## 4. First run (attended, at the console)

0. **Confirm what you just installed** - after every deploy, before drawing any conclusion from behavior:

   ```
   dynavlan --version
   ```

   Prints `dynavlan <version> (build <commit>)`. A `-dirty` suffix means the source tree had uncommitted changes and the build matches NO commit; `unknown` means it was installed from something other than a git checkout. Worth ten seconds: a deploy that lands mid-edit is indistinguishable from a failed fix unless you can name the running build. The same identity appears on every `run start:` line in the journal, so it is also recoverable after the fact.

1. **Preview** - detection plus the intended diff, zero changes:

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
| Force an add-only rescan now | `sudo systemctl start dynavlan-rescan.service` |
| Full reconcile (adds + removals) | `sudo dynavlan --boot` (or reboot) |
| Change the rescan interval | edit `RESCAN_MINUTES`, then `sudo dynavlan --reconfigure` |
| Run history | `journalctl -t dynavlan` |

Steady state is hands-off: boot reconciles the VLAN set against the trunk (two-pass, with guards against removing anything on faulty detection); the timer adds newly appearing VLANs between boots. VLANs that disappear from the trunk are removed at the next boot reconcile, never by the timer.

## 6. Files on the box

| Path | What |
|------|------|
| `/usr/local/sbin/dynavlan` | the tool |
| `/etc/dynavlan.conf` | configuration |
| `/etc/netplan/90-dynavlan.yaml` | the ONE netplan file dynavlan owns (do not edit; regenerated) |
| `/var/backups/dynavlan/` | timestamped backups of the owned file (last `BACKUP_KEEP`) |
| `/etc/systemd/system/dynavlan.{service,timer}`, `dynavlan-rescan.service` | units |
| `/run/dynavlan.lock` | run lock (fd-held; safe to ignore) |

## 7. Removal

```
sudo systemctl disable --now dynavlan.timer dynavlan.service
sudo rm /etc/systemd/system/dynavlan.service /etc/systemd/system/dynavlan-rescan.service /etc/systemd/system/dynavlan.timer
sudo rm -rf /etc/systemd/system/dynavlan.timer.d
sudo systemctl daemon-reload
sudo rm /etc/netplan/90-dynavlan.yaml && sudo netplan apply   # drops dynavlan's VLANs
sudo rm /usr/local/sbin/dynavlan /etc/dynavlan.conf
```

Base networking is untouched throughout - dynavlan never modified it.
