# dynavlan exit codes

**Status: DRAFT — Gate-4 freeze artifact.** This table is the authoritative exit-code
surface that `COMPATIBILITY.md` freezes at 1.0.0. It does not exist yet as a stable
contract; this draft enumerates what the script produces today (v0.4.20; line numbers are deliberately not cited because they drift),
proposes the frozen table, and records a disposition for each currently-ambiguous exit.

Exit codes are one of the four frozen surfaces (config keys, generated YAML shape, CLI
flags, exit codes). Under the deprecate-with-warning policy, changing an exit code's
*meaning* is a breaking change post-1.0. Pre-release (now) we are free to change any of
them; the point of this draft is to make those changes deliberately, then freeze.

## Current vocabulary

The script produces exactly three codes today: **{0, 1, 2}**. `main` returns them and is
the process's last statement (`dynavlan` tail: `main "$@"`), so its return is the exit
code.

| Code | Current meaning |
|------|-----------------|
| `0` | success, OR a deliberate no-op (nothing to change / another run holds the lock / a guarded abort) |
| `1` | operational failure or refusal — invalid config, not root, precondition fail, lock-acquire fail, validation fail, detection unavailable, **and an apply that was not accepted (health-failed and reverted, or uncertain)** |
| `2` | usage error — no mode given, or an unknown mode (a requested `-h`/`--help` is `0`) |

The problem this draft resolves: `0` currently covers both "success" and three distinct
"changed nothing" cases (one of which logs at `err`), and `1` conflates "refused before
touching anything" with "tried, health-failed, revert attempted." Neither overload is
wrong per se, but the freeze should make each a deliberate, documented choice.

## Complete inventory by mode (v0.4.20)

Every terminal exit path, by function.

### All modes — `main`
- `--version` / `-V` → **0**, before config load and root check
- `-h` / `--help` (explicitly requested) → **0** (0.4.13; requested help is success)
- no arg → **2**; unknown mode → **2**
- `load_config` failure → **1** (except `--teardown`, which falls back to built-in defaults with a warning and continues)
- `check_preconditions` failure → **1**
- lock-file open failure (reapply/boot/rescan) → **1**

### `--status` — `do_status`
- non-root → **1**; detection prerequisite missing (M8) → **1** (`detected trunks: unavailable`); a runtime detector failure on ANY sampled interface (D5) → **1** (incomplete or unavailable, whether the partial result is empty or not); a managed-elsewhere query failure → **1**; otherwise → **0**, including a genuinely quiet valid wire

### `--reconfigure` — `do_reconfigure`
- cannot create drop-dir → **1**; write failure → **1**; `systemctl daemon-reload` failure (the new timer interval is not active) → **1**; success → **0** (the reload is skipped, not failed, only where systemd is positively absent); non-root → **1** (main)

### `--dry-run` — `do_dryrun`
- validation pass or nothing-to-do → **0** (a quiet wire still validates); validation rejection (M3) → **1**; count-gate refusal (S3) → **1** with nothing validated; base-tree copy failure (L8) → **1** with nothing validated; a failed pending-delete or managed-elsewhere query → **1**; other early refusals → **1** (`vstatus` is only ever 0 or 1)

### `--teardown` — `do_teardown` (Group 6)
- non-root, `ip` missing, unsupported netplan, no `netplan try` → **1**; lock timeout → **1**; a unit enabled, active, or indeterminate → **1**
- pending-delete drain failure → **1**; unreadable or unrecognized owned file → **1**; nothing owned → **0**
- `apply_change` not accepted or uncertain → **1** (no manual-delete advice); stop request → **1**
- accepted but a link still present, or the post-accept drain failed → **1**; accepted and clean → **0** (a failed agent restart only warns, as for any accepted apply)

### `--reapply` — `do_reapply`
- nothing owned → **0**; body identical to on-disk → **0**; applied + accepted → **0**
- lock timeout → **1**; no-parent refuse / scratch-dir fail / generate fail / readback fail → **1**
- every `apply_change` failure → **1** (see below)

### `--boot` — `do_boot` / `--rescan` — `do_rescan`
- lock busy → **0** `skipped, run in progress` — deliberate, FR-30
- FR-22 zero-detection abort → **0**, severity now conditional on the owned set
  (`warning` if owned VLANs are preserved behind a quiet wire, else `info`; D1, fixed
  in 0.4.12) — was `log err` then 0
- no change → **0**
- pending-delete drain failure → **1** and no further reconciliation, with two different shapes: a failed current-state query happens before the delete loop and preserves the pending record untouched; a failure to write the survivor record happens after the attempted deletes, can truncate or partly rewrite the record, and a still-failing token can be lost. A later managed-elsewhere query failure → **1** before any change, but does not undo an earlier drain
- `gate_vlan_count` refuse (limit exceeded, `refuse` mode) → **1**
- fill-mode → proceeds to apply; exit reflects the apply outcome (not a distinct code)
- any `apply_change` failure → **1**

