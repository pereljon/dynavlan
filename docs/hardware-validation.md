# Hardware validation

Where dynavlan's validated hardware and its latest console-backed validation pass
are recorded. This is a living doc: the checklist and sign-off below are rewritten
in place each release; prior passes are recoverable via git tags
(`git show v0.4.2:docs/hardware-validation.md`).

## Validated hardware

dynavlan is hardware- and vendor-agnostic by design; this table records the gear it
has actually been validated on, not a hardware requirement.

| Component | Validated on |
|-----------|--------------|
| Appliance | Protectli (Intel igb NICs), dual trunk ports |
| OS / stack | Ubuntu 22.04, netplan >= 0.106 with the systemd-networkd renderer |
| Switches (detection) | Meraki (edge trunk), UniFi (edge trunk + access port) |
| Monitoring agent (restart hook) | Domotz snap |

Any netplan/systemd-networkd box on any switch vendor should work; the above is the
maintainer's validation bed. Latest completed sign-off: the v1.0 final-build pass on `0.4.22` (build `01e9f98`), 2026-10-12/13: HV-01 on 0.4.21 (Group 0 record) and batches 2 and 3 below, with HV-31 still release-gated (see "Pending: final-build pass"). The v0.4.11 pass of 2026-08-06 is kept below for history.

---

## Completed pass (v0.4.11, gate-4 group-5 accumulation)

Consolidated console-backed validation of everything merged between v0.4.2 and
v0.4.11, run once rather than per-fix. This section is a historical record of that
run: the per-phase results are in the sign-off below (the per-check Pass boxes in
the tables were not individually ticked). Phase 3b.2 and the Phase 4.1 positive
C1 case were deferred. Console-backed only: a bad apply drops SSH, so drive from
the serial console, never SSH-only.

**Build-identity gate (FR-38).** Before drawing any conclusion from behavior,
confirm the running build. That pass ran on a locally built `.deb` of the then-`main`
HEAD (0.4.11, later tagged `v0.4.11`). For any future pass, install the build under
test (a source install stamps the commit) and verify the running build matches the
expected commit:

```
git -C <repo> rev-parse --short HEAD   # the expected build id
dynavlan --version                     # dynavlan <ver> (build <that short commit>)
```

A `-dirty` suffix means the tree had uncommitted changes: rebuild from a clean
`main` first. If the build id does not match HEAD, stop - you are testing the wrong
code. Deploy steps: `docs/deployment-guide.md` §2 (source/tarball path).

**Redaction.** If you paste journal/capture excerpts back, redact any real MAC to
`00:00:5e:00:53:xx` first (public repo).

---

## Not validated on hardware by design (skip - unit-covered, fail-safe)

These need an **injected** failure that cannot be staged on the Protectli, and
each fails toward no-change/reachable. Unit coverage is the accepted substitute;
do not chase them at the console.

- **M4** - carrier drop in the detection->apply window (guard only ever drops additions).
- **M5** - a transient `ip link delete` failure (record + retry is reboot-scoped, ownership-safe).
- **H1** - a sniff/LLDP/promisc wire failure (preserve-only direction).
- **H6** - over-`IFNAMSIZ` interface names (box uses short `enp` names).

---

## Phase 1 - Happy-path smoke (no switch reconfig)

