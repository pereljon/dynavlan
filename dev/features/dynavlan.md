# dynavlan - Technical Design Doc

Bridges `docs/dynavlan-PRD.md` (v3.1, what/why) to implementation (how). The PRD's FR/NFR/AC IDs are the source of truth for behavior; this doc defines structure, sequencing, and the seams. Companion test plan: `dev/features/dynavlan-tests.md` (to be written before code).

## 1. Implementation decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Language | **bash** | Zero runtime dependency, portable across distros at the shell level (no interpreter-version coupling), natural fit for orchestrating `netplan`/`ip`/`tcpdump`/`lldpctl`. Concurrency footguns (flock/fifo) are contained in a few functions (§7, §9). |
| Timer interval | **static systemd timer + config-synced drop-in** | systemd timers are static files. `RESCAN_MINUTES` is materialized into `/etc/systemd/system/dynavlan.timer.d/interval.conf` by `dynavlan --reconfigure` (also run at install), followed by `systemctl daemon-reload`. Runtime edits to `RESCAN_MINUTES` require re-running `--reconfigure`. Avoids a self-rescheduling loop or a long-running daemon (PRD chose oneshot+timer). |
| Two-pass boot removal state | **in-process, within the single `--boot` run** | FR-23: detect, sleep `BOOT_SETTLE_SECONDS`, detect again, remove only VLANs absent from both. Held in shell variables; no persistence, no cross-invocation state (rescan stays strictly add-only per FR-21). |
| Network backend | **abstracted seam, netplan the only implementation** | See §4. Structure for portability without building multiple backends (that would be speculative). |
| Config format | **shell-sourced `/etc/dynavlan.conf`** | Commented KEY=value; `source` after a strict validation pass. Matches the PRD schema (§8 there). |

## 2. Architecture: two layers

```
+-------------------------------------------------------------+
|  CORE (distro-agnostic)                                     |
|  config parse/validate · interface discovery · sniff/lldp  |
|  detection · filter/exclude/candidates · reconcile logic · |
|  health-check evaluation · logging · flock · entrypoints   |
+-------------------------------------------------------------+
                         | calls (never touches netplan directly)
                         v
+-------------------------------------------------------------+
|  BACKEND SEAM (six operations) - netplan implementation     |
|  list_managed_vlans · generate_config · validate ·          |
|  apply_with_revert · remove_vlan · owned_vlans              |
+-------------------------------------------------------------+
```

The core contains all the intelligence and is portable. The backend seam is the only netplan-coupled code. A future port (NetworkManager, systemd-networkd-direct, ifupdown) implements the six operations; the core is untouched.

## 3. Ownership model (stated abstractly)

dynavlan owns a **namespace** of VLAN definitions and never modifies definitions outside it. Netplan instantiates this as "own `/etc/netplan/90-dynavlan.yaml`, exclude every other file" (FR-13). Future backends: NM = "own `dynavlan-*` connections"; networkd-direct = "own `90-dynavlan.*` unit files". The exclusion logic (FR-10) is "every VLAN managed outside our namespace," queried via the backend.

## 4. Backend seam - the six operations

Each is a bash function `backend_<op>`; the netplan implementation is the initial (only) one. Contract is capability-level, not netplan-specific.

| Operation | Contract | netplan impl | NM impl (future) | networkd-direct (future) |
|-----------|----------|--------------|------------------|--------------------------|
| `list_managed_vlans` | VLAN IDs managed **outside** our namespace (exclusion source) | `netplan get network.vlans` ∪ `ip -d link show type vlan`, minus our own | `nmcli -g … con show` VLANs ∪ `ip link` | parse other `*.netdev` ∪ `ip link` |
| `owned_vlans` | VLAN IDs currently in **our** namespace (known-set) | parse `90-dynavlan.yaml` | our `dynavlan-*` connections | our `90-dynavlan.*.netdev` |
| `generate_config` | Write our namespace to define exactly the given VLAN set (atomic) | atomic write `90-dynavlan.yaml` (FR-16) | `nmcli con add/mod` | write `.netdev`/`.network` |
| `validate` | Dry validate the pending config; distinguish our-error vs base-error | `netplan generate` (FR-17) | `nmcli con … --check` | `networkctl` verify / `systemd-analyze` |
| `apply_with_revert` | Apply, run caller's health check, keep if pass else auto-revert | `netplan try` + fifo-drive (FR-18, §9) | **native** `nmcli` checkpoint + rollback timeout | hand-rolled snapshot/apply/timer/revert |
| `remove_vlan` | Remove a VLAN from our namespace AND tear down the live interface | file edit + `ip link delete` (FR-24) | `nmcli con delete` | rm units + `ip link delete` |

