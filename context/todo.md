# todo - outstanding tasks and their state

Owns: open tasks and their status. Does NOT hold permanent facts or decisions (those live in dev/ docs and context/decisions.md).
Maintain: update whenever a task is added, changes state, or completes.
Entry format: `- [ ] task`  /  done: `- [x] task (done YYYY-MM-DD)`

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

## Hardware session 2026-07-25 (first real runs on the box) - live state

Box: `ssh -i ~/.ssh/domotz m18admin@192.168.101.39` (root via sudo). Ubuntu 22.04, kernel 5.15.0-177,
netplan.io 0.107.1-3ubuntu0.22.04.4. NICs: enp1s0 (trunk, carrier up), enp2s0 (no carrier).
Installed: /usr/local/sbin/dynavlan at commit 2803e89 (ALL FOUR code fixes: FR-0, FR-7a, FR-21a, FR-5a).
/etc/dynavlan.conf: all keys commented = DEFAULTS, except RESTART_SNAPS if the user ran the sed one-liner
(unverified at handoff - CHECK `grep ^RESTART_SNAPS /etc/dynavlan.conf` before assuming either way).
APPLIED: /etc/netplan/90-dynavlan.yaml owns [18 21 22 100 101]. /etc/netplan also holds
00-installer-config.yaml + 01-netcfg.yaml (both ethernets-only; no vlans anywhere but our file).
Timer HEALTHY and chaining: 5-min interval, LAST 02:37:01 / NEXT 02:42:01 box time.
Live: enp1s0.18 -> 192.168.18.6, .21 -> 192.168.21.39, .22 -> 192.168.22.39, .101 -> 192.168.101.39
(the SSH path), .100 -> link-local ONLY (dead, pending removal). One default route: enp1s0 metric 10.

**The single next action: deploy the two UNCOMMITTED/UNDEPLOYED changes below, then `sudo dynavlan --boot`.**
The box is still at 2803e89 and does NOT yet have either of them:
  1. VLAN_MIN default 2 -> 1, so VLAN 1 (192.168.255.0/24, tagged and live on this trunk) is finally a
     candidate. /etc/dynavlan.conf has VLAN_MIN commented, so the new default applies with no config edit.
  2. FR-14a `accept-ra: false` on every VLAN.
After deploying, `--boot` should show additions [1] AND removals [100] in one apply. That run exercises
L3-7 (post-accept ip link delete), L3-13b (FR-7a on the wire), L3-25 (FR-5a removal) and L3-26 (FR-14a)
at once, and - if RESTART_SNAPS got set - fires the first real agent restart. It is also the FIRST time
the removal path and `ip link delete` will ever have run. Preview with --dry-run first: it doubles as
proof that netplan 0.107 accepts the `accept-ra` key (backend_validate runs `netplan generate` in a
throwaway tree), which is UNVERIFIED from the dev box. Takes ~4 min (two detection passes, each paying
the full 30s carrier wait on the dead enp2s0 plus a 60s sniff).

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
