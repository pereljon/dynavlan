# decisions - decisions made and rejected

Owns: dated decisions, including options considered and turned down, with reasoning. Does NOT hold open questions (context/open_questions.md) or tasks (context/todo.md).
Maintain: append-only; never rewrite a past entry.
Entry format:
## YYYY-MM-DD - <decision>
Why: <reasoning>
Rejected: <option turned down, if any>

## 2026-07-14 - Deployment procedure captured from the internal deployment runbook
Why: the internal deployment runbook is the source of truth for the Protectli/Ubuntu Domotz provisioning runbook; captured here as docs/deployment-guide.md so it's versioned and can drift-check against the live internal runbook.
Rejected: n/a

## 2026-07-14 - New sub-project: dynavlan (dynamic VLAN auto-configuration)
Why: Static netplan with hardcoded VLANs requires internal users to edit YAML or SSH in to run a wizard, which is untrusted and does not scale as deployments move off a single standardized baseline. dynavlan is a self-configuring, company-agnostic tool that discovers active VLANs at boot and every 5 min and brings them up with DHCP, zero SSH, zero YAML editing in the common case.
Rejected: (a) Ubuntu/netplan built-in dynamic VLAN detection - does not exist, VLANs must be statically declared. (b) Domotz "assisted configuration" scripts (network_config.sh, add_vlans.sh) - interactive wizards only, no auto-detection, hardcode a single netplan path and rewrite it destructively, no DHCP option for VLANs. (c) `apt install vlan` + vconfig - legacy, netplan needs none of it. (d) Pentest VLAN-discovery tools (PyScanVLAN, 802.1q_network_scanner) - not built for unattended production DHCP provisioning.

## 2026-07-14 - dynavlan design locked (naming, detection, config schema, behavior)
Why: Full design agreed in planning session. Naming: project `dynavlan` (GitHub-clean: 0 exact repo matches, vs autovlan/vplan crowded, dynaplan squatted); generated netplan file `90-dynavlan.yaml`; config `/etc/dynavlan.conf`; script `/usr/local/sbin/dynavlan`; units `dynavlan.service` + `dynavlan.timer`.
Design invariants locked:
- Base netplan config is never read for assumptions nor modified; dynavlan owns ONLY 90-dynavlan.yaml. Makes it company/hardware-agnostic.
- Physical interfaces discovered dynamically (/sys/class/net, device symlink + type==1, exclude lo/wireless/VLAN), never hardcoded names. Trunk discovered by evidence: sniff every physical port for tagged frames; port carrying tags is the trunk; if multiple, port with most distinct tags wins, others logged/ignored.
- Detection = union of passive 802.1Q sniff (switch-agnostic) and lldpctl VLAN TLV (deterministic when advertised), controlled by DETECT_METHOD (both|lldp|sniff, default both).
- Candidates = detected ∩ [VLAN_MIN,VLAN_MAX] − (VLANs defined in any OTHER netplan file, matched by ID not interface) − (already in our file). External/base netplan VLANs are authoritative; excluded by ID to avoid key collisions and duplicate-subnet. Source of "defined elsewhere": `netplan get network.vlans` minus our own file. Warn on overlap between our file and an external file.
- Generated VLANs: dhcp4 true, use-default-routes false (untagged uplink from base config is the only default route).
- Safety: validate with `netplan generate` + backup before every apply; roll back on failure (headless box, no SSH recovery).
- Change-gated side effects: only a genuinely new/changed VLAN set triggers apply + restarts. Order: apply -> DHCP leases settle -> restart RESTART_SNAPS -> restart RESTART_SERVICES. Missing/failing entry logged, does not abort the rest. Steady state = zero applies, zero restarts.
- Persistence: generated 90-dynavlan.yaml IS the known-set (no separate state file). Add-only on the 5-min rescan (never remove, immune to idle-VLAN sniff misses). Boot = full reconcile to freshly-detected set (adds AND removes stale/relocated VLANs) done in a single reconcile pass (no destructive wipe-then-reapply), so an unchanged site reboot causes zero churn. RESET_ON_BOOT default true; false = add-only across boots, removal only by reimage.
- Config file `/etc/dynavlan.conf` shipped with all keys commented (built-in defaults apply untouched): DETECT_METHOD=both, VLAN_MIN=1, VLAN_MAX=1000 (valid 802.1Q range is 1-4094; 0/4095 reserved), SNIFF_SECONDS=60, RESCAN_MINUTES=5, RESET_ON_BOOT=true, RESTART_SNAPS="domotzpro-agent-publicstore", RESTART_SERVICES="". Invalid values are rejected (script refuses to run) rather than silently defaulted.
Rejected: hardcoded enp1s0 trunk (fails on other Protectli NIC naming); reconcile (drop-unseen) on rescan (tears down idle VLANs Domotz monitors); naming the netplan file after Domotz (tool is now vendor-agnostic); RESET_ON_BOOT=false as default (leaves ghost VLANs after relocation, no self-heal without SSH).