**Revert capability varies by backend** (the one genuinely hard portability item): netplan has `try`; NetworkManager has native checkpoints (cleaner); networkd-direct and ifupdown have none and must hand-roll. The core's `apply_with_revert` contract is "apply with a health-gated auto-revert," so the core is agnostic to which.

A startup stub `backend_detect` (reads `/etc/os-release`, probes for `netplan`) exists but today only ever resolves to `netplan`. No backend-selection config until a second backend exists.

## 5. Module / function decomposition (feeds dev/CODEMAP.md when code lands)

| Function | Purpose (one line) |
|----------|--------------------|
| `main` | Parse mode flag (`--boot`/`--rescan`/`--dry-run`/`--status`/`--reconfigure`), acquire flock, dispatch |
| `load_config` | Source `/etc/dynavlan.conf`, apply defaults, validate all values (refuse-to-run on bad) |
| `parse_vlan_ignore` | Expand `VLAN_IGNORE` comma/space list with `low-high` ranges into a set |
| `check_preconditions` | FR-0: root, netplan>=min + `netplan try` capability probe (non-mutating), deps for method |
| `discover_phys_ifaces` | Live physical NICs from `/sys/class/net` (device symlink, type==1, exclude lo/wifi/vlan) |
| `prep_iface` | Set iface up + promisc on, wait for carrier up to `CARRIER_WAIT_SECONDS` |
| `detect_sniff` | Passive 802.1Q capture (`tcpdump`, minimal snaplen, no disk) → VLAN IDs per iface |
| `detect_lldp` | `lldpctl` advertised VLANs per iface |
| `detect_union` | Union of enabled methods; pick trunk (most tags, hysteresis). Selection factored into a pure helper `select_trunk(candidates,previous)` for unit testing (tests 1e) |
| `compute_candidates` | `detected ∩ [MIN,MAX] − VLAN_IGNORE − backend_list_managed_vlans − backend_owned_vlans` |
| `reconcile_boot` | Two-pass: additions single-pass, removals need absence in both passes; zero-detection guard. Removal-set combination factored into a pure helper `boot_removals(owned,pass1,pass2)` for unit testing (tests 1d) |
| `reconcile_rescan` | Add-only; skip VLANs with an active lease |
| `apply_change` | Orchestrate the safety sequence (§7): generate → validate → apply_with_revert → deletes → restarts |
| `snapshot_default_route` | Capture iface/gw/metric of lowest-metric default route (health-check reference) |
| `health_check` | PASS iff post-apply default route egresses snapshot iface (or empty→empty); ARP non-fatal |
| `wait_leases` | Bounded `LEASE_SETTLE_SECONDS` wait for new-VLAN leases; non-blocking on failure |
| `restart_targets` | Restart `RESTART_SNAPS` (snap) then `RESTART_SERVICES` (systemctl); skip missing/failed |
| `prune_backups` | Keep newest `BACKUP_KEEP` |
| `log` | Leveled journal logging (identifier `dynavlan`), start/end lines |
| `do_status` / `do_dryrun` / `do_reconfigure` | Operator entrypoints |
| `backend_*` (×6) | The seam of §4 |

## 6. Control flow per mode

**`--boot`** (FR-22/23): preconditions → discover/prep iface → detect pass 1 → **guard: if no carrier / no tags / zero detected, ABORT, change nothing** → sleep `BOOT_SETTLE_SECONDS` → detect pass 2 → additions = new in pass 1; removals = owned VLANs absent from BOTH passes → if change: `apply_change` → done.

**`--rescan`** (FR-21): preconditions → discover/prep → detect (single pass) → additions only (add-only) → if change: `apply_change`.

**`--dry-run`** (FR-34): detect + compute diff + `backend_validate` against a throwaway tree → print intended add/remove; **never apply, never restart**. The throwaway tree is a copy of the real `/etc/netplan/` (base files included) with the candidate `90-dynavlan.yaml` overlaid, so `netplan generate` sees base files too and dry-run surfaces an FR-17 base-file-freeze (R-5) rather than hiding it.

**`--status`** (FR-35): print detected vs owned vs excluded/ignored, selected trunk, last-run result.

**`--reconfigure`**: render `dynavlan.timer` drop-in from `RESCAN_MINUTES`, `daemon-reload`.

## 7. Apply/rollback state machine (the safety-critical chain)

Runs under the flock (§ FR-30). Pseudocode with every failure branch:

