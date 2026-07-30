# SKELETON - how dynavlan works

Owns: the logic flow and key invariants of the `dynavlan` script, as prose or pseudocode. Does NOT hold per-function purposes (dev/CODEMAP.md) or requirements (docs/dynavlan-PRD.md).
Maintain: update when control flow, call sequences, or invariants change.

## Run lifecycle

Every invocation follows the same spine; the mode decides the reconcile policy.

```
main(mode)
  [--version: print "<ver> (build <id>)", exit 0 - BEFORE config load and root check, on purpose]
  load_config            # source /etc/dynavlan.conf, strict-validate every key; any bad value = refuse-to-run
  [--status/--reconfigure: root check, run, exit]
  check_preconditions    # root; netplan >= MIN_NETPLAN (--version on 1.x, else dpkg; undeterminable = its own refusal); `netplan try` capability probe (non-mutating); tcpdump/lldpctl per DETECT_METHOD
  [--dry-run: try the flock non-blocking (hold if free; warn + proceed read-only if held), preview, exit]
  [--reapply: take fd-held flock BLOCKING (-w); busy past the timeout = err, rc 1, nothing applied]
  [--boot/--rescan: take fd-held flock (non-blocking; busy = "skipped", rc 0), dispatch]
```

The flock is an open fd on /run/dynavlan.lock, released by the kernel on process death. There is no unlink-on-exit lockfile anywhere: a dead run can never freeze the tool.

## Detection

```
run_detection
  discover_phys_ifaces   # /sys/class/net: real device symlink, ARPHRD_ETHER, not wireless, safe charset
  prep_iface (all)       # admin-up + promisc on (promisc makes the NIC VLAN filter transparent; left ON)
  one shared carrier deadline (CARRIER_WAIT_SECONDS total, NOT per port)
  concurrent sniff+lldp per carrier-up iface (one SNIFF_SECONDS window total); sniff is INBOUND ONLY
  DETECTED_TRUNKS = every carrier-up iface with a non-empty tag set (no trunk selection/contest)
```

Detection cost is deliberately independent of port count (a 4-6 port box must not blow the systemd start timeout). Sniff is the primary detector (LLDP on Meraki advertises only the native VLAN); `both` is the default.

**All-trunks, not one selected trunk.** Every carrier-up interface with a non-empty detected tag set is a trunk and gets provisioned; there is no contest, no hysteresis, and no `select_trunk`. Two trunks that happen to carry the same VLAN id are provisioned independently as distinct interfaces (`enp1s0.100` and `enp2s0.100` are different netdevs, not a collision) - this is why every set in the pipeline downstream of detection is keyed by `iface.id` tokens, never bare VLAN ids (§ Token representation below).

**The sniff is INBOUND ONLY** (FR-5a, `tcpdump -Q in`). Packet capture sees egress too, and every VLAN we own transmits tagged DHCP on the parent - DISCOVER retries forever if it never leases, renewals if it did. Counting those makes detection self-fulfilling: an owned VLAN is permanently "detected" on its own evidence, so FR-23 removal can never fire, neither for a VLAN created in error nor for one the switch genuinely stopped trunking. Hardware-validated (2026-07-25): a dead `enp1s0.100` sustained itself across reboots on 1 outbound VID-100 DHCP Request from our own MAC, 0 inbound in 75s. Missing `-Q` support is a refuse-to-run precondition, never a silent fallback to bidirectional capture; the probe is `tcpdump -Q in -d vlan`, which compiles the filter without opening the device (non-mutating, no root needed).

