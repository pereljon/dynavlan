# todo - outstanding tasks and their state

Owns: open tasks and their status. Does NOT hold permanent facts or decisions (those live in dev/ docs and context/decisions.md).
Maintain: update whenever a task is added, changes state, or completes.
Entry format: `- [ ] task`  /  done: `- [x] task (done YYYY-MM-DD)`

## ==> CURRENT WORK (2026-07-28): all-trunks provisioner redesign <==

**STATUS: design APPROVED by operator. NEXT ACTION: invoke the `writing-plans` skill against the
approved spec to produce the implementation plan, then implement with TDD.**

Design spec (authoritative, read it first): `docs/superpowers/specs/2026-07-28-all-trunks-provisioner-design.md`
(rev 2 + hardware findings; committed aa816af). It was architect-reviewed (verdict: sound to plan after
folding 5 gate items, all folded) and the core feasibility was hardware-validated before any code.

What it does: repositions dynavlan from single-trunk monitoring provisioner to a GENERAL provisioner
that configures detected VLANs on EVERY carrier-up trunk (not one selected). Locked decisions live in
spec section 2; the load-bearing one is section 3 (**`iface.id` is the universal token for every VLAN
set** - bare ids alias across parents once two trunks share a VLAN id). Removes select_trunk/hysteresis
and the relocation branch; drops `id` metric mode; unified single netplan-try apply over the whole box.

Brainstorm decisions (all in the spec): all trunks; overlapping ids -> both interfaces; trunk goes
dark -> preserve (remove only carrier-up + non-empty-detection + absent-both-passes); isolated +
discovery-routed together, id mode dropped; metrics keyed iface.id discovery-order; unified apply;
stale interfaces on a vacated trunk accepted+documented; health check UNCHANGED (multi-uplink is normal,
watching lowest uplink suffices for never-strand).