| # | Check | Do | Expect | Pass |
|---|-------|----|--------|------|
| 1.1 | Build id | `dynavlan --version` | `0.4.11 (build b0317b6)`, no `-dirty` | [x] |
| 1.2 | Status static report | `sudo dynavlan --status` | owned / owned-trunks / per-trunk `carrier=up\|down` / `detect_method`+`range`+`ignore` all print | [ ] |
| 1.3 | Status per-trunk columns (M8/FR-35) | same output | each **detected** trunk line shows `detected=[..] ignored=[..] out-of-range=[..] managed-elsewhere=[..]` | [ ] |
| 1.4 | Status exit 0 when healthy | `sudo dynavlan --status; echo $?` | `0` | [ ] |
| 1.5 | **M8 dep-gate** | capture the path first, then hide the tool (DETECT_METHOD default `both` needs lldpctl): `L=$(command -v lldpctl); sudo mv "$L" "$L.bak"`, then `sudo dynavlan --status; echo $?` | static report still prints; detection line = `detected trunks: unavailable (...)`; exit **non-zero**. Then **restore**: `sudo mv "$L.bak" "$L"` and re-run 1.4 to confirm exit 0 again | [ ] |
| 1.6 | Dry-run read-only | `sudo dynavlan --dry-run; echo $?` | per-trunk diff + count gate preview; **no apply**; exit `0` (non-zero only if netplan validation FAILs, M3) | [ ] |
| 1.7 | No-change reconcile | `sudo dynavlan --boot` (or `--rescan`) with config unchanged | journal shows a run start with the build id; **no** `netplan try`, no revert, no restart; box stays reachable | [ ] |
| 1.8 | **M5 drain no-op** | during 1.7, watch the journal | `drain_pending_deletes` runs clean (file `/run/dynavlan/pending-delete` absent -> early return, nothing stranded) | [ ] |

## Phase 2 - Lease + restart timing (H5) - needs a real multi-VLAN add

| # | Check | Do | Expect | Pass |
|---|-------|----|--------|------|
| 2.1 | **H5 box-wide lease deadline** | trigger an apply that ADDS >=2 VLANs (e.g. widen `VLAN_MIN/MAX` or clear part of the owned set, then `sudo dynavlan --boot`) | after ACCEPT the lease wait is ONE bounded pass over all pending tokens, **not** N x `LEASE_SETTLE` in series; total stays well under the systemd `TimeoutStartSec` and the restart fires. Confirm via journal timestamps | [ ] |
| 2.2 | Restart after apply | same run | `restarted snap/service ...` logged once after the leases settle | [ ] |

## Phase 3 - Restart-failure -> seen-set (M6) - stageable, may need a new subnet

| # | Check | Do | Expect | Pass |
|---|-------|----|--------|------|
| 3.1 | **M6 total failure holds subnet unseen** | set `RESTART_SERVICES="dynavlan-nonexistent.service"` (only a bogus target), induce a new IPv4 subnet (add a VLAN that leases), `sudo dynavlan --rescan` | restart fails; `/run/dynavlan/seen` does **not** gain the new subnet; next `--rescan` retries the restart (subnet still "new") | [ ] |
| 3.2 | **M6 partial success consumes** | add a REAL target alongside the bogus one (`RESTART_SERVICES="<real> dynavlan-nonexistent.service"`), repeat | the real target restarts; the subnet **is** recorded seen; next run does NOT re-restart (no storm) | [ ] |

## Phase 3b - Script-death mid-apply (P2) - the FIFO-EOF assertion the code marks unvalidated

| # | Check | Do | Expect | Pass |
|---|-------|----|--------|------|
| 3b.1 | **P2 kill mid-`netplan try`** | during an apply that would ACCEPT, `sudo kill -9` the dynavlan process while `netplan try` is running (before the accept newline) | `netplan try` sees the dead writer / no confirmation and **reverts** to the pre-apply config; box returns to the snapshot default route; no interface left deleted | [ ] |
| 3b.2 | P2 systemd-timeout variant | let the run exceed the service `TimeoutStartSec` so systemd kills the cgroup mid-apply | same revert-to-prior outcome; confirm whether the same-cgroup kill takes `netplan try` down with it or it survives to its own timer revert (record which) | [ ] |

## Phase 4 - Switch-access-gated (schedule when you can reconfigure the switch)

