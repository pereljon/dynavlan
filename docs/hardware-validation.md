# Hardware validation

This file records the hardware dynavlan was validated on and the dated
console-backed validation passes.

- Each pass keeps its own dated section. Earlier passes stay as history.
- The latest pass is first. The oldest pass (v0.4.11) is last, under "History".
- Older versions of this file are in git tags (`git show v0.4.2:docs/hardware-validation.md`).

## Missing-VLAN removal pass (2026-10-16 UTC, `1.1.1 (build 1df3567)`)

Console-backed on the reference appliance. Commands ran over SSH to the `enp2s0` base address, and the serial console stayed open as the fallback. The package was built from a clean `1df3567` (sha256 `5cd6f3e7...9cadca91`) and installed with `dpkg --force-confold -i` over the 1.0.0 package, with the timer stopped first. `--version` reported `1.1.1 (build 1df3567)`. Config was at defaults, except for the MV-H6 step.

Starting state: on 2026-10-15 the operator set switch ports 5 and 6 to access mode (`forward: native`, tagged VLANs blocked). The box still owned all 14 VLANs on both trunks, with no addresses. That is the 1.0.0 defect this release fixes. Port 6 changes below were made through the UniFi controller API: a full `port_overrides` backup, one change per write, then a re-read diff. No other port changed.

| Case | What ran | Result |
|------|----------|--------|
| MV-H6 | `REMOVE_MISSING_MINUTES=0`, then `--status` and `--rescan` | PASS. Status said `off`; the rescan changed nothing; no record file; owned file unchanged. |
| (record) | Key back at the default, `--rescan`, then `--status` | PASS. 14 warnings with 15 minutes left; 14 record lines; `--status` showed 14 minutes left and did not write. |
| MV-H4 | Reboot | PASS. The boot run recorded 14 clocks (uptime 204), logged 14 warnings and removed nothing. |
| MV-H1, MV-H5 (as found) | Wait after boot, both ports in access mode | PASS. The 00:29 rescan removed all 14 VLANs about 15.5 minutes after the boot sample. `netplan try` was accepted in 21 s, links were deleted after ACCEPT, both base addresses and default routes stayed, and the record was cleared. |
| MV-H7 | Port 6 set to trunk (native 100, 996 to 999 excluded) | PASS. The next rescan added `enp2s0.1`, `.21`, `.22` and `.101`. VLANs 18, 20 and 200 sent no frames in the 60 s sniff and were not added (passive detection, PRD R-1). |
| MV-H2 and MV-H3 | Exclude VLANs 21 and 22 on port 6; re-include 21 after two missed rescans | PASS. Both clocks started at 00:40:25. 21 was seen at 00:50:31, its clock cleared and it was kept. Only `enp2s0.22` was removed, at 00:55:56. |
| MV-H5 (trunk to access) | Port 6 set from trunk to access mode | PASS. 15 minutes after the first miss, at 01:16, the rescan removed `enp2s0.1`, `.101` and `.21`; `enp2s0` kept its address and default route. |
| Port 6 restored (MV-H7 again) | Port 6 set back to trunk | PASS. At 01:21 the rescan re-added `enp2s0.1`, `.21`, `.22` and `.101`. |

End state: the box runs `1.1.1 (build 1df3567)` with the timer active and config at defaults. Port 6 is a trunk with 996 to 999 excluded, and the box owns `enp2s0.1`, `.21`, `.22` and `.101`. Port 5 stays in the access mode the operator set, so `enp1s0` owns no VLANs.

Not exercised on hardware: a routing loss during the FR-41 settle with a due missing VLAN (I1), and a failed record write (I2). Both are unit-tested in `tests/unit.sh` §1az.

## Status for 1.0.0

dynavlan 1.0.0 is validated on the reference appliance below. Every pass was console-backed. In batch 3, some steps ran over SSH to the base address because the console had no logged-in shell after reboots (see "Final-build pass, batch 3").

| Evidence | Build | Date | Result |
|----------|-------|------|--------|
| HV-31, the published package | 1.0.0 (`633f35e`) | 2026-10-13 | PASS. APT upgrade from 0.4.22 works. D3 is closed. See "HV-31". |
| Final-build pass, batch 3 | 0.4.22 (`01e9f98`) | 2026-10-12/13 | Every run case PASS. See "Final-build pass, batch 3". |
| Final-build pass, batch 2 | 0.4.21 (`72d9eea`) | 2026-10-12 | 12 cases PASS, 1 FAIL (HV-41, fails safe). HV-41 passed on the recheck in batch 3. |
| HV-01, stop during `netplan try` | 0.4.21 (`72d9eea`) | 2026-10-12 | D2 is closed. See "Group 0 record". |