**LLDP never contributes the native VLAN** (FR-7a). `lldpctl` flags it `pvid=yes`, and it is untagged on the wire: a VLAN interface carrying that tag can never receive a frame, so it comes up, never leases, and stays dead. Hardware-validated 2026-07-25: LLDP advertised only `vlan-id=100 / pvid=yes`, dynavlan built `enp1s0.100`, and it took no lease in 30s. `lldp_tagged_vlans` drops it. The exclusion is scoped to the LLDP source alone - if the sniff sees tagged frames for that ID, it is a real tagged VLAN and stays a candidate. Note `lldpctl -f keyvalue` gives no index in the key, so `vlan-id` and its `pvid` are correlated by ADJACENCY only; the parse is necessarily stateful, and a block with no `pvid` key is treated as tagged. The patterns anchor on the VLAN TLV's own subtree (`.vlan.vlan-id=` / `.vlan.pvid=yes`), never on anything merely ending in `.vlan-id=` (review 2026-07-25): lldpd's full key set is undocumented here, and a loose match makes the parse depend on assuming what else it emits. A foreign `.vlan-id=` key landing mid-block both flushes the real id as "tagged" before its `pvid` is seen - rebuilding the dead native-VLAN interface this rule exists to prevent - and leaks the foreign key's own VALUE as a VLAN candidate, so dynavlan would build an interface for a VLAN that is not on the trunk at all.

## Token representation (all-trunks canonical key)

Every set downstream of detection - candidates, additions, removals, owned, target - is a space-separated set of `iface.id` tokens, never bare VLAN ids. `tag_tokens`/`untag_tokens`/`tokens_for_iface`/`distinct_ifaces`/`tok_iface`/`tok_id` convert between the token domain and the per-trunk bare-id domain that `compute_candidates`/`boot_removals` operate in. `distinct_ifaces` on a token set is how every mode discovers which trunks to loop over, including trunks that are currently owned but no longer detected (a dark trunk).

## Reconcile policies

All three modes funnel into the same `apply_change`; they differ only in how the target token set is computed. Boot and rescan compute PER-TRUNK candidates/removals in a loop over every relevant iface, tag each trunk's ids to `iface.id` tokens, then combine into one token set and make ONE unified `apply_change` call for the whole box - never a per-trunk apply, since a single `netplan try` window must cover every trunk's change together.

- **--boot** (reconcile): detection pass 1 → **zero-detection guard**: no trunk detected at all (empty `DETECTED_TRUNKS`) = ABORT, change nothing → loop over the UNION of owned-trunk ifaces and newly-detected trunk ifaces; per trunk, candidates = detected ∩ [MIN,MAX] − ignore − managed-elsewhere − owned-on-that-trunk, tagged to `iface.id` → settle → pass 2 (re-detect) → per trunk, removals = owned ids on that trunk absent from BOTH passes (pass 2 only counts for that trunk if it has carrier at pass-2 time; an iface with no carrier or empty detection in either pass has its owned VLANs preserved, not removed) → combine all trunks' additions/removals into one token set → count gate → one unified apply. **No relocation branch**: a trunk that goes dark (no carrier, or no tags) is left alone - its owned VLANs are preserved, never torn down and rebuilt elsewhere, because bare-id relocation logic makes no sense once every trunk is provisioned independently and a "moved" trunk is just one trunk going dark while another (already provisioned on its own merits) carries tags.
- **--rescan** (timer): add-only, over every currently `DETECTED_TRUNKS` iface. Per-trunk candidates = detected ∩ [MIN,MAX] − ignore − managed-elsewhere − owned-on-that-trunk, tagged and combined → count gate → one unified apply. Never removes, on any trunk.
- **--reapply** (FR-39): NO detection at all. Target = the owned token set verbatim (spans whatever trunks it already spans; refuses if the owned set is non-empty but yields no distinct ifaces), generates a candidate under `/run`, and applies ONLY if `config_body_differs` says the body changed (line 1, the version/build header, is excluded positionally - FR-38 put a per-build id there and comparing it would force an apply on every upgrade). Never adds or removes a VLAN. Bypasses the count gate (zero additions is not growth; `fill` mode would trim). On ACCEPT, lease-waits the FULL owned set, since there are no additions to wait on and restarting the agent mid-re-DHCP would drop kept subnets. Exists because regeneration is otherwise gated on the VLAN-set diff, so a change to the GENERATED stanza never reaches a box whose VLAN set is stable.
- **--dry-run**: same per-trunk candidate math as boot, single pass, over the union of owned and detected trunk ifaces; generates into a throwaway copy of /etc/netplan and validates there; prints the diff (per-trunk breakdown plus a combined total), count gate, and (routed mode) the metric map + any would-be conflict. Never applies.

