# dynavlan - Product Requirements Document (v3.3)

Status: Draft v3.3, design-locked and hardware-validated 2026-07-14; implemented 2026-07-21..23 with three review rounds folded in. Not yet released.

### Changes from v3.2
NEW FR-37 (`VLAN_ROUTES`/`VLAN_ROUTE_METRIC_START`/`VLAN_ROUTE_METRIC_MODE`): opt-in routed mode - accept DHCP routes on discovered VLANs at per-VLAN metrics (discovery-order or id-derived assignment, persisted in our own YAML), guarded by an up-front uplink-metric conflict refusal. NEW AC-14. Round-4 operational fixes: `restore_prior` failure is loud; `--dry-run` takes the run lock non-blocking.

### Changes from v3.1 (post-implementation review rounds + approved feature)
FR-12: `VLAN_COUNT_WARN` renamed `VLAN_WARN`. NEW FR-36 (`VLAN_LIMIT`/`VLAN_LIMIT_MODE`): hard cap on total VLAN count, refuse-loud by default with opt-in deterministic fill. NEW AC-13 for the limit. FR-18 accept mechanism hardened after a second review round found the fifo ACCEPT race (see the requirement's accept-evidence clause): accept requires apply-completion evidence + netplan-try liveness + consecutive health passes; the FAIL path holds the fifo open so revert rides netplan's own timer. FR-19: `BACKUP_KEEP` minimum is 1 (0 could leave a revert with no disk-convergence target). Boot reconcile (FR-22/23) pins both passes to the owned parent and adds an explicit two-pass-evidence relocation branch (AC-3). Detection is bounded independent of port count (shared carrier deadline, concurrent sniffs).
Owner: IT / infrastructure team.
Supersedes: PRD v3, v2, v1 (all 2026-07-14).
Related: `context/decisions.md`, `docs/deployment-guide.md`, `context/open_questions.md`.

### Changes from v3 (folding the final architect review's non-blocking clarifications)
FR-0 capability probe specified as non-mutating; FR-18 handles the empty pre-apply snapshot case (no default route yet) and states its dependency on FR-14; FR-18 ARP reachability stated as strictly non-fatal; AC-12 added for the empty-snapshot case. No design changes; edge-precision only.

### Changes from v2 (closing the second architect review)
Apply/rollback/removal path fully sequenced: health-check now snapshots the pre-apply default route as its reference (C-1); flock specified as a held fd (C-2); `ip link delete` gated on ACCEPT (C-3); `netplan try` capability-probed with a pinned minimum version and no silent fallback (IR-1); boot reconcile stated as add=single-pass / remove=two-pass-within-boot (H-1); reverted apply does no lease-settle and no restarts (H-3). Plus: FR-10 re-tagged CONTINUITY; refuse-to-run if sniff requested but tcpdump absent; mandatory log persistence; minimal-snaplen capture; `PER_VLAN_MAC` default off; promisc left on deliberately; distinct "our YAML bad" vs "base file bad" errors; fifo-drive promoted to an FR; AC for the second untagged NIC.

## 0. Reading this document

### 0.1 Severity scale (requirements, risks, findings)

| Severity | Meaning |
|----------|---------|
| CRITICAL | Can strand a headless box (break the uplink, wipe needed state, silently no-op the whole tool). Close before ship. |
| HIGH | Degrades correctness or monitoring, but self-heals or does not strand the box. |
| MEDIUM | Maintainability, operability, or edge-case correctness. |
| LOW | Cosmetic, or rare/low-impact. |

### 0.2 Impact axis (blast radius)

| Impact tag | Blast radius if violated |
|------------|--------------------------|
| RECOVERABILITY | Box could lose its uplink / become unreachable with no remote recovery. Weighted highest (headless, no-SSH). |
| CONTINUITY | Monitoring interrupted or wrong, but box reachable and condition self-heals. |
| DETERMINISM | Edge-case/cosmetic correctness; no connectivity or monitoring loss. |

Severity and impact are independent: a CONTINUITY item can be CRITICAL severity. Map findings onto this scale.

## 1. Summary

dynavlan is a self-configuring VLAN provisioning tool for netplan/systemd-networkd Linux boxes (hardware- and vendor-agnostic; validated on a Protectli/igb appliance). It discovers the active tagged VLANs on whatever trunk the box is plugged into, brings each up with DHCP via netplan (address only, fully route/DNS-isolated by default), and restarts the nominated snaps/services so an interface-enumerating agent picks up the new subnets. It runs at boot and on a timer, with no human editing YAML and no SSH.

## 2. Problem

Static netplan with hand-declared VLAN IDs fails three ways: per-site VLAN schemes require hand-editing netplan on a headless box (confirmed live: the lab box carries 1/21/22/101, not the template's set); vendor-assisted configuration scripts still need SSH and a per-box wizard and destructively rewrite one shared file; neither approach scales across sites and mixed hardware. No built-in netplan mechanism does dynamic discovery.

## 3. Goals

- Zero-touch: freshly imaged box on any trunk self-configures its VLANs, no SSH, no YAML editing in the common case.
- Company/hardware-agnostic: no assumptions about interface names, native VLAN, base config contents, base netplan filenames, or switch vendor.
- Self-healing: adapts to VLANs added at runtime and to relocation/decommissioning across reboots, without intervention.
- Safe on a headless box: never leaves the appliance without a working uplink (RECOVERABILITY dominates).
- Observable: a durable log trail, since the box is not meant to be logged into.
- Vendor-neutral: restarts a configurable set of snaps/services on change, not Domotz specifically.
- Privacy-preserving: a monitored VLAN contributes only subnet reachability, never DNS/NTP/gateway/default-route pollution.

## 4. Non-Goals

- Managing base connectivity/uplink (owned by the image/installer; dynavlan never modifies base netplan files).
- Static IPs on VLANs (DHCP-only, address-only).
- Configuring switches (reads only; unwanted VLANs excluded via config, or disabled at the port by the operator).
- Detecting VLANs with zero live traffic AND no LLDP advertisement (fundamental limit; mitigated).
- GUI or remote management plane.

## 5. Users

- Primary: IT staff imaging/deploying appliances without per-box networking expertise.
- Secondary: support staff diagnosing a deployed box from logs and `--status`.
- Tertiary: third-party operators on their own hardware/stack.

## 6. Deltas from the static manual approach (and why)

| Static manual netplan | dynavlan | Why |
|-----------------------|----------|-----|
| VLANs hand-declared in a base netplan file | Auto-discovered into `90-dynavlan.yaml` | Zero-touch, site-agnostic. |
| Every VLAN gets a default route (metrics 10/20/100...) | VLANs get NO default route (`use-routes: false`) | Monitoring box needs only subnet reachability; untagged uplink is sole default route. |
| VLAN DHCP brings DNS/NTP/routes | Address only (`use-dns/use-ntp/use-domains/use-routes` all false) | Prevents each site VLAN polluting the monitor's routing/resolver (confidentiality-sensitive). Validated: without these, public OpenDNS pinned as host routes. |
| Single `enp1s0` assumed | Interfaces + trunk discovered from live kernel state | Different hardware names NICs differently. |
| Fixed VLAN set | Range + ignore-list bounded discovery | Sites vary; some VLANs must be excluded even when trunked. |

## 7. Functional Requirements

Each FR carries [SEVERITY / IMPACT].

### 7.1 Startup and preconditions
- FR-0 [CRITICAL / RECOVERABILITY]: On every invocation, before any change, verify preconditions and refuse to run (log `err`, exit non-zero, change nothing) if any fail: (a) running as root; (b) `netplan` present and version >= the pinned minimum (0.106, Ubuntu 22.04 baseline) with a working `netplan try` (capability probe); (c) config file parses and all values valid (FR-9, FR-6); (d) if `DETECT_METHOD` includes sniff, `tcpdump` present; if it includes lldp, `lldpctl` present. There is NO silent fallback from `netplan try` to bare `netplan apply` (that would remove the revert safety net); absence of a usable `netplan try` is a refuse-to-run condition. The capability probe MUST be non-mutating: version/subcommand introspection only (e.g. `netplan try --help`), never a live apply-cycle. Version discovery MUST NOT assume `netplan --version` exists: that flag arrived in netplan 1.0 and the validated 22.04 baseline (netplan 0.10x) rejects it, so discovery falls back to the package database (`dpkg-query -W netplan.io`). A version that cannot be determined is its own refuse-to-run condition, logged distinctly from "version below the minimum" so an operator can tell a broken probe from a genuinely old netplan.

### 7.2 Interface and trunk discovery
- FR-1 [HIGH / CONTINUITY]: Discover physical Ethernet interfaces from live kernel state (`/sys/class/net` + `ip link`): keep entries with a real `device` symlink and `type==1`, exclude loopback, wireless, and VLAN sub-interfaces. Never hardcode names; never read netplan for discovery.
- FR-2 [HIGH / CONTINUITY]: Before sniffing, set the candidate physical interface administratively up and to promiscuous mode (`ip link set <iface> promisc on`), then wait for carrier up to `CARRIER_WAIT_SECONDS`. Promiscuous mode is mandatory: it makes the NIC hardware VLAN filter transparent so unconfigured VLANs are visible (validated: sniff saw unconfigured VLAN 18 despite `rx-vlan-filter: on [fixed]`). Promiscuous mode is left ON deliberately after the run (clearing it risks dropping frames and it is already set by the monitoring agent in steady state); this is an intentional posture, not an oversight.
- FR-3 [HIGH / CONTINUITY]: Identify the trunk by evidence: a physical interface carrying 802.1Q-tagged frames and/or advertising VLANs via LLDP is a trunk. LLDP presence counts as trunk evidence even if the sniff window is quiet. An interface with carrier but no tags and no LLDP VLANs (e.g. a second untagged NIC) is NOT a trunk and is left alone.
- FR-4 [MEDIUM / DETERMINISM]: If more than one interface carries tags, select the one with the most distinct VLAN IDs, with stickiness/hysteresis so the selection does not flap between rescans. Log non-selected trunks; build VLANs only on the selected one.

### 7.3 VLAN detection
- FR-5 [HIGH / CONTINUITY]: Support `DETECT_METHOD` = `sniff` | `lldp` | `both` (default `both`). `sniff` = passive 802.1Q capture bounded by `SNIFF_SECONDS`, using a minimal snaplen sufficient only to read the VLAN tag and never writing captured frames to disk (privacy hygiene). `lldp` = `lldpctl`.
- FR-5a [HIGH / CONTINUITY]: The sniff MUST capture INBOUND frames only (`tcpdump -Q in`). Packet capture sees egress as well as ingress, and every VLAN dynavlan owns transmits tagged DHCP on the parent interface (DISCOVER retries indefinitely if it never leases; renewals if it did). Counting those frames makes detection self-fulfilling: an owned VLAN is permanently "detected" on its own evidence, so FR-23 removal can never fire - not for a VLAN created in error, and not for one the switch has genuinely stopped trunking. Only frames the switch delivers are evidence of what the trunk carries. Absence of `-Q` support is a refuse-to-run condition (FR-0), never a silent fallback to bidirectional capture. Validated failure (2026-07-25): a dead `enp1s0.100` sustained its own detection across reboots - 1 outbound VID-100 DHCP Request from the box's own MAC in a 75s window, 0 inbound.
- FR-6 [MEDIUM / DETERMINISM]: Reject an invalid `DETECT_METHOD` (refuse to run, per FR-0).
- FR-7 [MEDIUM / DETERMINISM]: `lldp` alone is insufficient where a switch advertises only the native/pvid VLAN (validated: Meraki MS130 advertised only pvid 100). `both` protects against this and is the default.
- FR-7a [HIGH / CONTINUITY]: LLDP MUST NOT contribute a VLAN it flags as the native/pvid VLAN (`pvid=yes`). The native VLAN is untagged on the wire, so an interface carrying its tag can never receive a frame: it comes up, never acquires a lease, and remains dead while re-warning on every rescan (validated 2026-07-25: LLDP advertised pvid 100, dynavlan built `enp1s0.100`, no lease in 30s). The native VLAN MUST be discovered from the advertisement, never configured by hand - requiring an operator to list it in `VLAN_IGNORE` per site reintroduces exactly the manual step this tool exists to remove. The exclusion is scoped to the LLDP source only: if the sniff independently observes tagged frames for that ID, the VLAN is genuinely tagged and remains a candidate.

### 7.4 Filtering and exclusion
- FR-8 [HIGH / CONTINUITY]: Consider only IDs within `[VLAN_MIN, VLAN_MAX]` (defaults 1-1000; valid range 1-4094). The default min is 1: VLAN 1 is frequently a real, tagged, DHCP-serving VLAN rather than switch management (validated 2026-07-25: a Meraki trunk carried VLAN 1 tagged as `192.168.255.0/24` while the native VLAN was 100), so excluding it by default silently drops a subnet the operator wants monitored. The range is a coarse bound; `VLAN_IGNORE` (FR-9) is the mechanism for skipping specific IDs, including 1.
- FR-9 [MEDIUM / DETERMINISM]: Subtract `VLAN_IGNORE` (denylist, never configured even if detected). Format: comma/whitespace-separated IDs with `low-high` inclusive ranges (e.g. `"1,5,20-25,80"`), parsed as a set; IDs 1-4094, range low<=high, malformed refuses to run. Ignore always wins.
- FR-10 [HIGH / CONTINUITY]: Exclude any VLAN ID already managed elsewhere, by numeric ID regardless of interface name. Union of two filename-agnostic sources, minus dynavlan's own IDs: (a) `netplan get network.vlans` (merges all `/etc/netplan/*.yaml` regardless of filename; primary, because a duplicate netplan key is what a collision would break); (b) live `ip -d link show type vlan` (catches VLANs created outside netplan). Rationale for CONTINUITY (not RECOVERABILITY): a duplicate key is caught by FR-17 `netplan generate`, which refuses to apply and preserves the working file, so the failure mode is a blocked update, not a stranded box.
- FR-11 [LOW / DETERMINISM]: Warn when a dynavlan VLAN overlaps a VLAN later defined in an external file, without retracting dynavlan's entry.
- FR-12 [MEDIUM / CONTINUITY]: Warn and proceed when about to configure more than `VLAN_WARN` VLANs (renamed from `VLAN_COUNT_WARN` in v3.2); the warning notes that a wide range on a many-VLAN trunk produces a simultaneous DHCP-DISCOVER burst and recommends narrowing the range.
- FR-36 [HIGH / CONTINUITY] (v3.2): `VLAN_LIMIT` (default 64; 0 = unlimited) hard-caps the total VLAN set size (kept + additions). `VLAN_LIMIT_MODE` (default `refuse`): `refuse` = when the would-be set exceeds the limit, apply NOTHING new (existing owned VLANs keep running), log `err` naming the count, the limit, and the remedies (narrow `VLAN_MIN`/`VLAN_MAX`, extend `VLAN_IGNORE`, raise `VLAN_LIMIT`); never partial-provision. `fill` (explicit opt-in) = keep all owned VLANs, add the LOWEST-id additions into the remaining slots (deterministic across a fleet), and log a warning naming every skipped VLAN so the monitoring gap is visible, never silent. A removals-only change is ALWAYS allowed even while the set exceeds the limit (the cap gates growth; blocking a shrink would freeze an over-limit box over-limit). Rationale: over-limit detection indicates misconfiguration (range too wide, or patched into a core trunk); refuse surfaces it at deploy time (attended) instead of leaving a quiet partial gap discovered mid-incident; a too-large apply also stresses the FR-18 try-window timing assumptions.

Candidate formula: `candidates = detected ∩ [VLAN_MIN,VLAN_MAX] − VLAN_IGNORE − (managed elsewhere) − (our own)`.

### 7.5 netplan generation
- FR-13 [HIGH / RECOVERABILITY]: Own exactly one netplan file, `/etc/netplan/90-dynavlan.yaml`, mode 0600 root:root. Never read base config for assumptions nor modify any other netplan file. This is the only filename dynavlan hardcodes.
- FR-14 [HIGH / RECOVERABILITY]: Generate each VLAN as `<iface>.<id>` with the validated full-isolation stanza:
  ```
  dhcp4: true
  accept-ra: false
  dhcp4-overrides:
    use-routes: false
    use-dns: false
    use-ntp: false
    use-domains: false
  ```
  yielding address + connected subnet route only (validated). Inherit the networkd renderer; never re-declare it.
- FR-14a [HIGH / RECOVERABILITY] (v3.4): `accept-ra: false` is required on every generated VLAN and is NOT redundant with the four `use-*` keys. Those are `dhcp4-overrides` and bind DHCPv4 alone; IPv6 Router Advertisement is an independent, unsolicited channel that systemd-networkd accepts by default on a non-router link, delivering a SLAAC address, RDNSS resolvers, and a default route that no `use-*` key declines. Validated 2026-07-25: `enp1s0.22` held a global SLAAC address from a VLAN RA with every DHCPv4 decline in force. This is a RECOVERABILITY requirement, not merely confidentiality: FR-18's health check samples `ip route show default` (IPv4 only), so an RA-installed default routed through a monitored VLAN is invisible to it and can never trigger the revert - the exact uplink-hijack FR-18 exists to catch. Remains false under `VLAN_ROUTES=true`: FR-37's conflict guard reasons only about metrics it assigns, and an RA route carries a metric dynavlan never chose, bypassing the guard entirely. `link-local` is deliberately left at its netplan default (the `fe80` addresses stay); this requirement governs RA processing, not link-local addressing.
- FR-37 [HIGH / RECOVERABILITY] (v3.3): `VLAN_ROUTES` (default false) optionally accepts DHCP routes on discovered VLANs, each at a distinct per-VLAN metric; `use-dns`/`use-ntp`/`use-domains` remain false in both modes (routes only, never the resolver). When true, FR-14's stanza becomes `use-routes: true` + `route-metric: <assigned>`. Metric assignment: `VLAN_ROUTE_METRIC_START` (default 100, >= 1) and `VLAN_ROUTE_METRIC_MODE` (default `discovery`): `discovery` = existing VLANs keep their persisted metric VERBATIM forever (assignments are stored in and re-read from `90-dynavlan.yaml`, the file dynavlan already owns); new discoveries, ascending, take `max(START-1, highest existing)+1` onward, so later discoveries never renumber established priorities. `id` = stateless `metric = START + VLAN id`, identical on every box regardless of discovery history. GUARD (the recoverability clause): before any disk change, if any assigned metric is <= the pre-apply uplink default's metric, that VLAN's default would out-prioritize or tie the uplink - a guaranteed FR-18 health-FAIL revert loop - so REFUSE loudly naming the uplink metric and the remedy (raise `VLAN_ROUTE_METRIC_START`), changing nothing. FR-18's empty-snapshot stance under `VLAN_ROUTES=true`: with no pre-apply default route, a VLAN-provided default may become the uplink and health PASSes - this is intended failover behavior, documented rather than prevented. Dry-run previews the assigned map and surfaces a would-be conflict.
- FR-15 [LOW / DETERMINISM]: `PER_VLAN_MAC` (default OFF). Shared parent MAC is validated working on the lab box (distinct leases across four VLANs). When enabled, derive a per-VLAN MAC from the base MAC + VLAN ID with a defined function: set the locally-administered bit, clear multicast bit, confine VLAN-ID mixing to the low 3 bytes with defined overflow, and avoid cross-box collision on the same L2. Off by default because the derivation carries footguns and solves a problem not yet observed.
- FR-16 [CRITICAL / RECOVERABILITY]: Write `90-dynavlan.yaml` atomically: temp file in the same directory, fsync, `rename()` over the target. A mid-run kill cannot leave partial YAML (defense-in-depth behind FR-17).

### 7.6 Apply and rollback (the safety-critical sequence)
- FR-17 [CRITICAL / RECOVERABILITY]: Pre-flight validate with `netplan generate`. On failure, do not apply, log `err`, leave the prior good file in place. The error message must distinguish "dynavlan's own YAML is invalid" from "a base netplan file is invalid": since `generate` also processes base files, a pre-existing broken base file will fail this step and freeze all future dynavlan updates until the base is fixed; that condition must be logged explicitly so support is not misdirected.
- FR-18 [CRITICAL / RECOVERABILITY]: Apply via `netplan try`, driven headlessly, with a health-check-gated accept:
  1. **Snapshot** the current default route BEFORE apply: interface, gateway, and metric of the lowest-metric default route. This snapshot is the health-check reference (dynavlan does not read base config, so it has no other notion of "the base uplink"). EMPTY-SNAPSHOT case: if no default route exists at snapshot time (e.g. booted with the trunk up but the uplink DHCP not yet leased, since FR-29 does not block on `network-online.target`), the health check PASS condition becomes "post-apply state is no worse than pre-apply": PASS iff no default route was removed or redirected by the change. Because every generated VLAN carries `use-routes: false` (FR-14), the change introduces no default route, so an empty-before / empty-after result PASSES. dynavlan must never REVERT solely because the box had no uplink independently of the change.
  - Dependency: this health check is valid ONLY because FR-14/FR-14a guarantee generated VLANs install no default route by ANY channel - `use-routes: false` for DHCPv4 and `accept-ra: false` for IPv6 RA - so the snapshot and post-apply default route reflect the base uplink alone. Any future change to those isolation keys must revisit FR-18. Note the check samples IPv4 defaults only (`ip route show default`): that is sufficient precisely because FR-14a bars VLANs from installing an IPv6 default, and it stops being sufficient the moment a VLAN is allowed one. If IPv6 route acceptance is ever offered, the health check must gain an `ip -6` arm in the SAME change.
  2. Start `netplan try --timeout N` and feed its stdin via a fifo/coproc.
  3. Run the health check: PASS iff a default route still exists AND the lowest-metric default route egresses the same interface as the snapshot (compare on interface only, never metric or gateway; a spurious lower-metric default on a different interface is a FAIL). Gateway reachability is a secondary, STRICTLY non-fatal signal and, if used, is L2/ARP-based (not ICMP, which HNW sites filter and which would cause false reverts): a gateway that does not answer ARP must NOT by itself fail the check or trigger a revert. The health check must NOT block on new-VLAN DHCP lease acquisition (that is FR-27, post-accept).
  4. If PASS, write a newline to ACCEPT; if FAIL, write nothing and let the timer REVERT.
  5. VLAN-level failures NEVER trigger revert; only base-uplink default-route integrity does.
  - Invariant: `N > (max health-check duration + margin)`, so the timer cannot fire mid-check. A hard wall-clock guard independent of `netplan try`'s own timer bounds the whole interaction. The accept-write must tolerate `netplan try` having already reverted and closed the pipe (handle SIGPIPE/EPIPE without crashing). Rollback is gated on the health check, never on `netplan apply`/`try` exit code.
  - ACCEPT-EVIDENCE (v3.2, closes the fifo-ACCEPT race; hardened in round 3): `netplan try` applies BEFORE reading stdin, and a newline written early sits in the pipe buffer and is consumed unconditionally after the apply. Therefore the accept may be written only when ALL hold: (a) apply evidence - the first added VLAN's interface exists (this proves the apply BEGAN, not completed, so additionally an unconditional settle floor must have elapsed before health sampling; changes with no additions anchor on the settle floor alone); (b) `netplan try` is still alive at the accept instant (a dead try = reverted or failed = never accept); (c) the health check PASSes on consecutive samples; (d) CONFIRMATION-WINDOW BOUND: the accept must land within `TRY_TIMEOUT - margin` of the first apply evidence - beyond that, a still-alive `netplan try` may be mid-REVERT, the revert itself restores routing (health would PASS), and a buffered newline would false-ACCEPT a rolled-back change. Past the bound, treat as FAIL. On FAIL, write nothing AND keep the fifo write-end OPEN until `netplan try` exits, so revert rides its own validated timeout path (stdin-EOF behavior on early close is not hardware-validated).
- FR-19 [MEDIUM / CONTINUITY]: Back up the current `90-dynavlan.yaml` before every change; a failed backup refuses the apply (no safe disk-convergence target on revert). Retain the most recent `BACKUP_KEEP` (default 10, minimum 1; pruning happens only after ACCEPT so a revert always finds the just-taken backup); first run has no prior file so the rollback target is "no dynavlan file" (remove + reapply). This backup is an audit/history and manual-recovery artifact; the authoritative in-run rollback is FR-18's `netplan try` revert. Do not implement a competing restore-from-backup path that fights netplan's own revert.

### 7.7 Persistence and reconciliation
- FR-20 [HIGH / CONTINUITY]: The generated `90-dynavlan.yaml` is the persistent known-set; no separate state file.
- FR-21a [HIGH / CONTINUITY]: The rescan timer MUST actually elapse. Its schedule is monotonic (never calendar, so RTC/NTP drift on a headless box cannot skew it) and MUST carry a first-fire trigger anchored on timer activation, not solely a `OnUnitActiveSec` interval: that option anchors on the PREVIOUS activation of the rescan service, so with no prior activation it never elapses at all. Any drop-in that renders the interval MUST restate every trigger the base unit declares, because in systemd an empty assignment to any `On*Sec=` resets the entire monotonic timer list rather than the single option assigned. Validated failure (2026-07-25): the rendered drop-in cleared `OnUnitActiveSec` to override it and silently discarded the base unit's boot trigger, leaving the timer active, `Result=success`, `next_elapse=0`, never once triggered - periodic discovery absent with no error surfaced anywhere.
- FR-21 [HIGH / CONTINUITY]: Timer rescan (`dynavlan --rescan`): strictly add-only. Newly detected, in-range, non-ignored, unexcluded VLANs are added; nothing is ever removed. Do not re-DHCP a VLAN that already has an active lease.
- FR-22 [CRITICAL / CONTINUITY]: Boot (`dynavlan --boot`) reconciles toward the detected set. ADDITIONS are single-pass. GUARD: if there is no carrier, no interface carries tags, or zero VLANs are detected, ABORT the reconcile and change nothing. "Detected nothing" must never mean "remove everything." The `CARRIER_WAIT_SECONDS` expiry path (FR-2) feeds directly into this abort: no carrier -> abort. (CONTINUITY not RECOVERABILITY because removal only affects dynavlan's own VLANs; the guard prevents a spurious monitoring outage + restart churn on an unplugged-at-boot.)
- FR-23 [HIGH / CONTINUITY]: REMOVALS during boot reconcile require two-pass confirmation WITHIN the single `--boot` invocation: sniff, wait `BOOT_SETTLE_SECONDS`, sniff again, and remove only VLANs absent from BOTH passes. This avoids tearing down a real-but-idle VLAN during the least-reliable window (STP/LLDP not converged at boot). Rescan (FR-21) remains strictly add-only and never removes. Boot-time cost is roughly `CARRIER_WAIT + 2×SNIFF_SECONDS + BOOT_SETTLE_SECONDS` (see NFR-4).
- FR-24 [CRITICAL / RECOVERABILITY]: Removing a VLAN requires BOTH dropping its stanza from `90-dynavlan.yaml` AND explicitly `ip link delete <iface>.<id>` (netplan apply alone leaves the orphaned interface up, validated). ORDERING: the explicit `ip link delete` happens ONLY AFTER `netplan try` is ACCEPTED (FR-18 health check passed), never before, and never if the change reverted. If the add/remove change reverts, no interface is deleted (else netplan's file-revert would not recreate the destroyed interface and monitoring would be silently lost).
- FR-25 [HIGH / CONTINUITY]: `RESET_ON_BOOT` (default `true`) governs FR-22/23. When `false`, boot is add-only like rescan; stale VLANs are removed only by reimage.

### 7.8 Change-gated side effects
- FR-26 [MEDIUM / CONTINUITY]: Apply, snap restarts, and service restarts occur only when the VLAN set actually changes. Steady state performs zero applies and zero restarts.
- FR-27 [HIGH / CONTINUITY]: On an ACCEPTED change only, execute in order: (FR-24 deletes for removals) → wait for new-VLAN DHCP leases up to `LEASE_SETTLE_SECONDS` (a VLAN that fails to lease is logged and does not block) → restart each snap in `RESTART_SNAPS` → restart each service in `RESTART_SERVICES`. On a REVERTED change, none of this runs: no lease-settle, no restarts; the run ends with an apply-rollback `err` and no side effects.
- FR-28 [MEDIUM / CONTINUITY]: `RESTART_SNAPS` (default empty; e.g. `domotzpro-agent-publicstore` to restart the Domotz agent) via `snap restart`; `RESTART_SERVICES` (default empty) via `systemctl restart`. A missing/failing entry is logged and skipped, not fatal to the rest.

### 7.9 Scheduling and concurrency
- FR-29 [HIGH / CONTINUITY]: Boot via `dynavlan.service` (`After=systemd-networkd.service`, NOT hard-blocked on `network-online.target`); rescan every `RESCAN_MINUTES` (default 5) via `dynavlan.timer` (monotonic `OnBootSec`/`OnUnitActiveSec`, to survive RTC/NTP drift).
- FR-30 [CRITICAL / RECOVERABILITY]: Serialize all invocations with an `flock` held on an OPEN FILE DESCRIPTOR (kernel-released automatically on process death), never a manual lockfile with unlink-on-exit. An invocation finding the lock held logs "skipped, run in progress" and exits. A dynavlan death mid-`try` releases the lock (kernel) and `netplan try` reverts (timer), so the tool can never enter a permanent "skipped" no-op state. The lock is held across the `netplan try` window; a rescan tick skipped because a boot reconcile holds the lock is acceptable (rescan is idempotent/add-only) and logged.

### 7.10 Logging and operator interfaces
- FR-31 [HIGH / CONTINUITY]: Log to the systemd journal via stderr, syslog identifier `dynavlan`. Persistent logging is MANDATORY and install-verified: the deployment provisions persistent journald (create `/var/log/journal`, `Storage=persistent`) OR ships the rotated `/var/log/dynavlan.log` enabled by default; one branch must be guaranteed at install, not left as an operator choice. A boot-looping headless box must retain logs across reboot.
- FR-32 [LOW / DETERMINISM]: `LOG_LEVEL` (debug|info|notice|warning|err, default info). Every run emits a start and an end line (a missing end line signals silent failure).
- FR-33 [MEDIUM / CONTINUITY]: Log events at their levels: notice = state changes (VLAN discovered ID/iface/method; VLAN removed on reconcile + reason; netplan accepted; each snap/service restart; boot reconcile summary); info = run start (mode + effective config), interfaces/trunk, scan start/end, candidates-vs-known, no-change, leases acquired; warning = exclusions (with source), overlap, restart missing/failed, VLAN no-lease, count over threshold; err = failed preconditions/config, no trunk, generate failure (distinguishing our-YAML vs base-file), apply revert, missing dependency.
- FR-34 [MEDIUM / CONTINUITY]: `dynavlan --dry-run`: detect, compute diff, run `netplan generate` against a throwaway tree to validate, print intended changes; never `netplan try`/`apply`, never restart anything.
- FR-35 [MEDIUM / CONTINUITY]: `dynavlan --status`: print detected vs configured vs excluded/ignored VLANs, selected trunk, and last-run result.

## 8. Configuration

`/etc/dynavlan.conf`, shipped with all keys commented (built-in defaults apply). Invalid values refuse to run (`err`).

```
# DETECT_METHOD="both"                          # both | lldp | sniff
# VLAN_MIN=1                                     # >= 1  (VLAN 1 is a real VLAN on many trunks; use VLAN_IGNORE to skip specific IDs)
# VLAN_MAX=1000                                  # <= 4094
# VLAN_IGNORE=""                                 # IDs never configured; comma/space list w/ ranges, e.g. "1,5,20-25,80"
# VLAN_WARN=32                                   # warn (proceed) above this many VLANs
# VLAN_LIMIT=64                                  # hard cap on total VLANs; 0 = unlimited (FR-36)
# VLAN_LIMIT_MODE=refuse                         # refuse | fill (FR-36)
# SNIFF_SECONDS=60                               # passive capture window
# BOOT_SETTLE_SECONDS=20                         # delay between the two boot-removal detection passes
# CARRIER_WAIT_SECONDS=30                        # max wait for link carrier before sniff
# LEASE_SETTLE_SECONDS=30                        # max wait for new VLAN leases before restarts
# RESCAN_MINUTES=5                               # timer interval
# RESET_ON_BOOT=true                             # true = reconcile at boot; false = add-only across boots
# RESTART_SNAPS=""                               # space-separated; snap restart, e.g. "domotzpro-agent-publicstore"
# RESTART_SERVICES=""                            # space-separated; systemctl restart
# LOG_LEVEL=info                                 # debug | info | notice | warning | err
# BACKUP_KEEP=10                                 # retained 90-dynavlan.yaml backups; minimum 1
# PER_VLAN_MAC=false                             # derive a distinct MAC per VLAN (default off; shared MAC validated)
# VLAN_ROUTES=false                              # true = accept DHCP routes on discovered VLANs at per-VLAN metrics (FR-37)
# VLAN_ROUTE_METRIC_START=100                    # first metric; must exceed the uplink default's metric (FR-37)
# VLAN_ROUTE_METRIC_MODE=discovery               # discovery | id (FR-37)
```

## 9. Non-Functional Requirements

- NFR-1 [CRITICAL / RECOVERABILITY]: Never leave the box without a working uplink. Delivered by FR-16 (atomic write), FR-17 (validate), FR-18 (snapshot + health-check-gated `netplan try` with timer revert), FR-24 (delete only after accept), FR-30 (fd flock). Rollback is driven by a routing health check, never by exit codes.
- NFR-2 [MEDIUM / CONTINUITY]: Idempotency. No-change runs produce no applies/restarts (FR-26); detection stability (FR-4 hysteresis) is load-bearing.
- NFR-3 [HIGH / CONTINUITY]: Portability. No dependency on NIC names, native VLAN, base config contents, or base netplan filenames. Runs on any netplan/systemd-networkd Ubuntu box at or above the pinned netplan version (FR-0).
- NFR-4 [LOW / CONTINUITY]: Time-to-monitor. Boot begins monitoring within roughly `CARRIER_WAIT + SNIFF_SECONDS` (+ `BOOT_SETTLE + SNIFF_SECONDS` when a removal pass runs) + lease settle.
- NFR-5 [MEDIUM / RECOVERABILITY]: Privacy. VLAN interfaces contribute only subnet reachability (FR-14); sniff uses minimal snaplen and never persists frames (FR-5); logs contain site VLAN IDs/subnets (confidentiality-sensitive) and stay local by default.
- NFR-6 [HIGH / CONTINUITY]: Dependencies. `tcpdump` (added to deployment packages), `lldpd`/`lldpctl` (already installed), netplan >= pinned min, systemd. Missing dependency for the requested `DETECT_METHOD` is a refuse-to-run (FR-0), not silent degradation. No `ethtool -K` needed on igb (offload off; promisc bypasses the filter).

## 10. Validated hardware findings (lab box: Ubuntu 22.04.5, Protectli igb NIC)

- Passive sniff in promisc mode discovers unconfigured VLANs despite `rx-vlan-filter: on [fixed]`; `rx-vlan-offload` already off. C4 closed without `ethtool -K`.
- `netplan try` accept and revert both work headless (no TTY). C1 mechanism confirmed.
- Full isolation needs all four `use-*: false` keys; `use-routes` alone leaks DNS/NTP host routes (public OpenDNS observed).
- VLAN removal needs explicit `ip link delete`; file removal + `netplan apply` leaves the interface up.
- `netplan get network.vlans` merges the split base files; live `ip -d link` IDs match. Exclusion sources validated.
- Real VLAN set (1/21/22/101) differs from the template; per-site variability confirmed.

## 11. Naming and Artifacts

Project `dynavlan`. Script `/usr/local/sbin/dynavlan` (`--boot`, `--rescan`, `--dry-run`, `--status`). Config `/etc/dynavlan.conf`. Generated netplan `/etc/netplan/90-dynavlan.yaml` (0600). Units `dynavlan.service`, `dynavlan.timer`. Log: journal (`dynavlan`) + persistent-logging guarantee (FR-31).

## 12. Risks

- R-1 [MEDIUM / CONTINUITY]: Idle VLAN with no traffic and no LLDP is undetectable in a window. Mitigated by LLDP where available, `both` default, add-only rescan re-adding it once it emits traffic.
- R-2 [LOW / DETERMINISM]: Multiple genuine trunks not fully supported (richest wins, FR-4). Revisit if it appears.
- R-3 [LOW / CONTINUITY]: Same-MAC DHCP relies on separate broadcast domains; unusual MAC-keyed servers could misbehave. Optional FR-15 mitigates.
- R-4 [MEDIUM / CONTINUITY]: Wide `VLAN_MAX` on a large trunk creates many simultaneous DHCP interfaces (DISCOVER burst). Mitigated by FR-12 warn; leases bounded and non-fatal (FR-27).
- R-5 [MEDIUM / CONTINUITY]: `netplan generate`/`try` reprocess base files; a hand-broken base file fails FR-17 and freezes all dynavlan updates until fixed. Mitigated by the distinct err log (FR-17/FR-33).

## 13. Acceptance Criteria

- AC-1 [CRITICAL]: Freshly imaged box on a trunk with in-range tagged VLANs comes up monitoring all of them, no SSH, no manual edit.
- AC-2 [HIGH]: Adding a VLAN results in monitoring within one rescan interval, each nominated restart target restarting exactly once (exactly-once rests on FR-26 change-gating + FR-30 serialization).
- AC-3 [HIGH]: A box moved to a different site drops the old VLANs (explicit delete, after accept) and configures the new ones on reboot, in a single reconcile, only when detection is non-empty.
- AC-4 [CRITICAL]: An unplugged/carrierless boot changes nothing (FR-22 guard); previously-known VLANs are not wiped.
- AC-5 [CRITICAL]: An invalid config value or missing required dependency prevents any change and is clearly logged (FR-0).
- AC-6 [CRITICAL]: A forced `netplan generate` failure or a failed post-apply health check results in no net change, no restarts, and a preserved working uplink.
- AC-7 [MEDIUM]: Steady state performs no apply and no restart across many rescan cycles.
- AC-8 [HIGH]: Each configured VLAN interface has only its connected subnet route: no default route, no DNS/NTP host routes.
- AC-9 [MEDIUM]: The journal contains a durable, greppable trail of every discovery, apply, and restart, surviving reboot.
- AC-10 [MEDIUM]: A second physical NIC that is untagged/carries no tags (e.g. `enp2s0`) is never selected as trunk and gets no VLANs.
- AC-11 [HIGH]: A change that reverts (health check fails) leaves no deleted interfaces, no restarts, and the prior VLAN set intact.
- AC-12 [MEDIUM]: A boot with the trunk up but no uplink lease yet (no default route to snapshot) does not cause a spurious revert; if the change adds only isolated VLANs (no default route), it is accepted, and the box is not left a persistent no-op waiting for a route that the change never affected.
- AC-13 [HIGH] (v3.2): On a trunk carrying more in-range VLANs than `VLAN_LIMIT` with `VLAN_LIMIT_MODE=refuse`, dynavlan provisions nothing new (any existing owned set untouched and running) and logs a clear `err` naming count, limit, and remedies; after the operator narrows the range or raises the limit, the next run provisions normally. With `fill`, exactly `VLAN_LIMIT` VLANs run (lowest ids), and every skipped VLAN is named in the journal.
- AC-14 [HIGH] (v3.3): With `VLAN_ROUTES=true` and `VLAN_ROUTE_METRIC_START` above the uplink metric, each provisioned VLAN's DHCP default route is installed at its assigned metric, the uplink remains the lowest-metric default, and health passes; an already-provisioned VLAN keeps its exact metric across subsequent reconciles (discovery mode). With `VLAN_ROUTE_METRIC_START` at or below the uplink metric, dynavlan refuses before touching disk, logs the conflict naming both metrics, and changes nothing.