Not exercised:

- The switch-induced `--boot` refusal (Phase 4.1, C1 positive). The switch controller kept the test VLAN excluded on the box's port. The same default-route guard was shown to refuse in HV-61, so C1 is accepted on that evidence.
- A revert in routed mode, and full kernel convergence after a revert. Neither is proven.

## Validated hardware

dynavlan is hardware- and vendor-agnostic by design. This table lists the gear it was validated on. It is not a hardware requirement.

| Component | Validated on |
|-----------|--------------|
| Appliance | Protectli (Intel igb NICs), dual trunk ports |
| OS / stack | Ubuntu 22.04, netplan >= 0.106 with the systemd-networkd renderer |
| Switches (detection) | Meraki (edge trunk), UniFi (edge trunk + access port) |
| Monitoring agent (restart hook) | Domotz snap |

Any netplan/systemd-networkd box on any switch vendor should work. The table above is the maintainer's validation bed.

---

## Rules for a pass

Run every pass from the serial console. A bad apply drops SSH, so never drive a pass over SSH only.

### Build-identity gate (FR-38)

Confirm the running build before you draw any conclusion from behavior.

1. Install the build under test. A source install stamps the commit.
2. Check that the running build matches the expected commit:

```
git -C <repo> rev-parse --short HEAD   # the expected build id
dynavlan --version                     # dynavlan <ver> (build <that short commit>)
```

A `-dirty` suffix means the tree had uncommitted changes. Rebuild from a clean `main` first. If the build id does not match HEAD, stop. You are testing the wrong code. Deploy steps: `docs/deployment-guide.md` §2 (source/tarball path).

### Redaction

If you paste journal or capture excerpts back, redact any real MAC to `00:00:5e:00:53:xx` first. This is a public repo.

### Not validated on hardware by design

These cases need an injected failure that cannot be staged on the Protectli. Each one fails toward no change and a reachable box. Unit coverage is the accepted substitute. Do not chase them at the console.

- **M4**: carrier drop in the detection->apply window (the guard only ever drops additions).
- **M5**: a transient `ip link delete` failure (record + retry is reboot-scoped, ownership-safe).
- **H1**: a sniff/LLDP/promisc wire failure (preserve-only direction).
- **H6**: over-`IFNAMSIZ` interface names (the box uses short `enp` names).

---

## HV-31: v1.0.0 published package reaches the box (2026-10-13 UTC)

The final-build pass is complete.

**Release checks**

- Release `v1.0.0` (tag at `633f35e`) was published on 2026-10-13 05:04 UTC. The `build-deb` and `publish-apt` jobs of the release workflow both succeeded.
- The release asset `dynavlan_1.0.0_all.deb` has sha256 `f3365acd9e61b9e4dbec0d478c592301fdd48913ac2502bd34f5f60bb6dd1aa1`.
- The asset has the same payload, control files, maintainer scripts and modes as a clean local build of `633f35e`. Only the archive compression differs.
- The script matches the commit except `build="633f35e"`.
- The APT repository's `InRelease` has a good signature from the repository key (`639F373F...EC9D`, signing subkey `5BAF93E3...4D24`).
- The `Packages` hash matches. `Packages` lists 1.0.0 with the release asset's SHA256. The pool file has the same hash.

**Box setup**

- The run was console-backed, from an authenticated root shell on the serial console (login on `ttyS0`).
- Recovery was staged first, in a read-only folder on the box:
  - the deployed 0.4.22 package (`01e9f98`, sha256 `a7e113da...b3f7faa4`, script and unit hashes equal to the installed copies);
  - the restore steps;
  - a copy of `/etc/dynavlan.conf`.