Count gate (FR-12/36): warn above VLAN_WARN; above VLAN_LIMIT either refuse loudly (default) or fill lowest-ids into the remaining slots. Removals-only changes always pass the gate (the cap gates growth, never a shrink).

**The timer drop-in must restate EVERY monotonic trigger** (FR-21a). In systemd an empty assignment to any `On*Sec=` resets the WHOLE monotonic timer list, not the single option assigned, so `render_timer_dropin`'s leading `OnUnitActiveSec=` also clears the base unit's first-fire trigger and has to put one back. A timer left with only `OnUnitActiveSec` anchors on the previous activation of `dynavlan-rescan.service`; with no prior activation there is nothing to anchor on and it NEVER elapses. Hardware-validated failure (2026-07-25): timer `active`, `Result=success`, `LastTriggerUSec` empty, `next_elapse=0`, `NextElapseUSecMonotonic=infinity`. Nothing logs an error - periodic discovery is simply absent, and `systemctl list-timers` showing `n/a` in every column is the only tell. First fire is `OnActiveSec` (timer activation) rather than only `OnBootSec` (kernel boot), because `install.sh` stops and restarts the timer on upgrade, long after any boot deadline has passed.

## Apply/rollback state machine (the safety-critical chain)

```
apply_change(target, additions, removals)
  snapshot default route (iface [+ metric in routed mode])
  [routed mode] assign per-VLAN metrics; REFUSE up front if any metric <= uplink metric
  backup current owned file            # failure = refuse (no safe convergence target without it)
  backend_generate_config(target)      # atomic: mktemp same-dir 0600, fsync, rename
  backend_validate                     # netplan generate; distinguishes "our YAML bad" vs "base file bad" (freeze)
  backend_apply_with_revert            # the accept primitive below
  ACCEPT: prune backups → delete removed VLAN links (ONLY here) → wait leases → restart targets
  FAIL:   netplan try has reverted live state; converge disk back to the prior file; NO deletes, NO restarts
```

### The accept primitive (netplan try + fifo)

`netplan try` applies first and reads stdin after; its revert timer starts post-apply. A newline written early would sit in the pipe buffer and be consumed unconditionally - accepting a change the health check never saw. So the accept loop requires ALL of:

1. **Apply evidence**: the first added VLAN's netdev exists (proves the apply BEGAN), plus an unconditional settle floor before any health sampling. No-additions changes anchor at t=0.
2. **Liveness**: `netplan try` still running at the accept instant (dead try = reverted/failed = never accept).
3. **Health**: HEALTH_CONSEC consecutive PASSes - the lowest-metric default route still egresses the snapshotted iface (iface only; metric/gateway changes are normal DHCP events).
4. **Confirmation-window bound**: no accept once `waited - first_evidence >= TRY_TIMEOUT - 2*POLL_INTERVAL`. Past that, a still-alive try may be mid-REVERT and the revert itself restores routing (health would PASS) - a buffered newline would false-ACCEPT a rolled-back change.

On FAIL the fifo write-end is held OPEN until try exits on its own timer (stdin-EOF-on-early-close is not hardware-validated and is never exercised). An independent wall-clock guard (3× TRY_TIMEOUT) bounds the whole interaction.

## Routed mode (FR-37, opt-in)

