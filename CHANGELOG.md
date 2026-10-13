# Changelog

Format: Keep a Changelog. Add bullets under `## Unreleased`; on release, retitle that section to `## [x.y.z] - YYYY-MM-DD`.

## Unreleased

### Changed

- The package description (`debian/control`) is rewritten in plain language. No behavior change.

## [1.0.0] - 2026-10-12

The 1.x compatibility contract (`COMPATIBILITY.md`) takes effect with this release. The runtime
is the hardware-validated 0.4.22 build (`01e9f98`); 1.0.0 changes only the version number,
developer tooling and documentation. Validated on one reference box; second-site validation was
waived for 1.0 (`docs/v1.0-definition.md`).

### Added

- Version-gate git hooks (`githooks/`, installed per clone with `bash githooks/install.sh`):
  `pre-commit` checks the staged script's `ver=`/`build=` lines and `commit-msg` requires a
  higher `ver=` for a script change unless the commit carries one reasoned
  `Version-Bump: none (<reason>)` trailer. They guard against accidental omissions; they do not
  prove a change is behavior-neutral.

### Changed

- `-h`/`--help`, when explicitly requested, now exits `0` (requested help is success)
  instead of `2`. A missing mode or an unknown mode still exits `2`. Done in the
  pre-1.0 window while exit codes are still free to change.

### Fixed

- LLDP detector failure read as an empty trunk (`ver=` 0.4.21 -> 0.4.22). `lldpctl` (lldpd 1.0.13)
  exits 0 when it cannot reach the daemon, so with `DETECT_METHOD=lldp` and lldpd down `--status`
  reported `detected trunks: [none]` with exit 0 (hardware case HV-41). The query's own connection
  diagnostic now fails the LLDP sample, so status reports detection unavailable and exits non-zero,
  and the sample cannot authorize a detection-diff removal. Under `both`, a good sniff still decides.
- Misleading output (same version). A steady boot or rescan logged "zero applies/restarts" just
  before the separate new-subnet pass could restart a target; it now says "nothing to apply". A
  count-gate refusal in `--dry-run` no longer prints a "count gate: OK" line before "count gate REFUSED".
- Rollback correctness (`ver=` 0.4.20 -> 0.4.21). `apply_change` validated the candidate with a real
  `netplan generate` before `netplan try`, so try's runtime backup (`/run/systemd/network`) captured the
  candidate's generated files and a revert restored them (observed on hardware: an interrupted add left
  the candidate's generated files behind although the owned YAML was restored). The candidate is now
  validated in an isolated scratch root that mirrors `/lib/netplan`, `/etc/netplan` and `/run/netplan`,
  before the backup and the live write, and a stop requested during validation is honored before any live
  change. `--dry-run` uses the same staging, so it now also sees `/lib` and `/run` inputs.
  Hardware-confirmed on an interrupted isolated-mode add (HV-01, 2026-10-12). Known limitation: a VLAN
  link created only by the reverted change stays in the kernel with its address and connected route,
  and its VLAN is treated as managed elsewhere until it is removed by hand (deployment guide, section 5).
- Wording corrections in operator-visible output (`ver=` 0.4.19 -> 0.4.20). The `install.sh`
  upgrade message no longer says a rescan is "add-only" (it adds VLANs and prunes a debounced
  carrier-down trunk), and the comment written into the generated timer drop-in now says every
  desired effective trigger must be emitted after the reset, with `OnActiveSec` replacing the
  base `OnBootSec`. No behavior change; the drop-in is rewritten on the next `--reconfigure`.
- Removal lifecycle (`ver=` 0.4.18 -> 0.4.19). New `dynavlan --teardown`: the attended,
  console-backed way to remove every owned VLAN. It takes the run lock (bounded wait), runs
  on built-in defaults if the config is invalid, needs root/`ip`/netplan but not the
  detection tools, refuses unless `dynavlan.timer` and `dynavlan.service` are both disabled
  and inactive, retries pending deletes, then applies an empty candidate through the same
  health-gated `netplan try` as a normal change and deletes the links only after it is
  accepted. A residual link after an accepted teardown is reported with its exact
  `ip link delete` and exit 1; a reverted or uncertain apply exits 1 with no delete advice.
  `--dry-run` does not preview it. Package `remove` now stops and verifies the timer, waits
  for any in-flight run, then disables the timer and boot service (it previously left them
  enabled), and `purge` also removes the generated timer interval drop-in (the directory
  only if empty). Maintainer scripts still never touch netplan or live links. The
  deployment guide's removal section is rewritten: the old claim that deleting the YAML and
  running `netplan apply` drops the VLANs was wrong (netplan does not delete interfaces).
