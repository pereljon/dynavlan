# Hardware validation checklist - v0.4.10 (gate-4 group-5 accumulation)

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
| 1.1 | Build id | `dynavlan --version` | `0.4.10 (build 3d89e82)`, no `-dirty` | [ ] |
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

| Item | Result | Build id | Notes |
|------|--------|----------|-------|
| Phase 1 (smoke + M8) | | | |
| Phase 2 (H5) | | | |
| Phase 3 (M6) | | | |
| Phase 3b (P2 kill-mid-apply) | | | |
| Phase 4 (C1, L3-30) | | | |

On completion, record the outcome in `context/todo.md` and, for the SKELETON /
tests-doc invariants any case touches (esp. L3-30 prune, C1 positive), update
their "hardware-validated" status so the docs stop saying "not yet run".