| # | Check | Do | Expect | Pass |
|---|-------|----|--------|------|
| 4.1 | **C1 positive-refusal** | routed mode (`VLAN_ROUTES=true`) so a dynavlan VLAN carries the box default route; then force that VLAN into the removal set (drop its tag on the switch; narrowing `VLAN_MIN`/`VLAN_MAX` or adding it to `VLAN_IGNORE` does NOT remove an already-owned VLAN) and `sudo dynavlan --boot` | dynavlan **refuses the whole reconcile before any disk change** (`default_iface_in_removals`); default route intact; box reachable; nothing deleted | [ ] (deferred: the faithful positive-refusal case was not run) |
| 4.2 | **L3-30 carrier-pull PRUNE** (revised; validated 2026-08-06, see sign-off) | pull the owned trunk's cable; let two carrier samples elapse across the debounce; `sudo dynavlan --rescan` | that trunk's entire owned set is **pruned** (not preserved), gated on healthy `have_routing`; re-plug + `--rescan` re-provisions | [ ] |

---

## Sign-off

Completed 2026-08-06, console-backed on the Protectli box, build `b0317b6` (0.4.11),
installed from a locally-built `.deb` over the box's prior 0.4.2 test build.

| Item | Result | Build id | Notes |
|------|--------|----------|-------|
| Phase 1 (smoke + M8) | PASS (8/8) | b0317b6 | M8: hidden lldpctl -> `detected trunks: unavailable`, exit 1, restored to exit 0. M5 drain: `pending-delete` absent, early return. No-change reconcile: no netplan try, no restart. |
| Phase 2 (H5) | PASS | b0317b6 | Re-add of 7 `enp1s0.*`: ACCEPT -> 7 leases in **179 ms** (one bounded pass, not per-VLAN serial) -> restart once; run 76s << 600s TimeoutStartSec. Domotz restart confirmed by ExecMainStartTimestamp. Fast-DHCP caveat: does not contrast vs the old serial path (structural fix is unit-covered). |
| Phase 3 (M6) | PASS | b0317b6 | Total failure (bogus-only target): new subnets held OUT of `seen`, retried next run. Partial success (real snap + bogus service): snap restarted, subnets recorded, next run no re-restart (no storm). Staged by clearing `/run/dynavlan/seen`. |
| Phase 3b (P2 kill-mid-apply) | PASS (3b.1) | b0317b6 | `kill -9` the dynavlan writer during `netplan try` (via a perturbed `--reapply` to open a real try window; applied config == canonical, safe): FIFO EOF -> netplan try reverted+exited ~4.3s later (<< 30s timer), 14 ifaces intact, box reachable. enp1s0 base default briefly dropped during the revert reconcile, DHCP-recovered. 3b.2 (systemd-cgroup kill) not run - secondary variant, core EOF path validated. |
| Phase 4 (C1, L3-30) | L3-30 PASS; C1 positive DEFERRED | b0317b6 | L3-30 carrier-pull PRUNE on 0.4.11: enp1s0 down -> 20s debounce -> 7 VLANs pruned via netplan try (removal-only accept ~18.2s, C2 floor), enp2s0's 7 preserved, box reachable; re-plug re-add PASS. C1 true-negative observed live (no isolated VLAN was default, guard silent). C1 POSITIVE refusal still deferred (needs routed-mode + switch to make a dynavlan VLAN the default route). |

Findings recorded in `context/todo.md`; SKELETON P2/FIFO-EOF status and the tests-doc
L3-30 note updated. Preserve-biased behavior confirmed along the way: neither
`VLAN_MAX` narrowing nor `VLAN_IGNORE` prunes an already-owned VLAN, and `--reapply`
no-ops when the on-disk yaml already matches the generated config.

---

## Group 0 record (v1.0 review, pre-remediation build)

