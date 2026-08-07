# dynavlan exit codes

**Status: DRAFT — Gate-4 freeze artifact.** This table is the authoritative exit-code
surface that `COMPATIBILITY.md` freezes at 1.0.0. It does not exist yet as a stable
contract; this draft enumerates what the script produces today (v0.4.11, line-cited),
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
| `1` | operational failure or refusal — invalid config, not root, precondition fail, lock-acquire fail, validation fail, detection unavailable, **and an applied-then-health-failed-and-reverted run** |
| `2` | usage error — no mode, `-h`/`--help`, unknown mode |

The problem this draft resolves: `0` currently covers both "success" and three distinct
"changed nothing" cases (one of which logs at `err`), and `1` conflates "refused before
touching anything" with "tried, health-failed, safely reverted." Neither overload is
wrong per se, but the freeze should make each a deliberate, documented choice.

## Complete inventory by mode (v0.4.11, grounded)

Every terminal exit path, with `dynavlan` line references.

### All modes — `main` (2351-2400)
- `--version` / `-V` → **0**, before config load and root check (2360-2362)
- no arg / `-h` / `--help` → **2** (2364-2366)
- unknown mode → **2** (2368-2371)
- `load_config` failure → **1** (2374-2377)
- `check_preconditions` failure → **1** (2400)
- lock-file open failure (reapply/boot/rescan) → **1** (2419/2433)

### `--status` — `do_status`
- non-root → **1**; detection prerequisite missing (M8) → **1** (`detected trunks: unavailable`); otherwise → **0**, including a genuinely quiet wire

### `--reconfigure` — `do_reconfigure` (…-2344)
- cannot create drop-dir → **1** (2335-2336); write failure → **1** (2339-2340); success → **0** (2344); non-root → **1** (main)

### `--dry-run` — `do_dryrun`
- validation pass or nothing-to-do → **0**; validation rejection (M3) → **1**; early refusals → **1** (`vstatus` is only ever 0 or 1)

### `--reapply` — `do_reapply` (2205-2248)
- nothing owned → **0** (2208); body identical to on-disk → **0**; applied + accepted → **0** (2248)
- lock timeout → **1** (2422-2424); no-parent refuse / scratch-dir fail / generate fail / readback fail → **1** (2213/2225/2237/2244)
- every `apply_change` failure → **1** (see below)

### `--boot` — `do_boot` / `--rescan` — `do_rescan`
- lock busy → **0** `skipped, run in progress` (2437-2439) — deliberate, FR-30
- FR-22 zero-detection abort → **0**, severity now conditional on the owned set
  (`warning` if owned VLANs are preserved behind a quiet wire, else `info`; D1, fixed
  in 0.4.12) — was `log err` then 0
- no change → **0** (1925, 1930)
- `gate_vlan_count` refuse (limit exceeded, `refuse` mode) → **1** (1928 / rescan 2031)
- fill-mode → proceeds to apply; exit reflects the apply outcome (not a distinct code)
- any `apply_change` failure → **1**

### `apply_change` failure paths (all → 1)
- C1 default-route-in-removals guard (1647-1649); route-metric conflict (1656); backup
  fail (1662); generate fail (1666); validate fail (1671-1677); **health-fail revert
  (1695-1698)** — applied, `netplan try` reverted, uplink preserved, `return 1`

## Proposed frozen table

| Code | Meaning | Notes |
|------|---------|-------|
| `0` | Success, or a deliberate no-op that left the box unchanged and healthy | Covers: applied+accepted; nothing to change; lock-skip; guarded aborts (see dispositions) |
| `1` | Refused or failed *before* changing anything, OR an apply that was safely reverted | Fail-toward-safe: box reachable, logged. The union is intentional (see D4) |
| `2` | Usage error (bad/missing mode) | Never touches config or hardware |
| `3` | *(proposed, optional)* Applied, post-apply health check FAILED, auto-reverted, box safe | Only if a real consumer needs it — see Decision below |

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
predicate was already `log info` in `do_rescan` (1943), so boot was the outlier.

Fixed by making the severity track the owned set (the guard now computes `owned` first):
`warning` when owned VLANs are being preserved behind a now-quiet wire (the per-trunk
preserve `warning` at 1882 is unreachable from this early return, so this is the only
signal — matching that line's convention), `info` when nothing is owned and there is
genuinely nothing to do (matching 1788/1943). A blanket `warning` was rejected: it would
cry-wolf on every boot of a dark spare box; a blanket `info` would lose the signal under
`LOG_LEVEL=warning`. `notice` was rejected: the codebase reserves it for state changes.

Note: dynavlan's `log()` prints the level as *text* to stderr and no unit sets
`SyslogLevel=`, so journald records every line at one uniform priority — severity is
visible to human readers and to dynavlan's own `LOG_LEVEL` gate, but NOT to
`journalctl -p`. The severity choice matters for those two, not for priority filtering.

### D2 — Lock-skip (2437-2439): **KEEP 0, document**
`log info "skipped, run in progress"` → 0. Deliberate per FR-30: a timer rescan that
collides with a running apply is a healthy no-op, not a failure; it retries next cycle.
Freeze as 0. No change.

### D3 — No-change reconcile (1925, 1930): **KEEP 0, document**
Nothing to add or remove → 0. Unambiguously correct. Freeze as 0. No change.

### D4 — Health-fail revert (1695-1698): **KEEP 1** (decision point for code 3 below)
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