- Configuration grammar (`ver=` 0.4.17 -> 0.4.18). Numbers must now be canonical decimals:
  a leading zero (`05`, `018`) is refused instead of being read as octal. `VLAN_IGNORE`
  refuses an empty element at the start, middle or end (`"1,"`, `",1"`, `"1,,3"`) and
  leading-zero ids and range endpoints. A quoted value needs a matching closing quote
  followed only by whitespace and an optional comment; an unmatched quote or trailing
  text is refused (the error names the key). **Upgrade note:** a config that loaded
  before with one of those forms is now refused at load (nothing changes on the box);
  correct the value, there is no automatic migration. `VLAN_IGNORE` and the
  `VLAN_MIN`/`VLAN_MAX` range are documented and tested as suppressing NEW candidates
  only, never removing a VLAN already owned; `--status` rows now list such VLANs as
  `owned-ignored` / `owned-out-of-range`. New routed metrics follow lexical full
  `iface.id` token order (documented; behavior unchanged), and the config comments now
  say a change to generated policy needs an attended `--reapply`.
- Dry-run, status and subnet reporting (`ver=` 0.4.16 -> 0.4.17). `--dry-run` now follows
  the real boot decisions: an invalid detection sample (even a partial one) no longer
  previews a removal, the real VLAN count gate applies (a refusal cancels additions and
  removals, prints the unchanged owned target, validates nothing, exits 1; `fill`
  previews the filled target), a quiet wire still previews guarded pending-delete retries
  and the new-subnet state and still validates, and a failed copy of the base netplan tree
  is a failed pre-flight instead of validating a partial tree. `--status` reports
  detection as unavailable/incomplete (non-zero) when any sampled interface's detector
  failed, and prints one row per owned-or-detected trunk (carrier, configured, detected,
  ignored, out-of-range, managed-elsewhere); the layout changed. With no restart targets
  configured, new subnets are left unseen so a target configured later gets one catch-up
  restart, and dry-run/status say `no restart targets configured` instead of `would
  restart`. The docs now state that detection (and so `--status` and `--dry-run`) brings
  physical NICs administratively up and leaves promiscuous mode on; it is not restored.
- Upgrade and install lifecycle (`ver=` 0.4.15 -> 0.4.16). `install.sh` no longer
  re-enables a unit you left disabled: it captures the enabled/active state of both
  units first and restores each independently; only a first-ever install enables by
  default. It now treats a timer that cannot be stopped *and verified inactive* as
  fatal before replacing anything, exits non-zero when a previously running timer
  cannot be restarted (instead of reporting success), keeps the original failure status
  when its own restoration also fails, and neutralizes the removed `PER_VLAN_MAC` key
  before the new script loads the config. The package gains a `preinst` (capture,
  quiesce and run-lock wait before unpack, which also covers the first dpkg install over
  a manual deployment, where no outgoing `prerm` exists); `prerm` handles
  `failed-upgrade` instead of silently bypassing quiescence; `postrm` restores the
  timer on `abort-install`/`abort-upgrade`; and `postinst` keeps the prior-state record
  when configuration fails, restarts only a previously running timer, and reports that
  this is not a rollback. The record is validated (exactly three 0/1 fields) before any
  reuse, and a record is trusted only as a genuine handoff within the same dpkg run
  (recorded owner), so an unrelated leftover cannot override the current posture;
  quiescence is always taken from the live timer state, never from the record. A failed
  restoration keeps the record and is reported. `dynavlan --reconfigure` now returns non-zero when `systemctl daemon-reload`
  fails instead of logging success, and the package and installer propagate it. Removal
  and purge behavior is unchanged.
- Stopping `dynavlan.service` or `dynavlan-rescan.service` (or a start timeout) during a
  live `netplan try` window no longer leaves an unconfirmed change applied. Both units now
  use `KillMode=mixed` with `TimeoutStopSec=60`, and the run handles SIGTERM before ACCEPT:
  it never writes the confirmation, withdraws the confirmation writer so Netplan reverts,
  waits (bounded) for `netplan try` to exit, and restores the prior owned file. After
  ACCEPT a stop keeps the committed change and runs the removals but skips the lease wait
  and agent restart, and the whole new-subnet restart pass is suppressed; a skipped restart
  is only made up later when a still-unseen subnet exists and `RESTART_ON_NEW_SUBNET=true`.
  A stopped run exits 1. `ver=` 0.4.14 -> 0.4.15.