### `apply_change` failure paths (all → 1)
- C1 default-route-in-removals guard; route-metric conflict; backup
  fail; generate fail; validate fail; **health-fail or otherwise unaccepted
  apply** — `return 1`. Rc 1 means unaccepted, failed or uncertain; it is not
  proof of a completed live revert (the caller's message says so, L6). A stop
  request (SIGTERM, FR-43) before or after ACCEPT also exits 1

## Proposed frozen table

| Code | Meaning | Notes |
|------|---------|-------|
| `0` | Success or a deliberate no-op; does not by itself establish routing health. | Covers: applied+accepted; nothing to change; lock-skip; guarded aborts (see dispositions) |
| `1` | Operational refusal, failure or interruption; may follow partial work, an unaccepted/uncertain apply, or interruption after ACCEPT. Does not prove a completed revert. | The union is intentional (see D4); the cause is in the journal |
| `2` | Usage error: no mode, or an unknown mode (requested `-h`/`--help` is `0`) | Never touches config or hardware |
| `3` | *(proposed, optional)* Applied, post-apply health check FAILED, revert attempted | Only if a real consumer needs it — see Decision below |

Codes stay below 126 (shell/signal reserved range). Additions to this table are allowed
post-1.0 as a free minor addition **provided the table is documented as open-ended** —
i.e. a consumer must treat any unknown non-zero as failure, not assume {1,2} exhaustive.

## Dispositions for the ambiguous exit-0 states

Three terminal states currently return 0 for "changed nothing." Each needs a ruling so
the freeze is deliberate.

### D1 — FR-22 zero-detection abort: **FIXED in 0.4.12**
Was `log err "...aborted..."` then `return 0` — an error-severity log paired with a
success exit, internally inconsistent. It is an intended no-op (zero detection + removal
disabled → change nothing), so exit 0 is correct and the log level was the bug. The same
predicate was already `log info` in `do_rescan`, so boot was the outlier.

Fixed by making the severity track the owned set (the guard now computes `owned` first):
`warning` when owned VLANs are being preserved behind a now-quiet wire (the per-trunk
preserve `warning` is unreachable from this early return, so this is the only
signal — matching that line's convention), `info` when nothing is owned and there is
genuinely nothing to do (matching `do_rescan`). A blanket `warning` was rejected: it would
cry-wolf on every boot of a dark spare box; a blanket `info` would lose the signal under
`LOG_LEVEL=warning`. `notice` was rejected: the codebase reserves it for state changes.

Note: dynavlan's `log()` prints the level as *text* to stderr and no unit sets
`SyslogLevel=`, so journald records every line at one uniform priority — severity is
visible to human readers and to dynavlan's own `LOG_LEVEL` gate, but NOT to
`journalctl -p`. The severity choice matters for those two, not for priority filtering.

### D2 — Lock-skip: **KEEP 0, document**
`log info "skipped, run in progress"` → 0. Deliberate per FR-30: a timer rescan that
collides with a running apply is a healthy no-op, not a failure; it retries next cycle.
Freeze as 0. No change.

### D3 — No-change reconcile: **KEEP 0, document**
Nothing to add or remove → 0. Unambiguously correct. Freeze as 0. No change.

### D4 — Health-fail revert: **KEEP 1** (decision point for code 3 below)
Currently 1, grouped with refused-before-trying. Keep it non-zero on **observability
grounds**: both systemd units are `Type=oneshot` with no `OnFailure=`/`SuccessExitStatus=`,
so a non-zero exit is the only passive signal that puts the unit in failed state — the one
signal a headless box surfaces to `systemctl --failed`. Exit 0 here would hide the single
failure the tool exists to survive. Keep 1.

## Open decision — add code 3?

Whether to split D4 out from generic `1` into a distinct code `3` = "applied,
health-failed, auto-reverted, box safe."

- **For:** a remote operator on a degraded link, without journal access, could distinguish
  "refused cold, nothing tried" (`1`) from "tried, reverted, box safe" (`3`) from `$?`
  alone.
- **Against:** to systemd the distinction is cosmetic — `Type=oneshot` + any non-zero =
  failed; `OnFailure=` cannot discriminate by code; the journal already logs the revert at
  `err` with full context (FR-38 journal-as-provenance). With zero deployed consumers of
  `$?` today, the yield is low.

**Recommendation: do NOT add code 3 for 1.0.** Keep the table `{0,1,2}`, document it as
open-ended so `3` can be added later as a free minor addition *if and when* the
remote-operator consumer becomes real. Adding it now is speculative surface against no
demand (project principle: smallest thing that works). If added, add *only* `3`; do not
proliferate.

## Summary of actions

1. **D1:** DONE in 0.4.12 — FR-22 abort severity now tracks the owned set (`warning` if
   preserving owned VLANs, else `info`), exit 0 unchanged.
2. **D2/D3:** no change; document as deliberate 0-exits.
3. **D4:** keep revert → 1; document.
4. **Code 3:** deferred; freeze `{0,1,2}` as open-ended, add `3` post-1.0 only on real demand.
5. Freeze this table into `COMPATIBILITY.md` at Gate 4.