| Step | Result |
|------|--------|
| Baseline | `0.4.22 (build 01e9f98)`; 14 VLANs; defaults `enp1s0` metric 10, `enp2s0` metric 20; service enabled, timer enabled and active with its `interval.conf` drop-in; a timer rescan reported no changes |
| `apt-get update`, `apt-cache policy dynavlan` | update rc 0; installed 0.4.22, candidate 1.0.0 from `pereljon.github.io/dynavlan stable/main` |
| `apt-get install --only-upgrade -s dynavlan=1.0.0` | only `dynavlan` upgraded, nothing installed or removed |
| `apt-get install -y --only-upgrade dynavlan=1.0.0` (conffile kept) | rc 0; the downloaded archive's sha256 equals the release asset |
| Identity | `dynavlan 1.0.0 (build 633f35e)`; `dpkg -V dynavlan` clean; conffile, owned netplan file and unit files unchanged from the baseline |
| Posture | service enabled, rescan unit inactive, timer enabled and active with `interval.conf`; after the timer's post-upgrade rescan, next elapse 05:19:26 UTC (finite) |
| Rescans | a manual rescan and the timer's rescan on 1.0.0: "no changes ... nothing to apply", rc 0 |
| Network | 14 VLANs, both default routes unchanged; `--status` rc 0, both trunks 7 tags, no ignored/out-of-range/managed-elsewhere |

**HV-31 PASS; D3 is closed** on published-and-installed evidence. No recovery was needed.

While a rescan is running, systemd shows no next elapse for the timer. It is finite again once the rescan ends (seen before and after the upgrade).

---

## Final-build pass, batch 3 (2026-10-12/13, `0.4.22 (build 01e9f98)`)

- The package was built clean from `01e9f98` (sha256 `a7e113da...b3f7faa4`).
- The `install.sh` lanes ran from a clean clone at the same commit.
- The pass was console-backed, with three reboots.
- The box ended equal to its starting state: config, owned YAML body, base Netplan files, timer drop-in, units, 14 VLANs, defaults. Only the owned YAML header changed. 0.4.22 now writes it.

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

**Control-path deviations**, recorded as they happened:

- The serial console has no autologin. It sat at a login prompt after each reboot.
- So the S4 refusals, teardown and recovery `--boot` ran over SSH to the base address. That address is on no VLAN, so teardown could not cut the session.
- Reboot 3 was issued over SSH. A reboot command typed at the console login prompt had failed as a login.
- The observed results stand.
- SSH to the base address does not replace the console-only rule. Future destructive or reboot work needs an authenticated console shell first.

## Final-build pass, batch 2 (2026-10-12, `0.4.21 (build 72d9eea)`)

- The pass was console-backed, with the timer stopped.
- Every config and record variant was restored and checksum-verified.
- A temporary VLAN 995 (DHCP, one test container as the traffic source) was created and removed by recorded IDs.
- Box, switch and controllers ended equal to their pre-batch backups. The owned YAML differs only in its header, now written by 0.4.21.

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

The attended `--boot` removed the temporary VLAN after it left the wire. Detection ignored the box's own outbound frames on it.

---

## Group 0 record (v1.0 review, HV-00 and HV-01)

The first build in this record is the clean pre-remediation `0.4.13 (build e3f2cef)`, before the review fixes.

HV-00 (baseline and recovery rehearsal) PASSED on that build.

HV-01 is the whole-cgroup stop of the rescan service during an applied-but-unconfirmed `netplan try`. It was run on three builds:

| Build | Date | HV-01 result |
|-------|------|--------------|
| 0.4.13 (`e3f2cef`), pre-remediation | not recorded | **FAIL** (finding D2). Stopping the unit killed both the script and `netplan try`. No revert occurred. The candidate stayed live and on disk. The box was restored to its recorded 14-VLAN baseline. |
| 0.4.20 (`d9b3618`), with the fix (`KillMode=mixed`, SIGTERM handling before ACCEPT, `ver=` 0.4.15) | 2026-10-09 | **PARTIAL**. Stopping the rescan service during a live, unaccepted `netplan try` withheld the confirmation. The child exited. The owned YAML was restored byte-for-byte. No post-accept work ran. The original defaults survived. The run ended rc 1 in about 6.5 seconds. But the candidate VLAN link kept its DHCP address and its generated `/run/systemd/network` files after the revert, so the "prior configuration live" criterion is not met. See the open rollback question in `context/open_questions.md`. D2 closure was pending that disposition. |
| 0.4.21 (`72d9eea`), the corrected artifact | 2026-10-12 | A stop during a live, unconfirmed `netplan try` exited in 5.9 s with no confirmation or post-accept work. The owned YAML and defaults were unchanged. `/run/systemd/network` was byte-identical to the pre-run state, with no candidate files or parent reference. **D2 is closed** (2026-10-12). |

Cause of the 0.4.20 result:

- A real `netplan generate` ran before the try. It put candidate files into the runtime backup of `netplan try`.
- `ver=` 0.4.21 validates in an isolated root instead.

Limits of the 0.4.21 result:

