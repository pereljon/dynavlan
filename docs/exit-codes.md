# dynavlan exit codes

This page lists the exit codes of dynavlan. They are frozen as of 1.0.0 under
[`COMPATIBILITY.md`](../COMPATIBILITY.md). If a change alters what a code means, it is a
breaking change.

## The frozen table

| Code | Meaning |
|------|---------|
| `0` | Success, or a deliberate no-op. Exit 0 does not by itself prove routing health. Includes a requested `--help` or `-V`. |
| `1` | A refusal, a failure, or an interruption. The run may have done part of its work first. Exit 1 can follow a change that was not accepted, a change whose outcome is uncertain, or an interruption after the change was accepted. Exit 1 does not prove that a revert completed. |
| `2` | Usage error: no mode given, or an unknown mode. |

A usage error (`2`) never touches the config or the network.

Rules for a script that reads the exit code:

- Treat the list as open-ended. Treat any unknown non-zero code as a failure. Do not assume that
  `1` and `2` are the only failure codes.
- Do not read `0` as "the network is healthy". Read it as "the run did what it should".
- Do not read `1` as "the box is unchanged". An apply can fail after some work is done.
  The journal (`journalctl -t dynavlan`) holds the cause.

A new code can be added in a minor release. Any new code stays below 126, because the shell
reserves 126 and above.

## Why a reverted apply exits 1

A reverted apply exits `1`, not `0`. Both systemd units are `Type=oneshot` and have no
`OnFailure=` or `SuccessExitStatus=`. A non-zero exit is the only passive signal that puts the
unit in the failed state, and a headless box shows that state in `systemctl --failed`. An exit
of `0` would hide the one failure that dynavlan exists to survive.

dynavlan has no separate code for "applied, health check failed, reverted". To systemd, any
non-zero exit is a failure, and `OnFailure=` cannot tell the codes apart. The journal already
records the revert.

## Exit codes by mode

### Checks before any mode runs

| Condition | Exit |
|-----------|------|
| `--version` or `-V` (answered before the config load and the root check) | `0` |
| `-h` or `--help` | `0` |
| No mode given | `2` |
| Unknown mode | `2` |
| Config is invalid (`--teardown` instead uses the built-in defaults and logs a warning) | `1` |
| Not root | `1` |
| A precondition fails, for example: netplan missing, too old or of unknown version; detection tools missing; or `netplan try` unavailable (does not apply to `--status`, `--reconfigure` and `--teardown`, which check their own needs) | `1` |
| The lock file cannot be opened (`--boot`, `--rescan`, `--reapply`, `--teardown`) | `1` |

### `--status`

| Condition | Exit |
|-----------|------|
| Detection tools missing (output shows `detected trunks: unavailable`) | `1` |
| The detector failed on any sampled interface, so the result is incomplete or unavailable | `1` |
| A query for VLANs managed elsewhere failed | `1` |
| Everything else, including a valid but quiet wire | `0` |

### `--reconfigure`

| Condition | Exit |
|-----------|------|
| The drop-in directory cannot be created | `1` |
| The drop-in file cannot be written | `1` |
| `systemctl daemon-reload` fails (the new timer interval is not active) | `1` |
| The drop-in is written and the reload succeeds | `0` |
| The drop-in is written and systemd is not running (the reload is skipped, not failed) | `0` |

### `--dry-run`

`--dry-run` never applies anything.

| Condition | Exit |
|-----------|------|
| Validation passes, or there is nothing to do (a quiet wire still validates) | `0` |
| Validation rejects the candidate config | `1` |
| The VLAN-count gate refuses the change; nothing is validated | `1` |
| The base netplan tree cannot be copied or the scratch tree cannot be created; nothing is validated | `1` |
| A query for pending deletes or for VLANs managed elsewhere failed | `1` |
| Any other early refusal, for example the candidate config cannot be written into the scratch tree | `1` |

### `--teardown`

| Condition | Exit |
|-----------|------|
| Not root, `ip` missing, netplan unsupported, or `netplan try` unavailable | `1` |
| The lock wait times out | `1` |
| `dynavlan.timer` or `dynavlan.service` is enabled, active, or in an unknown state | `1` |
| The pending-delete drain fails | `1` |
| The owned file cannot be read or is not recognized | `1` |
| Nothing is owned | `0` |
| The apply is not accepted or ends uncertain (no advice to delete links by hand) | `1` |
| A stop request (SIGTERM) arrives | `1` |
| The apply is accepted, but a link is still present or the final drain failed | `1` |
| The apply is accepted and everything is clean | `0` |

After an accepted apply, a failed agent restart only logs a warning. It does not change the exit.

### `--reapply`

| Condition | Exit |
|-----------|------|
| Nothing is owned | `0` |
| The on-disk file already matches what this build generates | `0` |
| The regenerated config is applied and accepted | `0` |
| The lock wait times out | `1` |
| The owned file has VLANs but no parent link, or the scratch directory, config generation, or read-back fails | `1` |
| The apply fails (see [Apply failures](#apply-failures)) | `1` |

### `--boot` and `--rescan`

| Condition | Exit |
|-----------|------|
| Another run holds the lock (logs `skipped, run in progress`; this is deliberate) | `0` |
| Nothing was detected and `REMOVE_ON_CARRIER_LOSS=false`: dynavlan changes nothing | `0` |
| No change is needed (also after VLAN-limit gating) | `0` |
| The change is applied and accepted | `0` |
| The pending-delete drain fails; nothing more is reconciled | `1` |
| A query for VLANs managed elsewhere fails; this happens before any change | `1` |
| The VLAN limit is exceeded and `VLAN_LIMIT_MODE` is not `fill` | `1` |
| The apply fails (see [Apply failures](#apply-failures)) | `1` |
| A stop request (SIGTERM) arrives | `1` |

Notes:

- When nothing is detected and `REMOVE_ON_CARRIER_LOSS=false`, `--boot` logs a warning if
  owned VLANs exist and are kept, and an info line if nothing is owned. `--rescan` logs an
  info line in both cases. The exit is `0` in every case.
- With `VLAN_LIMIT_MODE=fill`, dynavlan adds only as many VLANs as the limit allows and goes
  on to the apply. The exit then reflects the apply.
- A drain failure has two forms. If the query for current state fails, it fails before any
  delete runs, and the pending record is not touched. If the survivor record cannot be
  written, it fails after the deletes ran. The record can then be cut short or partly
  rewritten, and a token that still fails can be lost. A failed managed-elsewhere query later
  in the run also exits `1`, but it does not undo an earlier drain.

### Apply failures

`--boot`, `--rescan`, `--reapply` and `--teardown` share one apply step. Each of these makes it
return `1`, and so makes the mode exit `1`:

- The current default-route interface is in the removal set (dynavlan refuses before it
  changes anything).
- The route-metric check finds a conflict.
- A stop request arrives before the apply starts.
- Validation of the candidate config fails.
- The current owned file cannot be backed up, or the new file cannot be written.
- `netplan try` is not accepted. This includes a health-check failure. The result is
  unaccepted, failed or uncertain. It does not prove that the revert finished.
- The apply is accepted, but a delete failed and its retry record could not be written. The
  removed VLANs are not confirmed gone.
- A stop request arrives after ACCEPT. The change stays, and the lease wait and agent restart
  can be skipped.