Console-backed, on the clean pre-remediation `0.4.13 (build e3f2cef)` before the review
fixes: HV-00 (baseline and recovery rehearsal) PASSED. HV-01 (whole-cgroup stop of the
rescan service during an applied-but-unconfirmed `netplan try`) FAILED: stopping the unit
killed both the script and `netplan try`, no revert occurred, and the candidate stayed live
and on disk (finding D2). The box was restored to its recorded 14-VLAN baseline. The fix
(`KillMode=mixed`, SIGTERM handling before ACCEPT, `ver=` 0.4.15) was exercised on the corrected build `0.4.20 (build d9b3618)` on 2026-10-09: HV-01 is
**PARTIAL**. Stopping the rescan service during a live, unaccepted `netplan try` withheld the
confirmation, the child exited, the owned YAML was restored byte-for-byte, no post-accept work ran, the
original defaults survived, and the run ended rc 1 in about 6.5 seconds. But the candidate VLAN link kept
its DHCP address and its generated `/run/systemd/network` files after the revert, so the "prior
configuration live" criterion is not met; see the open rollback question in `context/open_questions.md`.
The cause was a real `netplan generate` before the try, which put candidate files into `netplan try`'s runtime backup; `ver=` 0.4.21 validates in an isolated root instead. HV-01 on the corrected artifact (2026-10-12, `0.4.21 (build 72d9eea)`): a stop during a live, unconfirmed `netplan try` exited in 5.9 s with no confirmation or post-accept work, the owned YAML and defaults were unchanged, and `/run/systemd/network` was byte-identical to the pre-run state with no candidate files or parent reference. The candidate kernel link persisted with its DHCP address and connected route (FR-24), recorded separately and removed by hand at the console. **D2 is closed** (2026-10-12); the retained link is an operator-accepted limitation (FR-43, recovery in the deployment guide, section 5). A routed-mode revert and full kernel convergence are not proven.
D2 closure is pending that disposition.

---

## Final-build pass, batch 2 (2026-10-12, `0.4.21 (build 72d9eea)`)

Console-backed, timer stopped, every config and record variant restored and checksum-verified; a temporary VLAN 995 (DHCP, one test container as the traffic source) was created and removed by recorded IDs. Box, switch and controllers ended equal to their pre-batch backups (the owned YAML differs only in its header, now written by 0.4.21).

| Case | Result |
|------|--------|
| HV-10 external Netplan key | PASS: keys `en-vpn` and `vlan995x`, either field order, read as managed elsewhere and excluded from additions; removing the file restored the proposal |
| HV-40 detection link flags | PASS: with promiscuous mode off on `enp2s0`, `--status` and `--dry-run` turned it on (FR-2) and changed no file or record |
| HV-41 runtime detector failure | **FAIL** (fails safe): with `DETECT_METHOD=lldp` and lldpd stopped, `lldpctl` (lldpd 1.0.13) exits 0 with empty output, so `--status` reported `detected trunks: [none]` with rc 0 instead of unavailable/non-zero; the dry-run proposed no additions or removals |
| HV-42 count gate | PASS: `refuse` exits 1 with no change and skips validation; `fill` stops at the limit and validates |
| HV-43 quiet wire | PASS: with port 6's tagged VLANs blocked (carrier and native kept), the dry-run preserved the owned set and still previewed the pending re-delete, the unseen subnet, the target, the count gate and validation, without changing either record |
| HV-44 status rows (live part) | PASS: shared rows and a configured-but-undetected row match kernel and wire state |
| HV-45 zero restart targets | PASS: the add left the new subnet unseen ("no restart targets"); with one target the next rescan restarted it once, the following one did not |
| HV-50 config grammar | PASS: canonical and quoted-then-comment values load; leading zero, empty element and unclosed quote refuse before detection with no arithmetic diagnostics |
| HV-51 ignore/range narrowing | PASS: an owned VLAN in `VLAN_IGNORE`, then outside `VLAN_MAX`, stayed owned through status, dry-run, rescan and a two-pass `--boot` |
| HV-52 routed metrics | PASS: unit test on the box (871/0) for lexical order and persistence; live metrics 1000-1014, distinct and above the uplinks (10, 20) |
| HV-53 generated policy | PASS: a rescan did not rerender; `--reapply` applied routed mode through `netplan try`; a second reapply and a metric-start change were no-ops; `--reapply` back to isolated restored the owned YAML byte-for-byte |
| HV-22 package refusal | PASS: with the timer unstoppable, `dpkg -i` exited 1 before replacing the script; package, binary and timer state unchanged |
| HV-24 reconfigure (live part) | PASS: rc 0, drop-in correct, finite next elapse |

