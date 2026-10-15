# Missing-VLAN removal: test plan

Owns: the test cases and review findings for `dev/features/missing-vlan-removal.md`. Does not hold the design or its decisions.

Layer 1 cases run in `tests/unit.sh`. Layer 3 cases run on the test box, with the serial console open.

## Layer 1: unit tests

Pure helpers, written RED before GREEN.

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

## Review findings

None yet.