```
apply_change(target_set):
  snap = snapshot_default_route()                 # may be empty
  backend_generate_config(target_set)             # atomic temp+fsync+rename (FR-16)
  if not backend_validate():                      # FR-17
     log err (distinguish our-YAML vs base-file); restore prior file; return NO_CHANGE
  backup_current(); prune_backups()

  accepted = backend_apply_with_revert(health_check_fn = -> health_check(snap))   # FR-18
     # netplan impl: netplan try --timeout N + fifo drive (§9);
     # health_check runs inside the try window; N > max_check + margin; wall-clock guard

  if not accepted:                                # REVERT path (FR-27, H-3)
     log err apply-rollback
     return NO_CHANGE                             # NO deletes, NO lease-settle, NO restarts

  # ACCEPTED path only:
  for vlan in removals: backend_remove_vlan(vlan) # FR-24: ip link delete ONLY here, after accept
  wait_leases(additions)                          # bounded, non-fatal (FR-27)
  restart_targets()                               # snaps then services (FR-27/28)
  log notice (summary)
```

Every failure path lands on "no net change, uplink intact, logged." A death anywhere releases the flock (kernel, fd-held) and `netplan try` reverts (timer). See §9 for the accept/revert primitive.

## 8. Health check (FR-18)

- `snapshot_default_route`: `ip route show default` → lowest-metric route's `dev`, `via`, `metric`. May be empty.
- Post-apply PASS iff: a default route exists AND the **lowest-metric** default route's `dev` equals the snapshot `dev`. Comparison is on `dev` (interface) only, never metric or gateway (a metric or gateway change on the same iface is a normal DHCP event and must not revert). If a spurious lower-metric default appears on a *different* iface post-apply, the lowest-metric default has moved off the base uplink → FAIL/revert. **Empty-snapshot rule (AC-12):** if the snapshot was empty, PASS iff post-apply is also empty or the only new default is one the change did not add (VLANs add none, per FR-14) — never revert solely because the box independently had no uplink.
- ARP reachability of the gateway is optional, secondary, **strictly non-fatal**: a silent gateway must not fail the check. Never ICMP.
- Dependency: valid only because FR-14 gives generated VLANs no default route, so snapshot/post-apply reflect the base uplink alone. A change to FR-14 isolation keys must revisit this.

## 9. `netplan try` accept/revert primitive (netplan `apply_with_revert`)

The concurrency-sensitive part (IR-2). `netplan try --timeout N` reads confirmation from stdin; we drive it via a fifo/coproc:
- Start `netplan try` with stdin connected to a fifo we hold open for writing.
- Run `health_check` (bounded; `N > max_health_check + margin`).
- PASS → write `\n` to the fifo (accept). FAIL → write nothing; the timer reverts.
- The accept-write **must tolerate `netplan try` having already reverted and closed the pipe** (handle `SIGPIPE`/`EPIPE` without crashing).
- An independent **wall-clock guard** bounds the whole interaction regardless of `netplan try`'s own timer.
- `N` is set explicitly from a config-derived value, never left to netplan's 120s default.

## 10. Data representation

- VLAN sets: space-separated sorted ID lists in shell vars; set ops via `comm`/`grep -F` or associative arrays.
- Known-set (`backend_owned_vlans`): parsed from `90-dynavlan.yaml` (`netplan get network.vlans` is authoritative for IDs).
- `VLAN_IGNORE`: parsed once into an associative-array set for O(1) membership.
- Generated VLAN stanza per ID (FR-14): `<iface>.<id>` with `dhcp4: true` + `use-routes/use-dns/use-ntp/use-domains: false`.

## 11. systemd units & install layout

- `/usr/local/sbin/dynavlan` (0755), the script.
- `/etc/dynavlan.conf` (commented defaults).
- `/etc/netplan/90-dynavlan.yaml` (0600, generated).
- `dynavlan.service`: `Type=oneshot`, `After=systemd-networkd.service`, NOT `Wants/After=network-online.target`, `ExecStart=/usr/local/sbin/dynavlan --boot`.
- `dynavlan.timer`: `OnBootSec`/`OnUnitActiveSec` (monotonic), interval via `.d/interval.conf` from `RESCAN_MINUTES`.
- Persistent journald guaranteed at install (`/var/log/journal` + `Storage=persistent`) OR `/var/log/dynavlan.log` default-on (FR-31).
- `install.sh`: place files, add `tcpdump` dependency, run `--reconfigure`, enable service+timer.

## 12. Portability plan (what to build now vs later)

**Now (cheap, structural):** the §4 backend seam as six functions; the abstract ownership model (§3); the `backend_detect` stub resolving only to netplan; the `apply_with_revert` capability contract. The core never calls `netplan` directly.

**Later (only when a second backend is real):** NM/networkd/ifupdown implementations; a real `backend_detect`; any backend-selection config. Each future backend's hardest piece is the revert (NM native / networkd-direct hand-rolled).

**Not planned:** non-systemd init (OpenRC/runit) — systemd assumed for service/timer/journald; revisit only if it comes up.

## 13. Deferred open items (see context/open_questions.md)

- IR-1: exact minimum netplan version (pinned conservatively at 0.106; possible later relaxation).
- G-4: per-VLAN MAC derivation function (only needed if `PER_VLAN_MAC` is enabled; default off).