REQUIRED deliverable of the implementation (do not forget): reframe README + PRD + deployment-guide to
the general-provisioner positioning (they still say single-trunk/monitoring, correctly, because the code
still is). The docs reframe lands WITH the code, never before (don't document unbuilt behavior). Also
resolve the deferred positioning question in open_questions.md (monitoring-origin vs general) as part of it.

Pre-implementation validations already banked (2026-07-28, see spec section 10): netplan 0.107 accepts
multi-parent + overlapping VLAN id (distinct netdevs); per-trunk detection reads each trunk's tagged set;
per-trunk native excluded for free (untagged native is never sniffed). Remaining hardware tests are
post-implementation (dual leasing, carrier-pull-preserve, routed multi-trunk, unified revert w/ 2 trunks).

## Planning phase - COMPLETE (2026-07-14)

- [x] dynavlan design planned, locked, hardware-validated on a real Protectli/igb lab box - see context/decisions.md, context/open_questions.md
- [x] PRD written, revised to v3.1, three architect reviews (final verdict GO / implementation-ready) - docs/dynavlan-PRD.md
- [x] Technical design doc - dev/features/dynavlan.md (architecture, backend seam, apply/rollback state machine, module decomposition, systemd/install layout)
- [x] Test plan written + architect-reviewed + hardened - dev/features/dynavlan-tests.md (lean 3-layer: unit asserts, --dry-run, hardware checklist)
- [x] Project genericized (no company-specific refs) and pushed to github.com/pereljon/dynavlan (private). Fully synced 2026-07-23 (f42c6b1..36190a8: design docs, implementation, review rounds 1-3).

## NEXT: Build dynavlan

Read first (fresh session): docs/dynavlan-PRD.md (v3.3, authoritative behavior), dev/features/dynavlan.md (how to build it), dev/features/dynavlan-tests.md (tests to write).
Approach agreed: single cohesive bash implementation (NOT subagent fan-out - the apply/rollback state machine is too coupled). TDD the pure helpers; build outward; review with subagents at the end.

- [x] Step 1 - TDD the 5 pure helpers (done 2026-07-14). `tests/unit.sh` (35 asserts, no framework) drives `parse_vlan_ignore` (1a), `compute_candidates` (1b), `health_check_eval` (1c), `boot_removals` (1d), `select_trunk` (1e); all RED-then-GREEN. Helpers live in the sourceable `./dynavlan` script (main guarded by BASH_SOURCE). Written bash-3.2-safe (sorted space-separated id lists via sort/comm/grep, no associative arrays) so the suite runs on the macOS dev box as well as Ubuntu. Shared `emit_set` extracted. Contracts: `health_check_eval SNAP_IFACE POST_ROUTES` (post routes as `iface:metric` tokens); `select_trunk` hysteresis margin = 1 (marginal lead does not flip). Run: `bash tests/unit.sh`.
- [~] Step 2 - Core script `./dynavlan` written (2026-07-14, code-complete, 858 lines; installs to /usr/local/sbin/dynavlan). Implements: constants, pure helpers (Step 1), set utils, leveled logging, load_config (strict validate/refuse), check_preconditions (FR-0 root/netplan>=0.106/`try` capability/deps), discover_phys_ifaces, prep_iface (up+promisc+carrier-wait), detect_sniff/detect_lldp/detect_iface/run_detection (wraps select_trunk), 6-fn backend seam (owned_vlans, list_managed_vlans, generate_config atomic, validate our-vs-base, apply_with_revert fifo/§9, remove_vlan), snapshot_default_route/post_apply_health (wraps health_check_eval), backups, wait_leases/restart_targets, apply_change (§7 state machine), do_boot (two-pass)/do_rescan (add-only, no relocate)/do_dryrun/do_status/do_reconfigure, main (fd-held flock, dispatch).
      Locally verified (all that's testable off-hardware): `bash -n` parse under bash 3.2; 35/35 pure-helper asserts still green (suite sources the full script); arg-handling exit codes; load_config accept/reject across 10 configs. NOT yet verified on hardware: detection, apply/rollback, netplan try revert semantics - that is Layer 2 (--dry-run) + Layer 3 (Meraki box).
      Decisions taken during build (need a look in review): PER_VLAN_MAC=true refuses-to-run (G-4 unimplemented, default false works); rescan pins trunk to the owned parent (never relocates; relocation is boot-only); on health-FAIL revert, restore prior file on disk but do NOT re-apply (FR-19, don't fight netplan's revert); FR-14 renderer NOT re-declared (inherited). File is 933 lines: single-file by design (design §1); the ECC global 800-line rule does NOT apply here (recorded in CLAUDE.md How-I-Work). Guards kept expanded/readable, no logic compressed.
    - [ ] Step 2 remaining: fold in code-review/security-review findings (Step 4); run Layer 2 `--dry-run` + Layer 3 on the Meraki box (Step 5).
- [x] Step 3 - Packaging (done 2026-07-21). Artifacts at repo root: `dynavlan.conf` (all keys commented, PRD §8), `dynavlan.service` (--boot, oneshot, After=networkd, TimeoutStartSec=600, WantedBy=multi-user), `dynavlan-rescan.service` (--rescan, timer-only, NEW third unit - a .timer needs a fixed-mode service), `dynavlan.timer` (OnBootSec/OnUnitActiveSec, Unit=dynavlan-rescan.service; interval drop-in from --reconfigure), `install.sh` (root; installs script/config/3 units; ensures tcpdump+lldpd; persistent-journald drop-in per FR-31; --reconfigure; enables boot service + starts timer; does NOT run --boot). tcpdump+lldpd already in docs/deployment-guide.md line 64 (no edit needed). Design §11 updated for the third unit + journald-only logging. All bash -n clean. NOT yet exercised on hardware.
- [x] Step 4 - Review pass (done 2026-07-23, TWO rounds). Round 1: `code-reviewer` + `security-reviewer`; 1 HIGH + 6 MEDIUM fixed. Round 2 (Fable model, briefed to verify round-1 fixes): BLOCK verdict - CRITICAL fifo-ACCEPT race (accept could be buffered pre-apply, nullifying FR-18), dead-try false accept, FAIL-path EOF, relocation deadlock (round-1 regression), detection scaling; ALL FIXED same day (see decisions.md 2026-07-23 round-2 entry). backend_apply_with_revert rewritten as an evidence+liveness+consecutive-health poll loop; do_boot gained the AC-3 relocation branch; detection now port-count-independent. Script 1242 lines; 47/47 asserts green (incl. new 1f); PRD bumped v3.2.
- [x] VLAN_LIMIT feature (approved + done 2026-07-23): VLAN_WARN=32 (renamed from VLAN_COUNT_WARN), VLAN_LIMIT=64 (0=unlimited), VLAN_LIMIT_MODE=refuse|fill (default refuse). FR-36/AC-13 in PRD v3.2; tests 1f; wired into boot/rescan/relocation/dry-run. Removals-only changes bypass the cap (shrink always allowed).
- [x] Round-3 targeted review (done 2026-07-23): scoped to round-2 fixes + VLAN_LIMIT. 1 HIGH (mid-revert false ACCEPT - closed with the §9 confirmation-window bound) + 2 MEDIUM + 3 LOW, all fixed; clean bills on fifo lifecycle, probe pre-existence, detection concurrency, gate plumbing, bash-3.2 parse. See decisions.md round-3 entry. Script 1270 lines; 47/47 green. NOT yet committed (commit cfa4383 predates these fixes).
- [x] Round-4 scoped review (done 2026-07-23, Fable cold read after model switch): no fourth full review (user-approved; unchanged code, 3 rounds prior). 2 fixes: restore_prior copy-back now checked + loud (err names the surviving backup); --dry-run takes the flock non-blocking (holds if free, warns + proceeds read-only if held). Portability spot-check clean. Script 1283 lines, 47/47 green. Design §6/§7, tests L2, CHANGELOG updated. See decisions.md round-4 entry. NOT yet committed.
- [x] VLAN_ROUTES routed mode (FR-37, done 2026-07-23, user-approved, landed pre-hardware by user choice): VLAN_ROUTES=false default, VLAN_ROUTE_METRIC_START=100, VLAN_ROUTE_METRIC_MODE=discovery|id. TDD'd (tests 1g, 17 asserts RED->GREEN); metric map persisted in the owned YAML; up-front uplink-metric conflict refusal in apply_change; dry-run previews map+conflict. 64/64 green. PRD v3.3 (FR-37/AC-14); L3-22/23 added to the hardware checklist. See decisions.md FR-37 entry. NOT yet committed.
- [ ] Step 5 - NEXT ACTION. Run the hardware integration checklist (dynavlan-tests.md Layer 3, L3-1..L3-23) on the actual Protectli appliance on the live Meraki trunk, with console access (user has it). No VM. Install runbook (given to user 2026-07-23): (1) scp dynavlan, dynavlan.conf, 3 units, install.sh to the box; (2) `sudo ./install.sh` (installs deps/script/config/units, persistent journald, enables service+timer for NEXT boot, changes nothing on the network); (3) `sudo dynavlan --dry-run` and sanity-check the diff vs a manual tcpdump; (4) first `sudo dynavlan --boot` AT THE CONSOLE, watch `journalctl -t dynavlan -f`, then `--status` + `ip addr` to verify isolated leases; timer arms on reboot or `systemctl start dynavlan.timer`. Priority checklist rows beyond the happy path: L3-15/L3-20 (accept race + mid-revert guard), L3-16 (FAIL path rides netplan's own revert), L3-17 (dead-try), L3-18 (cross-NIC relocation), L3-21 (reverted-add ghost netdev probe).

- [x] HARDWARE BUG 1 (found + fixed 2026-07-25, first real run): `sudo dynavlan --dry-run` refused on the box with `netplan >= 0.106 required (found unknown)`. `netplan_version` probed `netplan --version`, a flag that only exists on netplan >= 1.0; the fleet runs 0.10x (box: netplan.io 0.107.1-3ubuntu0.22.04.4), so the probe returned empty on EVERY target box and FR-0 refused unconditionally. Fixed: pure `parse_version` helper + source chain `netplan --version` then `dpkg-query -W netplan.io`, stdout only; "cannot determine version" now logged as a refusal distinct from "below the minimum". Tests 1h added RED->GREEN (74/74 at the time; 82/82 now). See decisions.md 2026-07-25. CONFIRMED on the box the same day (committed 92cddc5).

## Hardware session (first real runs on the box) - live state (updated 2026-07-27)

Box: `ssh -i ~/.ssh/domotz m18admin@192.168.101.39` (root via passwordless sudo). Ubuntu 22.04.5,
netplan.io 0.107.1.
INSTALLED: /usr/local/sbin/dynavlan build **e225a1c** (single-trunk, the current released-line code).
Confirm with `dynavlan --version` before concluding ANYTHING from behavior. Local repo is ahead of the
box (7e52fd5 defensive guard + the all-trunks DESIGN commits, none of which change the installed
single-trunk behavior). The all-trunks code does NOT exist yet - it is designed, not built.
/etc/dynavlan.conf: defaults except RESTART_SNAPS="domotzpro-agent-publicstore"; VLAN_ROUTES=false.
Domotz agent unit `snap.domotzpro-agent-publicstore.domotzpro-agent-deamon.service` ("deamon" misspelled
in the snap, not here); active running.

**TWO TRUNKS ACTIVE as of 2026-07-28** (operator plugged a second trunk into enp2s0 for multi-trunk
testing). Both carrier-up, each with a DIFFERENT native VLAN - this is the concrete L3 fixture in the
spec (section 10):
  enp1s0  tagged: 1 18 20 21 22 100 200   native/untagged 101 -> 192.168.101.39  default metric 10
  enp2s0  tagged: 1 18 20 21 22 101 200   native/untagged 100 -> 192.168.100.118 default metric 20
So VLAN 100 is tagged on enp1s0 but native on enp2s0, and 101 the reverse. TWO default routes now (the
"multi-uplink is normal" finding). LLDP empty on the UniFi -> detection is sniff-only here.
The installed SINGLE-trunk build owns [1 18 20 21 22 100 200] on enp1s0 only (it picks one trunk; enp1s0
wins the tie). It is stable: the rescan timer is add-only + pinned to enp1s0, so it will not touch enp2s0.
Do NOT run --boot on the single-trunk build now expecting multi-trunk behavior - it only does enp1s0.

SERIAL CONSOLE set up 2026-07-27: GRUB_TERMINAL="console serial", GRUB_SERIAL_COMMAND @115200,
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8" (both HDMI and serial work; serial is primary).
serial-getty@ttyS0 active. An iTerm `screen` to the USB-serial lives in a tmux session "Serial Console"
ON THE MAC - reachable from here via `tmux send-keys -t "Serial Console"` + `tmux capture-pane`, which
is how the revert drill was driven (SSH used only for read-only polling).

**Release status: the last blocker is CLEARED.** The FR-18 revert/rollback path was exercised end to end
on hardware 2026-07-27 (serial-driven) and passed the full contract (health FAIL -> netplan try revert ->
uplink preserved, no deletes, no restarts, rc=1, restore_prior converged disk). Routed mode (FR-37) also
validated on the box in the same session. See decisions.md 2026-07-27 and tests L3-6/L3-20/L3-22.
- [x] Revert/rollback drill on hardware (L3-6/L3-20) - DONE 2026-07-27, serial-driven, full contract passed.
- [x] Routed mode happy path on hardware (L3-22) - DONE 2026-07-27 (metrics 100-106, uplink stays primary).
- [ ] Release v0.1.0 when ready (operator-authorized only): tag, push tag, gh release on pereljon/dynavlan.
      Retitle CHANGELOG "## Unreleased" -> "## [0.1.0] - <date>". Everything material is now hardware-verified.

- [x] FR-0 netplan probe fix CONFIRMED WORKING ON HARDWARE (2026-07-25): --dry-run now gets past
      preconditions and completes. Committed 92cddc5.
- [x] First successful dry-run output: trunk enp1s0, detected [1 18 21 22 100 101], additions [18 100],
      count gate OK, validate OK.
- [x] **FIRST REAL APPLY SUCCEEDED (2026-07-25 01:36-01:41 box time, unattended via boot service).**
      User rebooted; orphan links cleared; dynavlan.service ran --boot. Journal evidence:
      pass1=pass2=[1 18 21 22 100 101] (2-pass agreement, no removals), `netplan try ACCEPTED`,
      `reconcile applied on enp1s0: added [18 21 22 100 101] removed [none]`, rc=0. Wrote
      /etc/netplan/90-dynavlan.yaml with all 5 VLANs as `enp1s0.<id>`, use-routes/dns/ntp/domains all false.
      - **NEW SUBNET DISCOVERED AND LEASED: VLAN 18 -> 192.168.18.6/24.** Never configured by hand;
        found on the wire. This is the product thesis validated on hardware.
      - Isolation held: `ip route show default` is exactly one line (uplink enp1s0 metric 10). Five VLANs
        up, zero routes/DNS/NTP injected. The hand-tuned metric 100/200/300 defaults are gone as expected.
      - SSH survived the interface rename (vlan101 -> enp1s0.101); DHCP returned 192.168.101.39.
      - Duration 4m06s: two detection passes x (30s carrier wait on dead enp2s0 + 60s sniff) = ~3m of waiting.
- [x] **HARDWARE BUG 2 (FR-7a): LLDP ingested the native/pvid VLAN as tagged. FIXED IN REPO, NOT YET
      DEPLOYED.** Symptom: `enp1s0.100` came up with link-local only, "VLAN 100 acquired no lease within
      30s". Root cause verified on the box: `lldpctl -f keyvalue enp1s0` returns exactly
      `vlan.vlan-id=100` + `vlan.pvid=yes`, i.e. LLDP was the ONLY source for 100 and flagged it native.
      The native VLAN is untagged on the wire, so an interface carrying that tag can never receive a frame.
      (My first explanation - DHCP server refusing a second lease for the same MAC on 192.168.100.0/24 -
      was a guess and was WRONG. The interface is dead, not duplicated.)
      - `VLAN_IGNORE="100"` was considered and REJECTED: it is a per-site manual step for something the
        tool can discover, and contradicts "no hardcoded native VLAN". The conf edit was attempted and
        BLOCKED by the permission classifier; /etc/dynavlan.conf on the box is still all-defaults.
      - Fix: new pure helper `lldp_tagged_vlans` (stateful adjacency parse of the keyvalue blocks) drops
        `pvid=yes`; `detect_lldp` now calls it. Scoped to the LLDP source only, so a VLAN the sniff sees
        tagged still counts. TDD RED->GREEN, 6 new asserts in section 1i, suite now 80/80.
      - NOTE FR-7 already recorded "Meraki advertised only pvid 100" and SKELETON.md:32 said the same.
        The observation existed; nothing acted on it. Worth a second look for other noted-but-unhandled facts.
- [x] **HARDWARE BUG 3 (FR-21a): the rescan timer had NEVER fired, on any install. FIXED IN REPO,
      NOT YET DEPLOYED.** `systemctl list-timers` = n/a in every column; `TimersMonotonic={ OnUnitActiveUSec
      =5min ; next_elapse=0 }`, NextElapseUSecMonotonic=infinity, LastTriggerUSec empty, yet unit active and
      Result=success. The rendered drop-in's `OnUnitActiveSec=` reset wiped the base unit's OnBootSec too
      (an empty On*Sec= resets the WHOLE monotonic list), leaving no first-fire anchor. FR-21 periodic
      discovery has never worked; every VLAN seen so far came from the boot reconcile. Fix: pure
      `render_timer_dropin` restates all triggers, first fire via OnActiveSec (survives install.sh's
      stop/restart). Suite 80 -> 82 (section 1j). Hardware row L3-24 added.
- [x] **FR-7a + FR-21a DEPLOYED AND CONFIRMED ON HARDWARE (2026-07-25 02:18-02:26 box time).**
      install.sh upgrade path ran end-to-end for the first time (stop timer -> lock -> swap -> reconfigure ->
      restart via trap). Timer now real: NEXT 02:26:01, LAST 02:21:01, TimersMonotonic gained
      `{ OnActiveUSec=2min ; next_elapse=46min }`, and the OnUnitActiveSec chain picked up its anchor once
      the run deactivated (it reads n/a WHILE the triggered service runs - not a bug). First-ever rescan ran
      02:21:02-02:22:34: `no new VLANs ... zero applies/restarts` (NFR-2 idempotency confirmed live).
      `detect_lldp enp1s0` now returns empty (FR-7a confirmed on the wire).
- [x] **HARDWARE BUG 4 (FR-5a): the sniff counted our own egress; removals could never fire. FIXED IN
      REPO, NOT YET DEPLOYED.** Found because 100 stayed in `detected` after the LLDP fix. 75s directional
      capture: 1 outbound VID-100 DHCP Request from our own MAC, 0 inbound. Every owned VLAN transmits
      tagged DHCP, so every owned VLAN self-detects and FR-23 removal is dead in general. Fix: `-Q in`
      plus a refuse-to-run probe (`tcpdump -Q in -d vlan`, non-mutating). Hardware row L3-25.
- [x] **FR-5a DEPLOYED AND CONFIRMED ON THE WIRE (2026-07-25 02:38 box time).** Timer rescan logged
      `detected=[1 18 21 22 101]` - 100 is GONE from detection, while owned still lists it. That gap is
      exactly what lets --boot remove it. Rescan correctly did nothing (add-only). Timer also proved the
      FR-21a fix survives an upgrade: install.sh's stop/start re-armed it via OnActiveSec (NEXT was real
      immediately after install), which is the case that used to leave a permanently dead timer.
- [ ] (superseded) DEPLOY the FR-5a fix, then `--boot` to finally clear the dead `enp1s0.100`. Until then the box
      still owns it and a reboot will NOT clear it (the config recreates the interface, it transmits, the
      sniff sees itself, removal is suppressed). Confirm afterwards that `detected` drops 100. After install, `systemctl list-timers
      dynavlan.timer` MUST show a real NEXT (never n/a) - that is the only proof; active + Result=success
      proved nothing. Then confirm a rescan actually appears in `journalctl -t dynavlan` after the interval.
- [ ] (superseded, kept for the record) DEPLOY the FR-7a fix to the box and confirm. The box still runs the pre-fix script and still
      owns [18 21 22 100 101] incl. the dead `enp1s0.100`. After deploying, `--boot` (not `--rescan`,
      which is add-only) removes VLAN 100 post-accept. This is checklist row L3-13b.
- [ ] ~~OPEN Q: the base netplan config no longer declares the VLANs.~~ RESOLVED by the apply above:
      dynavlan now owns 18/21/22/100/101. Historical detail retained below.
- [x] **(resolved) the base netplan config no longer declares the VLANs.** During this session
      the user edited `/etc/netplan/01-netcfg.yaml`, removing its whole `vlans:` block (vlan1/21/22/101 with
      route-metrics 100/200/300/300) and saving the original as `/etc/netplan/01-netcfg.yaml.bak`. The live
      file is now ethernets-only (enp1s0 metric 10, enp2s0 metric 20). Consequences, all verified:
      - `netplan get network.vlans` returns `null`, and `/run/systemd/network/` holds ONLY
        10-netplan-enp1s0.network + 10-netplan-enp2s0.network. netplan no longer generates those VLANs.
      - vlan1/vlan21/vlan22/vlan101 are STILL UP in the kernel as ORPHANS: created by an earlier apply,
        never torn down (netplan apply does not delete virtual devices it has stopped managing).
      - So `backend_list_managed_vlans` currently excludes 21/22/101 via its LIVE-KERNEL source only
        (`ip -d link show type vlan`), not via its netplan-config source. VLAN 1 is excluded by VLAN_MIN=2.
      - **Therefore the current dry-run is not what a rebooted box would show.** Once the orphan links go
        away (reboot, or `ip link del`), additions become [18 21 22 100 101], and dynavlan would adopt the
        VLANs the user had hand-tuned. Decide the intended end state before --boot:
        (a) restore the vlans block from the .bak and let dynavlan add only new VLANs; or
        (b) keep them out and let dynavlan own all of them - but note the hand-assigned default routes
            (metrics 100/200/300) disappear unless VLAN_ROUTES=true is set (uplink is metric 10, so the
            default VLAN_ROUTE_METRIC_START=100 clears the conflict check).
      - [x] 2026-07-25: user removed `/etc/netplan/01-netcfg.yaml.bak`. /etc/netplan now holds only
        00-installer-config.yaml (subiquity: enp1s0 critical + dhcp4 + nameservers 192.168.41.1) and
        01-netcfg.yaml (ethernets-only, enp1s0 metric 10 / enp2s0 metric 20). Neither declares vlans;
        `netplan get network.vlans` is still `null`. This CLOSES option (a): the hand-tuned vlans block
        no longer exists anywhere on the box, so the only remaining path is (b), dynavlan owning them.
        The four orphan kernel links (vlan1/21/22/101 on enp1s0) are STILL UP, so the exclusion described
        above is unchanged until a reboot or `ip link del`.
- [ ] **BLOCKER before --boot: RESTART_SNAPS is empty** (all-defaults config) while the
      `domotzpro-agent-publicstore` snap IS installed. As-is, --boot would provision VLANs and never restart
      the agent, so it would never enumerate the new subnets. Set
      `RESTART_SNAPS="domotzpro-agent-publicstore"` in /etc/dynavlan.conf first.
- [ ] UX gap, user-reported, fix NOT yet approved: `--dry-run` prints one line then goes silent for ~90s
      (CARRIER_WAIT_SECONDS=30, burned in full because enp2s0 has no carrier and the loop at dynavlan:590
      only breaks early when ALL ifaces are up, then SNIFF_SECONDS=60). Looks wedged. Proposed: log when
      the carrier wait starts and when the sniff starts, so output appears roughly every 30s.
- [ ] install.sh upgrade hardening written + verified, NOT COMMITTED. Also uncommitted: README.md and
      docs/deployment-guide.md now say `sudo bash install.sh` (mode-dropping transfers strip the exec bit;
      the box's whole repo dir arrived 664, dynavlan included - harmless, install -m 0755 sets the
      destination mode, but ./install.sh itself fails). Pending user approval: run the real install.sh on
      the box end-to-end (fresh path is safe now, timer inactive; the UPGRADE path needs the timer running,
      i.e. a live rescan and a real network change - console only).

### Session lessons (2026-07-25) - carry these forward

Five defects found in one hardware session, ALL of them invisible to 82 unit asserts and four rounds of
code review, because every one lived in the seam between the script and the platform rather than in the
script's logic. Four of the five were SILENT: no error, no log line, the box reporting healthy.

- FR-0: `netplan --version` does not exist below netplan 1.0 (loud, but misleading message).
- FR-7a: `lldpctl` flags the native VLAN `pvid=yes`; ingesting it built an interface for a tag that is
  untagged on the wire. Silent apart from a "no lease" warning.
- FR-21a: an empty `On*Sec=` resets the ENTIRE systemd monotonic timer list, not the assigned option.
  Timer active + Result=success + never fires. Completely silent; FR-21 had NEVER worked.
- FR-5a: tcpdump captures egress, so an owned VLAN self-detects on its own DHCP and FR-23 removal can
  never fire. Completely silent.
- install.sh: could rewrite the script under a live run (bash reads by file offset).

What to actually do with that:
1. **Docs recording an observation is not the same as code acting on it.** FR-7 and SKELETON.md:32 both
   already said "Meraki advertises only the pvid". Written twice, acted on never. Re-scan the docs for
   other noted-but-unhandled facts.
2. **Verify deploys against live platform state, never against "the command exited 0".** FR-21a was
   found only because `systemctl list-timers` got read after an install that reported success.
3. **A negative result from a window shorter than the phenomenon's period is not evidence of absence.**
   A 15s capture appeared to refute the (correct) egress-self-detection theory; the sniff window is 60s,
   so the probe had to be at least that long. Nearly recorded the wrong conclusion.
4. **Do not assert a plausible mechanism before reading the evidence.** The VLAN-100 no-lease cause was
   confidently explained as DHCP-server refusal for a duplicate MAC. Wrong; it was an untagged-on-wire
   interface. The lldpctl output settled it in one command and should have been step one.
5. Remaining untested platform seams, same risk class, worth a deliberate pass before release: the
   journald drop-in (FR-31), dynavlan.service boot ordering vs networkd, and the `netplan try`
   capability probe.

## State snapshot (2026-07-25, pre-context-clear)
- Build COMPLETE through review round 4 + FR-37 routed mode + 5 hardware fixes. Script 1505 lines, 82/82 unit asserts green (1a-1j). PRD v3.3 + FR-5a/FR-7a/FR-21a.
- Repo PUBLIC at github.com/pereljon/dynavlan (MIT license), pushed and synced at 2803e89 (five fix commits from the 2026-07-25 hardware session: 92cddc5 FR-0, 2f09c22 install.sh, 8a57857 FR-7a, c58859d FR-21a, 2803e89 FR-5a).
- Session model: Opus 5 (claude-opus-5) as of 2026-07-25 (was Fable 5 for the review rounds).
- PENDING user plan (2026-07-23): (1) user extracts the original Domotz deployment project from git history into a separate project - both files last at commit bed1d35 (`git show bed1d35:docs/deployment-guide.md` and `git show bed1d35:dev/IMPLEMENTATION-SPEC.md`); (2) THEN clean/rewrite git history so the repo starts fresh from the current tree (orphan-branch squash + force push; extraction MUST happen first - rewrite + GC destroys bed1d35). Do not rewrite history until the user confirms the extraction is done.
- RESTART_SNAPS default is now EMPTY (behavior change 2026-07-23): existing deployments must set RESTART_SNAPS="domotzpro-agent-publicstore" explicitly in /etc/dynavlan.conf.
- HARDWARE STATUS (2026-07-25): Layer 2 (--dry-run) PASSES on the box. Confirmed working on real hardware:
  detection, first apply via `netplan try ACCEPTED`, route isolation (one default, uplink metric 10),
  DHCP leases on discovered VLANs incl. the never-configured VLAN 18, idempotent rescan (zero applies),
  the rescan timer, and the install.sh upgrade path. Layer 3 rows still OUTSTANDING: L3-1, L3-2, L3-4..L3-25
  except the pieces noted above - in particular NO removal path, NO revert/rollback case, and NO agent
  restart has ever run. Do NOT claim those work until exercised on the box.
- [x] dev/SKELETON.md rewritten for dynavlan (done 2026-07-23, user-requested full rewrite): run lifecycle, detection, reconcile policies, apply/rollback state machine + accept primitive, routed mode, key invariants. Base-deployment content it held lives in docs/deployment-guide.md + dev/IMPLEMENTATION-SPEC.md (nothing lost). CLAUDE.md Start-Here note updated ("not yet built" was stale too).
- [x] Domotz-content sweep (done 2026-07-23, user directive: only the restart example stays): dev/IMPLEMENTATION-SPEC.md deleted; RESTART_SNAPS default now empty (Domotz snap = example, not default - deployments must set it); PRD/CLAUDE.md/SKELETON/index.md generalized. Validation-record references (Protectli/Meraki) kept deliberately. See decisions.md pivot entry.
- [x] docs/deployment-guide.md rewritten (done 2026-07-23, user-requested): dynavlan-only deployment guide (install/configure/first-run/operation/removal); Domotz-on-Ubuntu runbook removed (survives in git history at bed1d35 + the internal runbook). Cross-refs fixed in CLAUDE.md, README, PRD §2, IMPLEMENTATION-SPEC, SKELETON. See decisions.md entry.
- [x] dev/CODEMAP.md rewritten for dynavlan (done 2026-07-23, user-requested): per-function one-liners grouped by script section (pure helpers w/ test refs, seam, health, backups, gates, modes) + non-script artifacts table. CLAUDE.md Development-Workflow "not yet implemented" staleness fixed in the same pass. Both dev/ docs now current.

## Open items (off critical path - see context/open_questions.md)
- [ ] Strip the bogus `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer from this
      session's commits (2803e89..7e52fd5, the 2026-07-25/27 run). Wrong on two counts: the model was
      Opus, not Fable, and the trailer should not name a model at all (correct form is plain
      `Co-Authored-By: Claude <noreply@anthropic.com>`). Commit CONTENT is accurate; only the attribution
      line is wrong. Fix is a history rewrite + force-push of main, so ORDER MATTERS: do the Domotz-docs
      extraction from git history FIRST (git show bed1d35:... per the note below), THEN rewrite. Sequence:
      `git rebase` or `git filter-branch` over 2803e89..HEAD editing the trailer, then force-push.
- [ ] Automatic config-drift detection - DEFERRED 2026-07-25 until a second box exists.
      SCOPE RULE SET BY THE OPERATOR: dynavlan is installed on ONE box (the test appliance at
      192.168.101.39, locally accessible). Fleet is THEORETICAL until the operator says otherwise.
      The whole trigger-policy debate (should an upgrade cause unattended applies across many boxes
      within one timer interval?) was weighing a risk that does not exist yet, so per "smallest thing
      that works", automatic drift detection is NOT being built. Only the manual `--reapply` is.
      Deferred pieces, already designed and reviewed so this is cheap to resume:
        - drift detection on --rescan (the 288/day unattended path) and on --boot
        - the header-vs-content hybrid. The header check existed ONLY to make the frequent rescan
          path cheap; with no rescan check there is no cost argument, and content comparison is
          strictly more correct (it catches a config-driven change like toggling VLAN_ROUTES, which
          the header cannot see, and cannot be fooled by an input nobody remembered to fingerprint)
        - downgrade detection as a DECISION input (drift is direction-blind: an older build over a
          newer one would rewrite the file backwards). Currently just a log line.
        - install.sh performing its own drift check and printing the remedy
        - a REAPPLY_ON_DRIFT config key (rejected on YAGNI + it splits fleet behavior)
      REJECTED for this purpose: md5 of the file (detects hand-edits only, cannot see that what we
      WOULD write differs) and hashing generation INPUTS (cheap, but a forgotten input is a SILENT
      false negative - the exact failure mode behind this session's six defects; comparing the
      artifact cannot forget an input).
      WHEN RESUMING: the reviewed design is in the architect + silent-failure-hunter findings
      recorded against FR-39; the key correction to the first draft was that "unattended applies are
      a surprise" is a WRONG argument (do_rescan already applies unattended when a VLAN appears).
      The real argument is common-mode correlation plus the health check's blindness: FR-18 watches
      only the lowest-metric IPv4 default, so a generated-config change that kills VLAN monitoring
      or installs an IPv6 default PASSES health and gets ACCEPTED.
- [ ] Git hooks to enforce the version gate mechanically (proposed 2026-07-25, not built).
      WHY: the FR-38 "Version and build identity" gate in CLAUDE.md is currently enforced only by
      remembering to follow it. That is the same class of weakness that produced this session's defects.
      NOTE the split, it changes what needs enforcing:
        - `build` is NEVER committed by design (stays `build="source"` in the repo; install.sh stamps it
          at install time). Nothing to check pre-commit; what matters is that the `^build=` line stays
          stampable, and tests/unit.sh 1l already pins that.
        - `ver` is the manual one, and the only thing needing a commit-time gate.
      NOT a Claude Code PreToolUse hook: that binds only this agent in this harness, so a hand commit,
      another tool, or a session without the hook loaded bypasses it silently. A git hook binds every
      path into the repo, and composes with the environment's existing block on bypassing hooks.
      PLAN: commit `hooks/` to the repo, wired with `git config core.hooksPath hooks`.
        1. `pre-commit`: run `bash tests/unit.sh`, block on failure (catches a broken ^build= contract
           via 1l, plus every other regression, before it lands).
        2. `commit-msg`: if `dynavlan` is in the staged diff but its `ver=` line is unchanged, require an
           explicit `ver-unchanged: <reason>` line in the message. Turns CLAUDE.md's "state it on the
           record" from a request into a condition; a real bump satisfies it silently.
      KNOWN WEAKNESS: core.hooksPath must be set once per clone, so a fresh clone starts unprotected.
      Mitigate with an assert in tests/unit.sh that fails (or at minimum warns) when it is unset - the
      suite then enforces its own enforcement.
      ACCEPTANCE: each hook must be observed BLOCKING a real violating commit before it is called done.
      A guard nobody has watched fail is not a guard (the 1l lesson).
- [ ] IPv6 arm for the health check (deferred from FR-14a, 2026-07-25). `default_routes_tokens` runs
      `ip route show default` with no `-6`, so it cannot see an IPv6 default route at all. Safe today
      only because FR-14a bars VLANs from installing one; the PRD's FR-18 dependency clause now REQUIRES
      this arm to land in the same change as any future IPv6 route acceptance. Deliberately not bundled
      with the accept-ra fix: it touches the safety-critical rollback primitive.
- [ ] Audit the remaining stated guarantees against live platform state, the way FR-14a was found.
      Six defects in two days, every one a documented guarantee never confronted with the platform.
      Named suspects still unchecked: the journald drop-in (FR-31), dynavlan.service ordering vs
      networkd, and the `netplan try` capability probe.
- [x] IR-1: minimum netplan version (resolved 2026-07-23, user-approved) - keep pinned at 0.106 (validated floor). See decisions.md / open_questions.md IR-1.
- [ ] G-4: per-VLAN MAC derivation function (only if PER_VLAN_MAC enabled; default off).
- [ ] Non-Meraki switch detection (post-v0.1 future) - LLDP VLAN-table advertisement varies by vendor; sniff-primary proven only on Meraki; low-traffic VLANs invisible to sniff regardless of vendor. See open_questions.md "non-Meraki switches".

## Docs
- [x] README generalized for v0.1.0 pre-release (done 2026-07-23) - repositioned around vendor-agnostic dynamic VLAN discovery + service-restart integration; Domotz/Protectli demoted to reference deployment; pre-release/initial-testing banner added. See decisions.md 2026-07-23 README entry.

- [x] Review round 5 (done 2026-07-25) - FIRST review since hardware; three parallel reviewers over the
      268 unreviewed script lines (code / bash-correctness / security). No CRITICAL, no HIGH from the
      reviewers. One MEDIUM raised to HIGH on evidence and fixed (`lldp_tagged_vlans` key-shape matching:
      loose patterns both rebuilt the dead native-VLAN interface AND leaked a foreign key's value as a
      VLAN candidate). Four LOW fixed. 96/96 asserts. See decisions.md round-5 entry.

### FR-38 lesson (2026-07-25) - the one that changed the workflow

A deployed fix looked like it had failed. It had never been installed: the deploy landed in the
two-minute gap between two edits, so the box ran a tree with one change and not the other. Nothing on
the box could tell "present and ineffective" apart from "absent", and the wrong branch was taken. The
correction came only from noticing that the netplan file dynavlan writes ITSELF lacked the key.

Now enforced, so it cannot recur:
- `dynavlan --version` prints `<ver> (build <commit>[-dirty])`, works unprivileged and with a broken
  config, and the same string is on every `run start:` journal line (retroactive provenance).
- `install.sh` stamps the commit and WARNS when the tree is dirty.
- `tests/unit.sh` 1l pins the cross-file `^build=` contract install.sh depends on; verified to fail when
  broken. If 1l fails, fix the script, never the test.
- CLAUDE.md "Version and build identity" is a MANDATORY gate: bump `ver` or state on the record why not;
  never touch the `build=` line; run `--version` before drawing conclusions from a deploy.

The general rule, which is what the whole session keeps teaching: never infer which code is running from
whether a symptom persists. Verify the artifact, not the behavior.