Default is full isolation: every VLAN is DHCP address-only, `use-routes/use-dns/use-ntp/use-domains` all false (all four are required; anything less lets networkd pin DHCP-provided DNS/NTP as host routes), plus `accept-ra: false`. With `VLAN_ROUTES=true` the stanza flips to `use-routes: true` + `route-metric: N`; DNS/NTP/domains stay declined. The token:metric map is computed once per run by `plan_route_metrics`, the single decision point every caller must use (a second call site recomposing the pieces is how the two silently diverge): kept tokens reuse the metric read back from the owned YAML itself (the file is the state store, keyed by `iface.id` token so two trunks sharing a VLAN id get independent metrics); the tokens assigned a NEW metric are those in the target that do not already have one - NOT the additions. Those sets differ exactly when an owned VLAN has no persisted metric, which is what an isolated -> routed migration looks like, and assigning for additions alone left the rest unassigned and froze generation permanently (fixed 2026-07-25). New assignments are next-free ascending in discovery order across the WHOLE box (all trunks share one metric sequence, not one per trunk); existing tokens never renumber. `VLAN_ROUTE_METRIC_MODE`/`id` mode was dropped in the all-trunks redesign: discovery order is the only mode. If any assigned metric would match or beat the uplink's, refuse before touching disk - applying would guarantee a health-FAIL revert loop.

**Isolation is per-CHANNEL, and the `use-*` keys only cover one channel** (FR-14a). All four are `dhcp4-overrides`: they bind DHCPv4 and nothing else. IPv6 RA arrives unsolicited and networkd accepts it by default on a non-router link, handing over a SLAAC address, RDNSS resolvers, and a default route that no `use-*` key declines - so every VLAN also carries `accept-ra: false`, in routed mode as well as isolated. Hardware-observed 2026-07-25: `enp1s0.22` held a global SLAAC address from a VLAN RA while every DHCPv4 decline was in force. This is a rollback-safety matter, not just confidentiality: `default_routes_tokens` samples `ip route show default`, IPv4 only, so an RA default via a monitored VLAN is invisible to the health check and could never trigger a revert. The v4-only sample is correct ONLY while `accept-ra: false` holds; allowing a VLAN an IPv6 default requires giving the health check an `ip -6` arm in the same change. `link-local` is left at netplan's default, so the `fe80` addresses remain.

## Key invariants

- **Never strand the box**: every failure path lands on "no net change, uplink reachable, logged." Rollback is gated on the routing health check, never on an exit code. There is no fallback from `netplan try` to bare `netplan apply`.
- **One file owned**: dynavlan writes exactly `/etc/netplan/90-dynavlan.yaml` and never reads base config for assumptions nor modifies any other file. Base-file validation errors freeze dynavlan updates rather than being "fixed."
- **Discover, don't assume**: no hardcoded interface names, VLAN ids, native VLAN, or base filenames anywhere.
- **Deletes only after ACCEPT**: `ip link delete` for removed VLANs runs only on the accepted path. On revert, netplan's file-level revert could not recreate a destroyed interface.
- **Zero detection never means "remove everything"**: boot aborts only when NO trunk is detected at all; per-trunk removals additionally need absence in two passes on a carrier-up trunk, and a trunk that goes dark (no carrier, or empty detection) has its owned VLANs preserved rather than removed.
- **Side effects are change-gated**: no change = no apply, no lease wait, no restarts (restart targets are nominated snaps/services; failures there are warn-and-continue, never fatal).
- **State lives in the owned YAML**: the owned VLAN token set (spanning however many trunks) and routed-mode metric assignments (keyed by `iface.id` token) are all read back from the one file dynavlan writes. No sidecar state files, no persisted "selected trunk."
- **Config is strict**: any invalid value refuses the whole run; the config file must be root-owned and not group/other-writable (it is sourced by root).
- **Logs are the console**: leveled logging to stderr → journald (identifier `dynavlan`); the box is not meant to be logged into, so every decision leaves a trail.