The attended `--boot` removed the temporary VLAN after it left the wire; detection ignored the box's own outbound frames on it.

## Final-build pass, batch 3 (2026-10-12/13, `0.4.22 (build 01e9f98)`)

Clean package from `01e9f98` (sha256 `a7e113da...b3f7faa4`); install.sh lanes ran from a clean clone at the same commit. Console-backed with three reboots; ended equal to its starting state (config, owned YAML body, base Netplan files, timer drop-in, units, 14 VLANs, defaults), with the owned YAML header now written by 0.4.22.

| Case | Result |
|------|--------|
| HV-21 normal upgrade | PASS: `dpkg -i` 0.4.21 -> 0.4.22 from enabled/active returned to enabled/active, no reconcile during the swap |
| HV-41 LLDP detector failure (recheck) | PASS: with lldpd stopped and `DETECT_METHOD=lldp`, `--status` reports detection unavailable and exits 1, `--dry-run` preserves every owned VLAN; with lldpd restored, `--status` exits 0 |
| HV-61 default-route refusal | PASS via a controlled route override (a temporary metric-5 default through owned `enp1s0.100`; routed mode cannot make a VLAN the default because dynavlan refuses a VLAN metric at or below the uplink's): `--teardown` refused before any disk or link change |
| C1 positive refusal (Phase 4.1) | ACCEPTED on shared-guard evidence: the HV-61 default-route refusal above is a real positive refusal by the same `apply_change` default-route guard that `--boot` uses, together with the local mode and dry-run tests. The switch-induced `--boot` scenario is NOT EXERCISED: the switch controller kept the temporary VLAN excluded on the box's port after the intended settings were applied twice, and no other switch method was tried |
| HV-60 remove and purge | PASS: remove keeps the conffile, removes the script, units and wants links, and makes no Netplan or link call; after a reboot no unit invokes the missing script and the retained owned YAML recreates the VLANs. Purge removes the conffile and the timer drop-in. Reinstalling over the removed state leaves both units disabled (no prior-state record), so the operator re-enables them |
| HV-61 teardown | PASS: refuses with the timer enabled, with it active, and with the run lock held past 300 s; the real teardown removes every owned VLAN through `netplan try` with base files and defaults unchanged; re-enabling and an attended `--boot` recreate the set |
| HV-20 direct upgrades | PASS: enabled/active returns to enabled/active, disabled/inactive stays so, no reconcile during the swap, build matches the clone |
| HV-22 direct installer | PASS: with the timer unstoppable, `install.sh` exits 1 before replacing the script |
| HV-23 restoration failure | PASS: `install.sh` exits 1, reports that the timer could not be restarted and prints no completion line |
| HV-25 config migration | PASS: `PER_VLAN_MAC=false` is commented out once, a second upgrade changes nothing, the rest of the config is byte-identical |
| HV-21 manual-to-package migration | PASS: the first `dpkg -i` over a disabled/inactive manual install removes the `/etc` unit copies, keeps both units disabled and the timer inactive; after a reboot neither unit was enabled or started |
| HV-02 pristine install | PASS: from a state with no package, units, config, record or process, `dpkg -i` enables both units for the next boot and leaves the timer inactive with no run; after a reboot the boot reconcile ran under 0.4.22 and the timer runs on schedule |
| HV-90 final observation | PASS: a real timer rescan reported no changes; `--status` and `--dry-run` clean |

Control-path deviations, recorded as they happened: the serial console has no autologin and sat at a login prompt after each reboot, so the S4 refusals, teardown and recovery `--boot` ran over SSH to the base address `192.168.100.118` (on no VLAN, so teardown could not cut that session), and reboot 3 was issued over SSH after a reboot command typed at the console login prompt failed as a login. The observed results stand; base-address SSH does not replace the console-only rule, and future destructive or reboot work needs an authenticated console shell first.

## v1.0 review: finding closure

Hardware evidence is on `0.4.20`-`0.4.22` from the records above; "local" means unit, lifecycle-harness or dry-run evidence that Codex accepted for the pass.

| Finding | Remediation | Evidence | Status |
|---------|-------------|----------|--------|
| D1 pending-delete default guard | Group 1 (`bf59ab0`) | local; shared default guard shown live in HV-61 | closed |
| D2 stop during `netplan try` | Groups 2a, `72d9eea` | HV-01 on 0.4.21 | closed; retained candidate link accepted (FR-43) |
| D3 APT publication | Group 3 (`34bed4e`) | local; HV-31 needs a real release | open until a release |
| D4 status/dry-run link mutations disclosed | Group 4 | HV-40 | closed |
| D5 detector failure reported as `[none]` | Group 4, `01e9f98` | HV-41 on 0.4.22, HV-44 | closed |
| D6 fresh install vs migration | Group 2 | HV-02, HV-21 | closed |
| D7 removal lifecycle | Group 6 | HV-60, HV-61 | closed |
| D8 direct upgrade re-enables units | Group 2 | HV-20 | closed |
| D9 failed upgrade leaves timer stopped | Group 2 | HV-22 (package), HV-21; fault branches local | closed |
| D10 reload failure reported as success | Group 2 | HV-24 live; injected failures local | closed |
| D11, D12, D13, S1, L16 documentation | Group 8 | review | closed |
| S2, S3 dry-run planning | Group 4 | HV-42, HV-43 | closed |
| L1 external Netplan keys | Group 1 | HV-10 | closed |
| L2 config grammar | Group 5 | HV-50 | closed |
| L3 prerm continues after a failed stop | Group 2 | HV-22 | closed |
| L4 `get.sh` cleanup | Group 3 | local | closed locally; exercised with a release |
| L5 direct upgrade hides a failed timer restore | Group 2 | HV-23 | closed |
| L6, L7 honest apply reporting, pending-delete ownership | Group 1 | local; HV-01 reporting | closed |
| L8 dry-run base-copy failure | Group 4 | local (HV-46) | closed |
| L9 quiet-wire dry-run | Group 4 | HV-43 | closed |
| L10 no-target subnets | Group 4 | HV-45 | closed |
| L11 ignore/range preserve | Group 5 | HV-51 | closed |
| L12 routed metric order | Group 5 | HV-52 | closed |
| L13 status union rows | Group 4 | HV-44 | closed |
| L14 generated policy needs reapply | Group 5 | HV-53 | closed |
| L15 `PER_VLAN_MAC` direct migration | Group 2 | HV-25 | closed |
| T1 direct test evidence | Group 7 | HV-70 on the target OS | closed |
| Rollback runtime-backup contamination (found in HV-01) | `72d9eea` | HV-01 on 0.4.21 | closed |
| HV-41 LLDP zero-exit failure (found in batch 2) | `01e9f98` | HV-41 on 0.4.22 | closed |
| C1 positive refusal (gate-4 carry-over) | earlier release | HV-61 shared guard | accepted; switch-induced `--boot` not exercised |

Open low-severity wording, recorded and not fixed: teardown after a default-route refusal also prints "teardown not completed (the apply was not accepted or ended uncertain)"; HV-23 repeats its restart error 3-4 times.

## Pending: final-build pass

The console-backed pass on the final build is complete apart from the row below (HV-01/D2 and batches 2 and 3 are done, see above). Nothing below has passed on
hardware; the unit suite and local lifecycle tests do not close these. Historical results
above stay tied to the builds they were run on.

| Area | Cases | Relates to |
|------|-------|--------|
| Published package reaches the box | HV-31 | D3 (only an authorized release can prove it) |

Before the pass: confirm the running build with `dynavlan --version` (a `-dirty` suffix or
a wrong build id means stop), and keep a console open. A teardown or any destructive case
needs a recorded way back to the baseline.