## 2026-07-14 - dynavlan logging and operational hardening locked
Why: Box is headless with no expected SSH access, so logging is the only forensic window and several operational gaps need closing before build.
- Logging: sink is systemd journal via stderr, syslog identifier `dynavlan` (journalctl -u / -t). Optional rotated /var/log/dynavlan.log. LOG_LEVEL config knob (debug|info|notice|warning|err, default info). Every run logs a start and end line so silent failure shows as a missing end line. State-change events at notice: VLAN discovered (ID/interface/method), VLAN removed on boot reconcile (ID+reason), netplan applied, each snap/service restarted, boot reconcile summary, reset event. info: run start (boot vs rescan, effective config), interfaces discovered, trunk selected, scan start/end, candidates vs known, no-change, leases acquired. warning: VLAN excluded (defined in other netplan file + which), our/external overlap, restart entry missing/failed, VLAN got no lease in settle window, VLAN count over sane threshold. err: invalid config (refuse run), no trunk, netplan validate fail, apply fail+rollback, tcpdump/lldpctl missing.
- Backup retention: BACKUP_KEEP config (default 10); prune oldest beyond it. Backups double as change-history audit trail. Fixes unbounded .bakN growth from Domotz's scripts.
- Concurrency: each invocation wrapped in flock; overlapping run logs "skipped, run in progress" and exits. Prevents colliding netplan applies from timer stacking on a slow run.
- One script, two modes: `dynavlan --boot` (full reconcile) from dynavlan.service, `dynavlan --rescan` (add-only) from dynavlan.timer.
- Boot ordering: service orders After=systemd-networkd.service, does NOT hard-block on network-online.target (sniff needs link-up not an IP, and script brings links up itself); lease-settle wait precedes snap/service restarts since Domotz needs networking up.
- Dependency: `tcpdump` added to deployment package list (sniff needs it; not currently installed).
- Scale guard: warn-and-proceed threshold when about to create an unusually large number of VLANs (misconfigured wide VLAN_MAX on a many-VLAN trunk).
- Privacy: logs contain client VLAN IDs and subnet addresses (client network topology under confidentiality obligations). Logs stay local; nothing ships them off-box without a deliberate decision.
- Conventions: VLAN interfaces named `<iface>.<id>` (e.g. enp1s0.20); networkd renderer inherited from base, never re-declared.
Config additions: LOG_LEVEL=info, BACKUP_KEEP=10 (both commented defaults in /etc/dynavlan.conf).
Rejected: unbounded backups; journald-only with no file option (kept file optional); blocking on network-online.target (would stall a no-uplink boot).