- The release workflow could never publish the APT repository: `publish-apt` read the
  version from a `steps.*` context belonging to the *other* job, which evaluates empty
  across jobs, so its just-published-package check always looked for `dynavlan__all.deb`
  and failed. The version now travels as an explicit `build-deb` job output consumed via
  `needs`, binding both jobs to one value, and an empty version fails by name instead of
  as a confusing "missing package" error. Observed effect of the bug: the public index
  stayed at 0.4.2 while later versions were released.
- `get.sh` no longer destroys a working APT repository configuration when the apt path
  fails. It previously wrote the keyring and source file directly to their final paths
  and deleted both on any failure, so a transient `apt-get update` error on an
  already-configured box left dynavlan installed but undiscoverable by later
  `apt update`/`apt upgrade`. Key and source are now staged and moved into place only
  once written, files that pre-existed are restored byte-for-byte on failure, and files
  this run created are removed. Every staging step is checked explicitly rather than
  relying on `set -e`, which is disabled while the function runs as an `if !` condition.
  The fallback contract is unchanged: a first install may still fall back to the tarball
  path, and an existing dpkg-managed install still refuses an unmanaged fallback.
- `get.sh` and `build-deb.sh` lost their intended diagnostics to `pipefail`: a failing
  `curl`/`grep` inside a capture pipeline aborted the script silently, so the messages
  written for exactly those cases never printed. Retrieval and parsing are now separate,
  keeping a transport/read failure and an empty parsed result distinct and reported.
- VLAN identity, pending-delete guards and apply reporting (`ver=` 0.4.13 -> 0.4.14). A
  netplan VLAN stanza is now identified by its own `id:` and `link:` fields, not its mapping
  key, so arbitrarily keyed stanzas are no longer merged or mistaken; the stanza query reports
  "none configured" and "cannot tell" differently, and callers that gate on ownership stop
  on a failed query. Each pending-delete retry takes a fresh default-route and netplan
  ownership query and checks every token against those results (it does not re-query
  before each individual delete), and preserves the record if a query fails, so a past
  removal alone no longer authorizes a delete. A change that was not
  accepted no longer claims a completed revert, and a failed, unrecordable delete no longer
  prints a contradictory "removed" summary.
- FR-22 zero-detection boot abort logged at `err` while exiting 0 (an error-severity
  line on an intended no-op). Severity now tracks the owned set: `warning` when owned
  VLANs are preserved behind a now-quiet wire, `info` when nothing is owned. Exit code
  unchanged (0). The same predicate was already `info` in the rescan path.

## [0.4.11] - 2026-08-06

Consolidates the pre-1.0 gate-4 review hardening (0.4.3 through 0.4.11) into one
release. Console-backed hardware validation on the Protectli box (build `b0317b6`,
2026-08-06): build-identity gate, M8 dep-gate, H5 lease timing, M5 drain, M6
restart-failure seen-set (total + partial), P2 kill-mid-apply FIFO-EOF revert, and
the L3-30 carrier-pull prune + re-add all PASS. Details in
`docs/hardware-validation.md`.

### Changed

- FR-35 narrowed: `--status` shows a `journalctl -t dynavlan` run-history hint
  rather than a persisted last-run result (deferred; the journal already carries it).

### Fixed

- The post-apply health check is now order-independent for equal-metric multi-uplink
  boxes. It kept the first default route listed at the minimum metric; with two
  equal-metric defaults, a route-listing order flip between the pre-apply snapshot
  and the post-apply sample (same routing state) could pick a different iface and
  spuriously FAIL -> revert. The check is now set membership at the minimum metric
  (the snapshot iface still holds a default at the min), so a legitimate multi-uplink
  box no longer sees a needless revert. The prior behavior was preserve-biased (the
  revert was a no-op, never a strand), so this removes churn, not a hazard (gate-4
  P3). (`ver=` 0.4.10 -> 0.4.11.)