- The candidate kernel link persisted with its DHCP address and connected route (FR-24). It was recorded separately and removed by hand at the console.
- The retained link is an operator-accepted limitation (FR-43, recovery in the deployment guide, section 5).
- A routed-mode revert and full kernel convergence are not proven.

---

## v1.0 review: finding closure

Hardware evidence is on `0.4.20`-`0.4.22`, from the records above. "Local" means unit, lifecycle-harness or dry-run evidence that the independent reviewer (Codex) accepted for the pass.

| Finding | Remediation | Evidence | Status |
|---------|-------------|----------|--------|
| D1 pending-delete default guard | Group 1 (`bf59ab0`) | local; shared default guard shown live in HV-61 | closed |
| D2 stop during `netplan try` | Groups 2a, `72d9eea` | HV-01 on 0.4.21 | closed; retained candidate link accepted (FR-43) |
| D3 APT publication | Group 3 (`34bed4e`) | HV-31 on the published v1.0.0 | closed |
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

Open low-severity wording, recorded and not fixed:

- Teardown after a default-route refusal also prints "teardown not completed (the apply was not accepted or ended uncertain)".
- HV-23 repeats its restart error 3-4 times.

---

## History: v0.4.11 pass (2026-08-06)

This is the oldest pass. It is kept as a record and is not the current status.

### Completed pass (v0.4.11, gate-4 group-5 accumulation)

- This was one consolidated, console-backed validation of everything merged between v0.4.2 and v0.4.11. It was run once, not per fix.
- The per-phase results are in the sign-off below. The per-check Pass boxes in the tables were not individually ticked.
- Phase 3b.2 and the Phase 4.1 positive C1 case were deferred.
- The pass ran on a locally built `.deb` of the then-`main` HEAD (0.4.11, later tagged `v0.4.11`).

### Phase 1: Happy-path smoke (no switch reconfig)

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

### Phase 2: Lease + restart timing (H5), needs a real multi-VLAN add

| # | Check | Do | Expect | Pass |
|---|-------|----|--------|------|
| 2.1 | **H5 box-wide lease deadline** | trigger an apply that ADDS >=2 VLANs (e.g. widen `VLAN_MIN/MAX` or clear part of the owned set, then `sudo dynavlan --boot`) | after ACCEPT the lease wait is ONE bounded pass over all pending tokens, **not** N x `LEASE_SETTLE` in series; total stays well under the systemd `TimeoutStartSec` and the restart fires. Confirm via journal timestamps | [ ] |
| 2.2 | Restart after apply | same run | `restarted snap/service ...` logged once after the leases settle | [ ] |

### Phase 3: Restart-failure -> seen-set (M6), stageable, may need a new subnet

| # | Check | Do | Expect | Pass |
|---|-------|----|--------|------|
| 3.1 | **M6 total failure holds subnet unseen** | set `RESTART_SERVICES="dynavlan-nonexistent.service"` (only a bogus target), induce a new IPv4 subnet (add a VLAN that leases), `sudo dynavlan --rescan` | restart fails; `/run/dynavlan/seen` does **not** gain the new subnet; next `--rescan` retries the restart (subnet still "new") | [ ] |
| 3.2 | **M6 partial success consumes** | add a REAL target alongside the bogus one (`RESTART_SERVICES="<real> dynavlan-nonexistent.service"`), repeat | the real target restarts; the subnet **is** recorded seen; next run does NOT re-restart (no storm) | [ ] |

### Phase 3b: Script-death mid-apply (P2), the FIFO-EOF assertion the code marks unvalidated

| # | Check | Do | Expect | Pass |
|---|-------|----|--------|------|
| 3b.1 | **P2 kill mid-`netplan try`** | during an apply that would ACCEPT, `sudo kill -9` the dynavlan process while `netplan try` is running (before the accept newline) | `netplan try` sees the dead writer / no confirmation and **reverts** to the pre-apply config; box returns to the snapshot default route; no interface left deleted | [ ] |
| 3b.2 | P2 systemd-timeout variant | let the run exceed the service `TimeoutStartSec` so systemd kills the cgroup mid-apply | same revert-to-prior outcome; confirm whether the same-cgroup kill takes `netplan try` down with it or it survives to its own timer revert (record which) | [ ] |

### Phase 4: Switch-access-gated (schedule when you can reconfigure the switch)