## 2026-07-14 - dynavlan is filename-agnostic; discovery vs exclusion sources locked
Why: Base netplan filenames vary and cannot be relied on (verified on the lab box: enp1s0 defined across BOTH 00-installer-config.yaml and 01-netcfg.yaml). dynavlan must hardcode exactly ONE path: its own /etc/netplan/90-dynavlan.yaml. Everything else is discovered, never read by base filename.
- Physical interface + trunk discovery: LIVE Linux state only (/sys/class/net + ip link for interfaces; sniff for trunk). Never reads netplan. Works even if base config is missing or names nothing.
- VLAN exclusion set (VLANs to skip because managed elsewhere) = union of two filename-agnostic sources, minus dynavlan's own IDs:
  (a) PRIMARY: `netplan get network.vlans` - merges ALL /etc/netplan/*.yaml regardless of name; this is the netplan layer's own answer and the collision we avoid (two files defining same vlan) is a netplan-layer problem. Verified working on live box across the split base files.
  (b) SAFETY NET: `ip -d link show type vlan` (extract `802.1Q id N`) - catches VLANs created OUTSIDE netplan (raw ip link, other tools, other renderer .netdev) that netplan get would miss (architect M3).
- Exclusion matched by numeric VLAN ID, not interface name. candidates = detected ∩ [VLAN_MIN,VLAN_MAX] − exclusion − our-own-IDs.
- Consequence: a VLAN declared in netplan but not yet instantiated is still excluded (via netplan get); a VLAN instantiated outside netplan is still excluded (via ip link). Belt-and-suspenders that makes "leave everything else alone" actually hold.
Verified 2026-07-14: on the lab box both sources returned identical {1,21,22,101}; live sniff additionally discovered unconfigured VLAN 18 on the trunk.
Rejected: reading/globbing base YAML files by name (fragile); using only netplan get (misses non-netplan VLANs); using only live ip link (misses not-yet-applied netplan VLANs, and can't tell configured from ad-hoc).

## 2026-07-14 - dynavlan netplan behaviors validated on live box (C1 + VLAN stanza + removal)
Why: End-to-end test on the lab box (Domotz agent unlinked) exercised dynavlan's exact apply path and surfaced two non-obvious netplan/networkd behaviors that change the design.
1. APPLY PATH VALIDATED: write /etc/netplan/90-dynavlan.yaml (mode 600, root:root) -> `netplan generate` (validates, exit 0) -> `netplan try --timeout N` fed by a health-gated stdin -> health check (default route still via base uplink) -> printf newline to ACCEPT, else let it revert. Added VLAN 18 (enp1s0.18) which came up with a DHCP lease and NO default route. Confirmed headless/no-TTY.
2. CORRECT ISOLATION KEYS: the netplan key is `use-routes: false` (NOT `use-default-routes`, which is not a netplan key). But use-routes:false alone still leaves networkd installing link-scope host routes for DHCP-provided DNS/NTP servers - observed public OpenDNS IPs (208.67.220.220/.222) and stray /32s pinned to the VLAN interface. Under confidentiality obligations that means the monitor could resolve via a site VLAN's DNS or pin public IPs to the wrong interface. FULL isolation stanza (validated: interface then has ONLY its connected subnet route):
   dhcp4: true
   dhcp4-overrides: { use-routes: false, use-dns: false, use-ntp: false, use-domains: false }
   dynavlan VLAN stanzas MUST include all four.
3. VLAN REMOVAL REQUIRES EXPLICIT `ip link delete`: removing a VLAN's stanza from netplan and running `netplan apply` does NOT remove the live interface - networkd leaves the orphaned VLAN device UP (still had its lease) until reboot. Confirmed: after rm + netplan apply, enp1s0.18 was still up; only `ip link delete enp1s0.18` removed it. CONSEQUENCE: dynavlan's boot reconcile (FR-18) and relocation self-heal (AC-3) must, for each VLAN being removed, both drop it from 90-dynavlan.yaml AND explicitly `ip link delete <iface>.<id>`. netplan apply alone is insufficient for removal.
Also noted: netplan warns "Permissions too open" on world-readable base files (00-installer is 644); dynavlan's own file is 600 so it won't trigger this. `netplan try` accept/revert both work over SSH with no TTY (drive accept via fifo/coproc at build time).
Rejected: use-routes:false as the sole isolation key (leaks DNS/NTP host routes); relying on netplan apply to remove VLAN interfaces (leaves orphans).

## 2026-07-14 - dynavlan VLAN_IGNORE denylist added (no allowlist)
Why: Original "take all, disable unwanted at the switch port" assumes we control the trunk. Post-standardization, on site-managed switches we often won't, so an in-config denylist is needed to keep the monitor off specific VLANs (guest/voice/contractually-off-limits segments) even when they're trunked and detected.
- New config key: `VLAN_IGNORE=""` (commented default empty = take-all preserved). FORMAT: list-with-ranges, separators are comma and/or whitespace, ranges via `low-high` inclusive. Example `"1,5,20-25,80,30"` -> set {1,5,20,21,22,23,24,25,30,80}. Parsed as a set (order-independent, duplicates/overlaps collapse). Validation: each ID 1-4094, range low<=high, reject non-numeric/malformed -> refuse to run + log err. Ignoring an ID outside [VLAN_MIN,VLAN_MAX] is a harmless no-op. VLAN_MIN/VLAN_MAX stay single integers (no list syntax).
- Precedence: ignore ALWAYS wins. candidates = detected ∩ [VLAN_MIN,VLAN_MAX] − VLAN_IGNORE − (managed in other netplan files) − (our own IDs).
- Composes with VLAN_MIN=2 default (range handles VLAN 1; VLAN_IGNORE handles specific IDs).
Rejected: allowlist / VLAN_ALLOW whitelist mode - defeats the auto-discovery purpose (back to declaring VLANs by hand); user chose denylist only.

## 2026-07-14 - dynavlan PRD v3: apply/rollback sequencing + two approved decisions
Why: Second architect review of PRD v2 found the design sound but the apply/rollback/removal SEQUENCING under-specified (4 CRITICAL paper-closable gaps). PRD v3 (docs/dynavlan-PRD.md) closes them. Note: VLAN_MIN default is 2 (PRD authoritative); the earlier "design locked" entry line saying VLAN_MIN=1 is SUPERSEDED.
Sequencing decisions locked in v3:
- FR-18 health check: SNAPSHOT the pre-apply default route (iface+gw+metric) as the reference (dynavlan never reads base config, so this is its only notion of "the base uplink"); revert gate = default route still egresses the snapshot interface; gateway reachability is secondary/non-fatal and L2/ARP not ICMP (HNW sites filter ICMP -> false reverts); invariant netplan-try-timeout > max-health-check + margin; VLAN lease failures NEVER revert.
- FR-30 flock: held on an OPEN FD (kernel-released on death), never a manual lockfile - else a mid-try death permanently freezes the tool in "skipped, run in progress".
- FR-24 removal ordering: explicit `ip link delete` ONLY after netplan try ACCEPT, never before, never on revert - else the validated orphan behavior silently loses monitoring when a change reverts.
- FR-0 startup: capability-probe netplan try + pinned min netplan version; refuse to run if unavailable; NO silent fallback to bare netplan apply (would drop the revert safety net).
- FR-22/23: boot ADD is single-pass; boot REMOVE requires two passes within the same --boot run (sniff, BOOT_SETTLE_SECONDS, sniff); rescan stays strictly add-only.
- FR-27: a reverted apply does no lease-settle and no restarts.
APPROVED DECISIONS: (1) Minimum netplan version pinned to Ubuntu 22.04 baseline (netplan 0.106), the validated version. (2) PER_VLAN_MAC default OFF (shared parent MAC validated working on lab box; derivation has bit-flip/collision footguns) - kept as opt-in insurance only.
Also in v3: FR-10 re-tagged HIGH/CONTINUITY (dup key caught by netplan generate, doesn't strand); refuse-to-run if sniff requested but tcpdump absent; mandatory install-verified log persistence; minimal-snaplen sniff w/ no on-disk capture (confidentiality-sensitive); promisc left on deliberately; distinct err "our YAML bad" vs "base file bad"; fifo/coproc try-accept promoted to FR w/ SIGPIPE + wall-clock guard; AC-10 second untagged NIC never selected as trunk; AC-11 reverted change leaves no deleted interfaces.
Rejected: silent fallback to netplan apply when netplan try absent; ICMP-based health check; manual lockfile; deleting interfaces before accept; PER_VLAN_MAC default-on.

## 2026-07-14 - dynavlan implementation decisions + portability seam (dev/features/dynavlan.md)
Why: Wrote the technical design doc bridging PRD v3.1 to code. Locked implementation-level decisions.
- Language: bash (zero-dependency, cross-distro at the shell level, natural for netplan/ip/tcpdump/lldpctl orchestration; concurrency footguns contained in the flock/fifo functions).
- Timer interval: static systemd timer + a `.d/interval.conf` drop-in rendered from RESCAN_MINUTES by `dynavlan --reconfigure` (also at install) + daemon-reload; runtime RESCAN_MINUTES edits need a re-run. Avoids self-rescheduling loop / long-running daemon.
- Two-pass boot removal state: in-process within the single --boot run (detect, sleep BOOT_SETTLE_SECONDS, detect; remove only VLANs absent from both). No persistence; rescan stays strictly add-only.
- PORTABILITY SEAM (pre-planned for future Linux flavors, structure-only, not built): core logic is distro-agnostic (interface discovery, sniff/lldp, filter/exclude, health-check eval, logging). All netplan-coupled code isolated behind a 6-operation backend seam: list_managed_vlans, owned_vlans, generate_config, validate, apply_with_revert, remove_vlan. netplan is the ONLY implementation now. Ownership stated abstractly ("own a VLAN-definition namespace, exclude others"). backend_detect stub resolves only to netplan. apply_with_revert is a CAPABILITY contract ("apply with health-gated auto-revert"), not netplan-specific - the one genuinely hard portability item since revert varies: netplan try / NetworkManager native checkpoints (cleaner) / systemd-networkd-direct + ifupdown (hand-rolled, none).
Rejected: building multiple backends now (speculative); plugin loader / backend-selection config (until backend #2 real); non-systemd init support (systemd assumed for service/timer/journald); python (interpreter-version coupling hurts the portability goal).