- `--status` no longer reports a confident, wrong "no trunk" when a detection tool
  is missing. It ran its detection pass without a dependency check (those gated only
  the reconcile path), so on a box lacking tcpdump/lldpctl/netplan it printed
  `detected trunks: [none]` and exited 0 - indistinguishable from a genuinely quiet
  wire. The tool checks are now shared with the reconcile path; `--status` gates its
  detection on them, prints `detected trunks: unavailable` and exits non-zero when a
  prerequisite is missing, while still printing the static report. Each detected
  trunk now also shows per-trunk ignored / out-of-range / managed-elsewhere VLANs
  (gate-4 M8). (`ver=` 0.4.9 -> 0.4.10.)

- A new IPv4 subnet is no longer marked "seen" when NO restart target restarted at
  all. Previously `restart_targets` warned-and-continued on a failed snap/service
  restart while the subnet was recorded as seen regardless, so a transient failure
  meant it was never retried and the agent never learned it this uptime. On a total
  restart failure the new subnet is now held out of the seen-set and retried on the
  next `--boot`/`--rescan`; a partial success still consumes it (total-failure only,
  since a subnet cannot be mapped to a specific target and blocking on any failure
  would let one permanently-broken target re-restart the working agents every run
  forever). Covers a failed VLAN-driven restart from an apply too (gate-4 M6).
  (`ver=` 0.4.8 -> 0.4.9.)
- A post-accept `ip link delete` that fails transiently is no longer forgotten.
  The delete runs only after the change is accepted, at which point the stanza is
  already gone from the owned netplan file, so a failed delete would leave the live
  interface (and its subnet) up until reboot and the next run could not tell that
  orphan from a genuine external VLAN. The failed token is now recorded in
  `/run/dynavlan/pending-delete` (tmpfs, reboot-scoped) and retried at the start of
  every `--boot`/`--rescan`; `--dry-run` previews the pending set read-only. Only
  tokens dynavlan itself removed are ever recorded, so a retry never deletes an
  external VLAN (gate-4 M5). (`ver=` 0.4.7 -> 0.4.8.)
- Additions are no longer created on a trunk that lost carrier between detection
  and apply. Additions are computed from the detection sample taken before the
  carrier verdict; the prior drop-on-dead-trunk guard only covered **owned** trunks
  on the removal path, so a newly-detected but not-yet-owned trunk that died in the
  detection->apply window still got new VLAN stanzas on a dead parent (they never
  lease, stall the lease wait, and fire a pointless restart). `--boot`/`--rescan`
  now recheck carrier on every addition-bearing interface immediately before apply
  and drop additions on any that are down, regardless of ownership; `--dry-run`
  applies the same filter so its preview matches. A single sample is used: declining
  an addition is fail-toward-no-change and re-added next rescan (gate-4 M4).
  (`ver=` 0.4.6 -> 0.4.7.)
- The post-accept new-VLAN lease wait is now one box-wide deadline instead of a
  per-VLAN wait in series. The new VLANs all DHCP in parallel once the apply
  accepts, but `wait_leases` waited up to `LEASE_SETTLE_SECONDS` on each VLAN
  before looking at the next, so the total stacked to as much as `VLAN_LIMIT` ×
  the deadline (up to 1920s at the cap). That could exceed the systemd
  `TimeoutStartSec` and get the run killed before `restart_targets` ran, silently
  skipping the FR-27 monitoring-agent restart. All pending VLANs are now polled
  together, bounding the wait to `LEASE_SETTLE_SECONDS` regardless of count
  (gate-4 H5). (`ver=` 0.4.5 -> 0.4.6.)
