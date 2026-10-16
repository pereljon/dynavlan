# Missing-VLAN removal: test plan

Owns: the test cases and review findings for `dev/features/missing-vlan-removal.md`. Does not hold the design or its decisions.

Layer 1 cases run in `tests/unit.sh`. Layer 3 cases run on the test box, with the serial console open.

## Layer 1: unit tests

Pure helpers, written RED before GREEN. Every case lives in `tests/unit.sh` §1az, and each test name carries its MV id (for example `1az MV-7 missing for exactly the window is due`). MV-14 is covered by the existing §1au allowlist, template and defaults checks. §1az also covers the boot, rescan, `--status` and `--dry-run` wiring and the review fixes listed below.

| ID | Case | Expected |
|----|------|----------|
| MV-1 | First trusted miss of an owned VLAN | A missing-since line with the run's time is written |
| MV-2 | A later trusted miss | The original time is kept |
| MV-3 | A sample that sees the VLAN | Its line is deleted |
| MV-4 | An untrusted sample (a capture method failed) | The state is unchanged: no miss, no sighting |
| MV-5 | A carrier-down trunk | The state is unchanged; FR-41 owns the case |
| MV-6 | Missing for less than `REMOVE_MISSING_MINUTES` | Not due |
| MV-7 | Missing for exactly `REMOVE_MISSING_MINUTES` | Due |
| MV-8 | `REMOVE_MISSING_MINUTES=0` | Nothing is ever due, and no state is written |
| MV-9 | Case A: a trunk with carrier and no tags | Each owned VLAN on it becomes due on time |
| MV-10 | Case B: one VLAN gone, others still seen | Only the gone VLAN becomes due |
| MV-11 | A VLAN no longer owned | Its line is dropped on the next write |
| MV-12 | A missing or unreadable state file | Treated as empty; the run continues |
| MV-13 | Config: the default, `0`, the lower bound, `RESCAN_MINUTES * 2 - 1`, `1441`, and a non-integer | `15`; off; accepted; refused; refused; refused |
| MV-13a | Config: unset key with `RESCAN_MINUTES=10`; explicit `15` with `RESCAN_MINUTES=10`; unset key with `RESCAN_MINUTES=1000` | `20`; refused; `2000` |
| MV-15 | A recorded time above the current uptime | Restarted at the current uptime; not due |
| MV-14 | `CONFIG_KEYS` and the `dynavlan.conf` template | Both list the key (existing allowlist and template checks) |

## Layer 3: hardware tests

| ID | Case | Expected |
|----|------|----------|
| MV-H1 | Case A: remove every VLAN from switch port 6, then wait 15 minutes | A `warning` per VLAN with minutes left on each rescan, then a `notice` removal through `netplan try`; uplink stays healthy |
| MV-H2 | Case B: remove one VLAN from port 6 | Only that VLAN is removed, after 15 minutes |
| MV-H3 | Re-add the VLAN before 15 minutes | The clock resets; nothing is removed |
| MV-H4 | Reboot with a VLAN missing | Nothing is removed at boot; a rescan removes it 15 minutes after boot |
| MV-H5 | Case C: set port 6 to access mode | Every owned VLAN on `enp2s0` is removed after 15 minutes; the base interface keeps its address |
| MV-H6 | `REMOVE_MISSING_MINUTES=0` | 1.0.0 behavior: nothing is removed on a trunk with carrier |
| MV-H7 | A removed VLAN returns on the switch | The next rescan adds it back |

All seven Layer 3 cases passed on 2026-10-16 UTC on `1.1.1 (build 1df3567)`. MV-H1 and MV-H5 also ran on `enp1s0`, and MV-H2 used VLAN 22 because VLAN 200 sent no frames. Record: `docs/hardware-validation.md`, "Missing-VLAN removal pass".

## Review findings

Code review 2026-10-15 (Opus subagent, high effort) on the uncommitted 1.1.0 diff. Evidence was verified by reading the code and by probe scripts outside the repo.

- **I1 (Important, fixed).** `do_rescan` checked `have_routing` for missing removals before the FR-41 settle, so a due VLAN was applied after the post-settle check found routing gone. Fix: the missing-VLAN block runs after the FR-41 block. Test: `1az rescan: routing lost during the FR-41 settle also preserves a due missing VLAN`.
- **I2 (Important, fixed).** A failed write or unlink could leave a stale record, so a VLAN seen since could come due early. Fix: `write_missing_since` checks that the record is gone and empties it as a fallback; `missing_record` returns 1 when it cannot persist, so that run removes nothing by this rule. Tests: `1az a failed write drops the prior record and warns`, `1az a failed persist makes missing_record fail`, `1az an undeletable record is emptied and reported, never kept`, `1az rescan: a run that cannot persist its clocks removes nothing by this rule`.
- **I3 (design, resolved 2026-10-15, option a).** The clock measured time since the first miss, so carrier-down or untrusted runs counted toward the window. Fix: such a run restarts the trunk's clocks (`missing_classify`), `ver=1.1.1`. Tests: `1az MV-4 ...`, `1az MV-5 ...` and `1az I3 rescan: a carrier-down run between misses restarts the clock`, `1az I3 rescan: an untrusted run between misses restarts the clock`.
- **M1 (fixed).** `--status` no longer exits 1 for an unreadable uptime clock; the exit codes are unchanged.
- **M2 (accepted, documented in the design doc).** With the key on, a zero-detection boot with `REMOVE_ON_CARRIER_LOSS=false` no longer returns early: it runs the managed-elsewhere query and pass 2 to record its clocks.
- **M3 (fixed).** A recorded time over 12 digits is malformed and restarts. Test: `1az an oversized recorded time is malformed and restarts at now`.
- **M4 (fixed).** `--status` and `--dry-run` print an `incomplete` line when a detector failed. Test: `1az missing_report marks itself incomplete when a detector failed`.
- **M5 (fixed).** `--dry-run` warns when a due missing VLAN is the default-route interface (C1).
- **M6 (open, pre-existing).** `backend_remove_vlan` deletes a link without the L7 check that another netplan file defines the token; this applies to every removal path. Recorded in `context/open_questions.md`.
- **M7 (fixed).** In-shell tests point `MISSING_SINCE_FILE` and `UPTIME_FILE` at a temp dir, and the §1ar status environment pins the key to 0.
- **M8 (fixed).** The MV-8 rescan test seeds a record and asserts the 1.0.0 log line. The fix also found a gap: the key-0 early returns kept an old record, which a later re-enable could read as a stale clock. Both early returns now drop it.
