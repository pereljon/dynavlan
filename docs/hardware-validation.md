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
maintainer's validation bed. Latest sign-off: v0.4.11, 2026-08-06 (below).

---

## Current validation pass (v0.4.11, gate-4 group-5 accumulation)

Consolidated console-backed validation of everything merged since the last
hardware pass (v0.4.2). Run this **once** before cutting the next release, not
per-fix. Console-backed only: a bad apply drops SSH, so drive from the serial
console, never SSH-only.

**Build-identity gate (FR-38).** Before drawing any conclusion from behavior,
confirm the running build. This validates the accumulated pre-freeze build (0.4.11
as of this writing); it is **not tagged**, so install from the `main` checkout
(source install; `install.sh` stamps the commit) and verify the running build
matches `main` HEAD:

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
| 4.1 | **C1 positive-refusal** | routed mode (`VLAN_ROUTES=true`) so a dynavlan VLAN carries the box default route; then force that VLAN into the removal set (drop its tag on the switch, or narrow the range) and `sudo dynavlan --boot` | dynavlan **refuses the whole reconcile before any disk change** (`default_iface_in_removals`); default route intact; box reachable; nothing deleted | [ ] |
| 4.2 | **L3-30 carrier-pull PRUNE** (revised, unvalidated on HW) | pull the owned trunk's cable; let two carrier samples elapse across the debounce; `sudo dynavlan --rescan` | that trunk's entire owned set is **pruned** (not preserved), gated on healthy `have_routing`; re-plug + `--rescan` re-provisions | [ ] |

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