- A capture method that **fails** at runtime (tcpdump cannot open the device or the
  BPF filter is rejected, `lldpctl`'s daemon is down, or promisc could not be set)
  no longer reads as a genuinely empty trunk and can no longer authorize a boot
  detection-diff removal. Detection now carries a per-interface validity verdict;
  the `RESET_ON_BOOT` removal path preserves all owned VLANs on a trunk (with a
  warning) when either pass's sample is untrustworthy. Additions still proceed on
  whatever positive evidence exists. Under the default `DETECT_METHOD=both`, only
  the primary **sniff** must have succeeded (a failed sniff is the actual removal
  hazard); LLDP is a supplement, so a down `lldpd` does not block removals
  (gate-4 H1). (`ver=` 0.4.4 -> 0.4.5.)
- The Debian `prerm` no longer proceeds with an upgrade/removal when a dynavlan run
  is still holding the FR-30 lock: it now **aborts** (like `install.sh` already
  did) instead of warning and letting dpkg swap the script under a live run, which
  could make the running invocation execute garbage mid-apply and strand the box.
  The lock is always created+opened (the previous `-e` check/use guard is gone),
  and if the abort happens after the rescan timer was stopped, the timer is
  restarted so a refused upgrade leaves the box exactly as it was (gate-4 H4).
  Maintainer-script only: the `dynavlan` script is unchanged, so **no `ver=` bump**.
- The APT-repo rebuild in the release workflow no longer silently drops packages.
  It previously listed only the 30 most recent releases (gh's default) and treated
  a failed `.deb` download as a warning, so after 30 releases the oldest versions
  fell out of the published repo, and a transient fetch error on the just-published
  version could ship a repo missing it, all with a green job. The step now lists all
  releases (`--limit 1000`, guarded), hard-fails when a release that has a `.deb`
  asset cannot be downloaded (while still skipping releases that legitimately carry
  none), and asserts both the downloaded count and the just-published version are
  present before publishing (gate-4 M2). CI workflow only: **no `ver=` bump**.
- `VLAN_LIMIT_MODE=fill` now keeps the lowest-**numeric**-id VLANs, matching the
  documented "lowest IDs" contract. It previously selected by lexicographic token
  order, so with VLANs 2/10/100 it kept 10 and 100 before 2 (gate-4 M7). (`ver=`
  0.4.3 -> 0.4.4.)
- A physical NIC whose name plus the `.<vlan-id>` suffix would exceed the 15-char
  kernel limit (IFNAMSIZ) - e.g. the MAC-derived `enx001122334455` - is no longer
  provisioned into an interface the kernel would reject; the over-long VLANs are
  skipped with a warning naming them (gate-4 H6). Full support for such NICs via
  generated short names is a post-1.0 item.
- Interface names containing `.` are refused at discovery (a dotted parent is
  ambiguous with dynavlan's own `<parent>.<id>` VLAN separator and could not
  round-trip in owned-state, provisioning once then vanishing). `-`/`_` remain
  supported and are now handled by an injective interface-key map, so names like
  `enp-1`/`enp_1` no longer alias to one another (gate-4 M1). Standard predictable
  and legacy NIC names are unaffected (they contain none of these characters).

### Removed

- `PER_VLAN_MAC` config key. It was reserved but never implemented: the only
  thing it ever did was refuse `true`. Rather than freeze that dead surface
  into the 1.0 config contract, it is removed. Per-VLAN MAC derivation stays a
  post-1.0 item (G-4); any future implementation adds its own key. `debian/postinst`
  neutralizes an uncommented `PER_VLAN_MAC=` line in an existing conffile on
  upgrade, so the removal cannot make a box refuse its own config. (`ver=` 0.4.2 -> 0.4.3.)

## [0.4.2] - 2026-08-05

### Added

- Public APT repository (GitHub Pages + `reprepro`, signed with a dedicated
  repo key) so `sudo apt update && sudo apt upgrade` picks up new dynavlan
  releases. Rebuilt from the GitHub release `.deb` assets on every release
  (nothing stored in git); manual/attended upgrades only by design, not
  structured for unattended-upgrades. `get.sh` is now apt-aware (adds the
  repo + installs via apt when apt/dpkg is present) and falls back to the
  existing tarball + `install.sh` path otherwise, or if the repo isn't
  reachable. No `ver=` bump - the `dynavlan` script itself is untouched.

### Fixed

- Apply-evidence gap on no-addition changes (C2): a removal-only reconcile or
  `--reapply` could ACCEPT a `netplan try` on elapsed time, sampling pre-apply
  routing on a slow apply. These changes have no in-kernel signal to observe
  (netplan try does not delete removed netdevs; a rerender changes no kernel
  state), so they now use a larger, bounded settle floor
  (`APPLY_NOEVIDENCE_SETTLE`) sized so the first health sample lands post-apply,
  and netplan try's exit is logged on both accept and revert paths instead of
  discarded. Additions are unchanged. (`ver=` 0.4.1 -> 0.4.2.)
- Config is now parsed declaratively instead of `source`d (H2). A line in
  `/etc/dynavlan.conf` could previously assign any internal/safety variable
  (`NETPLAN_FILE`, `TRY_TIMEOUT`, `ver`, `PATH`, ...) or execute arbitrary shell,
  because the file was sourced and only the documented keys' *values* were
  validated. `load_config` now honors only allowlisted `KEY=value` lines for the
  documented keys; an unknown/protected key or non-assignment line refuses the
  run, and values are assigned as inert literals (no code execution). The config
  surface is now exactly the documented keys. (`ver=` 0.4.1 -> 0.4.2.)
- Routed-mode default-route delete guard (C1). In routed mode (`VLAN_ROUTES=true`)
  a dynavlan VLAN can be the box's default egress. Removing it would strand the
  box: the `ip link delete` runs only after `netplan try` ACCEPTs, and the health
  check PASSes during the try (the VLAN is still up), so the delete tears down the
  default route post-ACCEPT with no revert. `apply_change` now refuses the whole
  reconcile before any disk change when the current default-route interface is in
  the removal set, preserving it and changing nothing until an alternate default
  exists; `--dry-run` previews the refusal. No-op at the default `VLAN_ROUTES=false`
  (the default is always the base uplink, never a dynavlan VLAN). (`ver=` 0.4.1 -> 0.4.2.)
- `--dry-run` now exits non-zero when `netplan generate` rejects the candidate
  config; it previously printed `validate: FAIL` but exited 0, so a scripted or
  attended pre-flight keying on `$?` could not tell a bad config from a good one.
  The printed line and `VALIDATE_ERRSRC` still distinguish our-YAML from a
  pre-existing base-file error. (`ver=` 0.4.0 -> 0.4.1.)
- Debian upgrades preserve the operator's timer/service state instead of
  unconditionally re-enabling and starting the timer on every configure. `prerm`
  records the prior enabled/active state before stopping; `postinst` restores it,
  so an upgrade never re-arms a `dynavlan.timer` the operator deliberately
  disabled. First install is unchanged (enable for next boot, never start). On
  the first upgrade FROM a pre-fix package the outgoing `prerm` cannot record
  state, so `postinst` falls back to live `is-enabled` (which `stop` does not
  clear) for the enable dimensions and infers the running-state from enablement:
  an enabled timer is assumed to have been running, a disabled timer is never
  started (`tmr_active` follows `tmr_enabled`). Hardware-validated (L3-37),
  including the transitional disabled case.
- `build-deb.sh` refuses to build when the requested version (the release job
  passes the git tag) differs from the script's `ver=`, so a tag that outran a
  `ver=` bump fails the build instead of publishing a package whose `--version`
  disagrees with its label (FR-38). Checked before the `dpkg-deb` requirement so
  the version mismatch is the reported failure.

## [0.4.0] - 2026-08-04

### Added

- Carrier-down VLAN removal (FR-41). When an owned trunk's physical link stays carrier-down across a two-sample debounce (`BOOT_SETTLE_SECONDS` apart) - at boot or on the rescan timer - and the box still has a healthy default route, dynavlan removes all owned VLANs on that trunk through the standard validated + health-gated + auto-reverting apply chain. A carrier-down port cannot pass frames, so this is a full teardown of the trunk's set, not a per-VLAN detection diff. Independent of `RESET_ON_BOOT`: governed solely by new config key `REMOVE_ON_CARRIER_LOSS` (default `true`), so a `RESET_ON_BOOT=false` box still self-heals a dead trunk. Rescan (previously strictly add-only) gains its first removal path; the settle sleep is incurred only when an owned trunk is actually carrier-down, so the steady-state fast path is unchanged. Narrows the prior preservation invariant: preservation now protects only genuine detection uncertainty (carrier-up, no tags) - carrier-down is authoritative kernel evidence and is no longer blanket-preserved. `--dry-run` previews a would-be teardown; `--status` reports carrier state per owned trunk. Two new pure helpers: `carrier_removals` (the debounce decision) and `have_routing` (the routing pre-condition - a carrier-down trunk that doubles as the box's own uplink, with no redundant route, is preserved rather than attempted). `have_routing` requires a lowest-metric default route, carrier on its egress iface, AND carrier on at least one physical NIC; the last clause keeps a tun/wireguard default route - those netdevs report carrier whenever merely configured up - from making an all-dark box look routable, while still allowing pruning on a box that legitimately routes over a VPN atop a live uplink. A zero detection no longer aborts the boot/rescan run: `run_detection` returns non-zero if and only if it saw nothing, so an rc-based abort could not distinguish a probe failure from a quiet wire and suppressed FR-41 in its own headline case (every owned trunk unplugged, leaving nothing to detect). A `BOOT_SETTLE_SECONDS` below 5 is clamped to 5 for the carrier samples only (and only while the knob is on): back-to-back samples cannot tell a port bounce from a sustained loss, and clamping rather than rejecting avoids turning an already-deployed conffile into a boot-time config failure. **Supersedes** the hardware-validated v0.2.0 "L3-30 carrier-pull preserve" result with a revised "carrier-pull prune" case (`dev/features/dynavlan-tests.md`). Hardware-validated 2026-08-04 on the Protectli box, all 6 L3-30 sub-cases PASS: carrier-pull prune, re-plug re-add, flap-shorter-than-settle preserve, own-uplink-no-redundancy preserve, `--boot` prune, post-boot re-add.

## [0.3.0] - 2026-07-30

### Added

- Restart on a newly-appeared IPv4 subnet (FR-40). Previously, dynavlan only restarted `RESTART_SNAPS`/`RESTART_SERVICES` on a tagged-VLAN change, so two cases were missed: an access port or native-only trunk that gets a DHCP lease after boot (no tagged VLAN, so nothing changes), and the monitoring agent starting before the base interface finishes DHCP (dynavlan's boot run is deliberately not ordered after `network-online.target`). Both are the same underlying problem: the agent cares about IPv4 subnets it can scan, not VLAN tags. New pure helper `ipv4_network` keys subnet tokens on the network address, not the host address, so a same-pool DHCP renewal never restarts; a monotonic per-uptime seen-set at `/run/dynavlan/seen` (wiped on reboot) means a flap back onto an already-seen subnet doesn't either, and an empty seen-set at boot restarts once after settle regardless of boot-vs-DHCP ordering. At most one restart per run, deduped against any VLAN-driven restart. New config key `RESTART_ON_NEW_SUBNET` (default `true`). `--dry-run`/`--status` report the would-restart delta without restarting or writing the seen-set. `apply_change` is unchanged; the growth-check is an additive post-step called from `main` after every `--boot`/`--rescan` exit, regardless of that mode's own return code.

## [0.2.1] - 2026-07-30

### Fixed

- `backend_list_managed_vlans` awk assumed `link:` precedes `id:` in `netplan get` output, but netplan 0.107 emits `id:` first. The netplan-get exclusion source silently returned nothing, falling back to `ip -d link` single-source (FR-10 degraded). Found in code review; verified on hardware. 3 tests added.

## [0.2.0] - 2026-07-30

### Added

- **All-trunks provisioner** (redesign): dynavlan now provisions VLANs on every carrier-up trunk with detected tags, not one selected trunk. A box with two live trunks (validated: `enp1s0` and `enp2s0`, each with a different native VLAN, one VLAN id tagged on both) gets both provisioned in one reconcile. The universal token for every set downstream of detection is now `iface.id` (e.g. `enp1s0.100`), not a bare VLAN id: bare ids alias across parents the moment two trunks share an id. New pure token helpers: `emit_tokens`, `tok_iface`, `tok_id`, `tag_tokens`, `untag_tokens`, `tokens_for_iface`, `distinct_ifaces`. `do_boot`/`do_rescan`/`do_dryrun` loop per-trunk candidate/removal math over the union of owned and detected trunk interfaces, tag each trunk's result to tokens, then combine into one token set and make a single unified `apply_change`/`netplan try` call for the whole box. Hardware-validated 2026-07-30 (L3-29 dual leasing, L3-30 carrier-pull preserve, L3-31 routed multi-trunk, L3-32 unified revert, all PASS).

- `dynavlan --reapply` (FR-39). Regenerates the owned set with the running build and applies it only if the generated body differs from what is on disk, through the full `netplan try` + health-check chain. Runs no detection (pinned to the owned parent), never adds or removes a VLAN, lease-waits the entire owned set before restarting targets, bypasses the count gate, and blocks on the run lock rather than reporting a misleading rc-0 "skipped." The comparison ignores line 1 (version/build header), so an FR-38 build stamp change alone cannot force a no-change apply. Refuses if it generates a candidate config it cannot read back.

- `dynavlan --version` (alias `-V`) and install-stamped build identity (FR-38). Prints `dynavlan <ver> (build <commit>)` and exits before the config load and root check, so it works when the config is invalid or the caller is unprivileged. `install.sh` stamps the source checkout's short commit, suffixed `-dirty` when the tree has uncommitted changes. The same string appears on every `run start:` journal line and in the generated netplan file's header.

- Opt-in routed mode (FR-37): `VLAN_ROUTES=true` accepts DHCP routes on discovered VLANs at per-VLAN metrics; `VLAN_ROUTE_METRIC_START` (default 100), discovery-order assignment shared across the whole box (existing VLANs never renumber, persisted in the owned YAML). Refuses up front if any assigned metric would match or beat the uplink default's metric. DNS/NTP/domains stay declined in both modes.

### Changed

- `backend_owned_vlans`/`backend_owned_metrics` now parse `iface.id` stanza headers across however many parents the owned file spans. `backend_list_managed_vlans` takes an `iface` argument and is scoped per trunk. `plan_route_metrics`/`assign_route_metrics`/`map_filter`/`metric_conflict`/`map_ids` all operate on `iface.id:metric` maps rather than bare-id maps.

- `VLAN_MIN` default is now 1 (was 2). The old default encoded "VLAN 1 is the switch management VLAN" as if it were a fact about the wire; a validated Meraki trunk broke it in both directions. `VLAN_IGNORE` remains the way to skip specific IDs.

- `RESTART_SNAPS` default is now empty (was `domotzpro-agent-publicstore`); the Domotz agent snap is the documented example, not a baked-in default.

- Install docs recommend `sudo bash install.sh` over `sudo ./install.sh`. Transfers that do not carry Unix modes strip the executable bit; invoking the interpreter is immune.

- `--dry-run` now takes the run lock non-blocking: holds it during the preview if free; warns and proceeds read-only if a run is already in progress.

- Positioning reframes dynavlan from a single-trunk monitoring provisioner toward a general dynamic-VLAN provisioner with a monitoring origin; isolation stays the default, routed mode is first-class.

### Removed

- `select_trunk` and its hysteresis contest. There is no longer a "which NIC is the trunk" decision.

- AC-3 relocation branch: a trunk that goes dark has its owned VLANs preserved, never torn down and rebuilt on a different NIC.

- `VLAN_ROUTE_METRIC_MODE` (and its `id` mode). Metric assignment is discovery-order only, since a stateless START+id scheme has no coherent meaning once VLAN ids are no longer globally unique keys.

- Domotz-on-Ubuntu deployment runbook and base-deployment spec (`docs/deployment-guide.md` rewritten as the dynavlan deployment guide; `dev/IMPLEMENTATION-SPEC.md` deleted).

### Fixed

- Routed mode (FR-37) could only be enabled on a box that already owned VLANs. `apply_change` passed additions to `assign_route_metrics`, but the correct set is "target ids without a metric." Assignment now lives in one pure `plan_route_metrics` that every caller must use. No stranding risk: the refusal preceded `netplan try`.

- `lldp_tagged_vlans` matched any key ending in `.vlan-id=` / `.pvid=yes` rather than the VLAN TLV's `.vlan.` subtree. A foreign key inside a VLAN block flushed the real id as "tagged" before its `pvid=yes` was seen, and leaked the foreign key's value as a candidate. Patterns now anchor on `.vlan.vlan-id=` / `.vlan.pvid=yes`; two regression cases added.

- LLDP detection ingested the native/pvid VLAN as if it were tagged (FR-7a). New pure helper `lldp_tagged_vlans` correlates each `vlan-id` with its adjacent `pvid` and drops the native VLAN. Found on hardware (Meraki trunk advertising pvid 100).

- VLANs accepted IPv6 Router Advertisements (FR-14a), so "fully route/DNS-isolated" was only true for IPv4. networkd accepts RAs by default; a VLAN could acquire a SLAAC address and a default route invisible to the FR-18 health check. Every generated VLAN now carries `accept-ra: false`. Found on hardware.

- Detection counted the box's own transmitted frames, making it self-fulfilling (FR-5a). The sniff now uses `-Q in`; missing `-Q` support is a refuse-to-run precondition. Found on hardware.

- Rescan timer never fired, on any install (FR-21a). `--reconfigure` rendered a drop-in that cleared `OnUnitActiveSec`, which in systemd resets the entire monotonic timer list. The drop-in now restates every trigger using `OnActiveSec`. Found on hardware.

- `install.sh` could replace `/usr/local/sbin/dynavlan` underneath a running invocation. The installer now stops `dynavlan.timer` for the duration and takes the FR-30 lock before touching the script.

- FR-0 netplan version precondition refused to run on every target box. `netplan --version` only exists on >= 1.0; the validated baseline ships 0.10x. Version discovery now falls back to `dpkg-query -W netplan.io`.

- `restore_prior` now checks its copy-back and logs `err` naming the surviving backup on failure.