| # | Check | Do | Expect | Pass |
|---|-------|----|--------|------|
| 4.1 | **C1 positive-refusal** | routed mode (`VLAN_ROUTES=true`) so a dynavlan VLAN carries the box default route; then force that VLAN into the removal set (drop its tag on the switch; narrowing `VLAN_MIN`/`VLAN_MAX` or adding it to `VLAN_IGNORE` does NOT remove an already-owned VLAN) and `sudo dynavlan --boot` | dynavlan **refuses the whole reconcile before any disk change** (`default_iface_in_removals`); default route intact; box reachable; nothing deleted | [ ] (deferred: the faithful positive-refusal case was not run) |
| 4.2 | **L3-30 carrier-pull PRUNE** (revised; validated 2026-08-06, see sign-off) | pull the owned trunk's cable; let two carrier samples elapse across the debounce; `sudo dynavlan --rescan` | that trunk's entire owned set is **pruned** (not preserved), gated on healthy `have_routing`; re-plug + `--rescan` re-provisions | [ ] |

### Sign-off

Completed 2026-08-06, console-backed on the Protectli box, build `b0317b6` (0.4.11),
installed from a locally-built `.deb` over the box's prior 0.4.2 test build.

| Item | Result | Build id | Notes |
|------|--------|----------|-------|
| Phase 1 (smoke + M8) | PASS (8/8) | b0317b6 | M8: hidden lldpctl -> `detected trunks: unavailable`, exit 1, restored to exit 0. M5 drain: `pending-delete` absent, early return. No-change reconcile: no netplan try, no restart. |
| Phase 2 (H5) | PASS | b0317b6 | Re-add of 7 `enp1s0.*`: ACCEPT -> 7 leases in **179 ms** (one bounded pass, not per-VLAN serial) -> restart once; run 76s << 600s TimeoutStartSec. Domotz restart confirmed by ExecMainStartTimestamp. Fast-DHCP caveat: does not contrast vs the old serial path (structural fix is unit-covered). |
| Phase 3 (M6) | PASS | b0317b6 | Total failure (bogus-only target): new subnets held OUT of `seen`, retried next run. Partial success (real snap + bogus service): snap restarted, subnets recorded, next run no re-restart (no storm). Staged by clearing `/run/dynavlan/seen`. |
| Phase 3b (P2 kill-mid-apply) | PASS (3b.1) | b0317b6 | `kill -9` the dynavlan writer during `netplan try` (via a perturbed `--reapply` to open a real try window; applied config == canonical, safe): FIFO EOF -> netplan try reverted+exited ~4.3s later (<< 30s timer), 14 ifaces intact, box reachable. enp1s0 base default briefly dropped during the revert reconcile, DHCP-recovered. 3b.2 (systemd-cgroup kill) not run - secondary variant, core EOF path validated. |
| Phase 4 (C1, L3-30) | L3-30 PASS; C1 positive DEFERRED | b0317b6 | L3-30 carrier-pull PRUNE on 0.4.11: enp1s0 down -> 20s debounce -> 7 VLANs pruned via netplan try (removal-only accept ~18.2s, C2 floor), enp2s0's 7 preserved, box reachable; re-plug re-add PASS. C1 true-negative observed live (no isolated VLAN was default, guard silent). C1 POSITIVE refusal still deferred (needs routed-mode + switch to make a dynavlan VLAN the default route). |

Findings are recorded in `context/todo.md`. The SKELETON P2/FIFO-EOF status and the
tests-doc L3-30 note were updated.

Preserve-biased behavior confirmed along the way:

- Neither `VLAN_MAX` narrowing nor `VLAN_IGNORE` prunes an already-owned VLAN.
- `--reapply` no-ops when the on-disk yaml already matches the generated config.

---

## History: first hardware deploy observations (2026-07-25)

These are observations from the first deploys on the reference box, not a validation pass. Each one is the hardware basis for a rule in `dev/SKELETON.md`. The full records are in `context/decisions.md` (2026-07-25 entries).

- **Inbound-only sniff (FR-5a):** a dead `enp1s0.100` stayed "detected" across reboots. The only VID-100 frame in 75 s was one outbound DHCP Request from the box's own MAC.
- **Native VLAN from LLDP (FR-7a):** LLDP advertised only `vlan-id=100` with `pvid=yes`. The `enp1s0.100` interface that dynavlan built took no lease in 30 s.
- **Dead rescan timer (FR-21a):** the timer showed `active` and `Result=success`, but `LastTriggerUSec` was empty and `NextElapseUSecMonotonic=infinity`. `systemctl list-timers` showed `n/a` in every column.
- **IPv6 RA on a VLAN (FR-14a):** `enp1s0.22` held a global SLAAC address from a VLAN RA while every DHCPv4 decline was in force.
