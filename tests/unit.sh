#!/usr/bin/env bash
#
# dynavlan unit tests - Layer 1 pure-helper asserts (dev/features/dynavlan-tests.md).
# Plain asserts, no framework. Run: bash tests/unit.sh
#
# Sources the dynavlan script (which guards main behind BASH_SOURCE) and exercises
# the side-effect-free helpers directly.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${here}/../dynavlan"

tests=0
fails=0
OUT=""
STATUS=0

call() { OUT="$("$@" 2>/dev/null)"; STATUS=$?; }

ok() { # desc expected  (asserts exit 0 and OUT == expected)
	tests=$((tests + 1))
	if [ "$STATUS" -eq 0 ] && [ "$OUT" = "$2" ]; then
		printf 'ok   - %s\n' "$1"
	else
		fails=$((fails + 1))
		printf 'FAIL - %s\n       expected [%s] exit 0, got [%s] exit %s\n' "$1" "$2" "$OUT" "$STATUS"
	fi
}

ver_ge() { # A B desc  (asserts version_ge A B is true)
	tests=$((tests + 1))
	if version_ge "$1" "$2"; then
		printf 'ok   - %s\n' "$3"
	else
		fails=$((fails + 1))
		printf 'FAIL - %s\n       expected %s >= %s\n' "$3" "$1" "$2"
	fi
}

ver_lt() { # A B desc  (asserts version_ge A B is false)
	tests=$((tests + 1))
	if version_ge "$1" "$2"; then
		fails=$((fails + 1))
		printf 'FAIL - %s\n       expected %s < %s\n' "$3" "$1" "$2"
	else
		printf 'ok   - %s\n' "$3"
	fi
}

err() { # desc  (asserts non-zero exit)
	tests=$((tests + 1))
	if [ "$STATUS" -ne 0 ]; then
		printf 'ok   - %s\n' "$1"
	else
		fails=$((fails + 1))
		printf 'FAIL - %s\n       expected non-zero exit, got [%s] exit 0\n' "$1" "$OUT"
	fi
}

# ---------------------------------------------------------------------------
# 1a. parse_vlan_ignore - expand comma/space list with low-high ranges into a set
# ---------------------------------------------------------------------------

call parse_vlan_ignore "1,5,20-25,80"; ok "1a ranges expand and sort"        "1 5 20 21 22 23 24 25 80"
call parse_vlan_ignore "1 5 80";       ok "1a space separators"              "1 5 80"
call parse_vlan_ignore "20-25,22";     ok "1a overlap collapses"             "20 21 22 23 24 25"
call parse_vlan_ignore "";             ok "1a empty input -> empty set"      ""
call parse_vlan_ignore "25-20";        err "1a range low>high"
call parse_vlan_ignore "5-";           err "1a incomplete range"
call parse_vlan_ignore "abc";          err "1a non-numeric"
call parse_vlan_ignore "1,,3";         err "1a empty element"
call parse_vlan_ignore "1,5000";       err "1a id above 4094"
call parse_vlan_ignore "0";            err "1a vlan 0 reserved"
call parse_vlan_ignore "4094";         ok "1a upper edge valid"              "4094"
call parse_vlan_ignore "4095";         err "1a vlan 4095 reserved"

# ---------------------------------------------------------------------------
# 1b. compute_candidates - detected ∩ [MIN,MAX] − IGNORE − managed − owned
#     args: detected  min  max  ignore  managed  owned   (space-separated sets)
# ---------------------------------------------------------------------------

call compute_candidates "1 18 21" 2 1000 ""   ""   "";   ok "1b below-MIN dropped"          "18 21"
call compute_candidates "18 21"   2 1000 "21" ""   "";   ok "1b ignore wins"               "18"
call compute_candidates "18 21"   2 1000 ""   "21" "";   ok "1b managed excluded"          "18"
call compute_candidates "18 21"   2 1000 ""   ""   "21"; ok "1b owned not re-added"        "18"
call compute_candidates "5000 18" 2 1000 ""   ""   "";   ok "1b above-MAX dropped"         "18"
call compute_candidates "18 21"   2 1000 ""   "21" "21"; ok "1b managed and owned overlap" "18"
call compute_candidates ""        2 1000 ""   ""   "";   ok "1b empty detection -> empty"  ""

# ---------------------------------------------------------------------------
# 1c. health_check_eval - PASS iff lowest-metric post default egresses snapshot iface
#     args: snap_iface  post_routes ("iface:metric ..." ; "" = no default route)
# ---------------------------------------------------------------------------

call health_check_eval "enp1s0" "enp1s0:10";            ok "1c same iface -> PASS"            "PASS"
call health_check_eval "enp1s0" "enp2s0:10";            ok "1c different iface -> FAIL"       "FAIL"
call health_check_eval "enp1s0" "";                     ok "1c lost default -> FAIL"          "FAIL"
call health_check_eval ""       "";                     ok "1c empty snap, empty -> PASS"     "PASS"
call health_check_eval ""       "enp1s0:10";            ok "1c empty snap, uplink up -> PASS" "PASS"
call health_check_eval "enp1s0" "enp1s0:20";            ok "1c metric changed -> PASS"        "PASS"
call health_check_eval "enp1s0" "enp1s0:10";            ok "1c gateway changed -> PASS"       "PASS"
call health_check_eval "enp1s0" "enp1s0:10 enp2s0:5";   ok "1c lower-metric elsewhere -> FAIL" "FAIL"

# ---------------------------------------------------------------------------
# 1d. boot_removals - owned VLANs absent from BOTH boot passes; zero-detection guard
#     args: owned  pass1  pass2
# ---------------------------------------------------------------------------

call boot_removals "18 21 22" "18 21" "18 21";       ok "1d absent from both -> removed"     "22"
call boot_removals "18 21 22" "18"    "18 21";       ok "1d present in pass2 kept"           "22"
call boot_removals "18 21 22" "18 21 22" "18 21 22"; ok "1d all present -> none"             ""
call boot_removals "18 21"    ""      "";            ok "1d both passes empty -> guard, none" ""

# ---------------------------------------------------------------------------
# 1e. select_trunk - most tagged port wins, with hysteresis toward the previous trunk
#     args: candidates ("iface:tagcount ...")  previous ("" if none)
# ---------------------------------------------------------------------------

call select_trunk "enp1s0:5 enp2s0:1" "";       ok "1e no previous -> most tags"       "enp1s0"
call select_trunk "enp1s0:3 enp2s0:3" "enp1s0"; ok "1e tie -> stick with previous"     "enp1s0"
call select_trunk "enp1s0:2 enp2s0:5" "enp1s0"; ok "1e clear supersede flips"          "enp2s0"
call select_trunk "enp1s0:3 enp2s0:4" "enp1s0"; ok "1e marginal lead does not flip"    "enp1s0"

# ---------------------------------------------------------------------------
# 1f. vlan_guard / limit_fill - VLAN_WARN / VLAN_LIMIT gate (0 = unlimited)
#     vlan_guard N WARN LIMIT -> OK | WARN | OVER ; limit_fill ADDS SLOTS -> lowest-N
# ---------------------------------------------------------------------------

call vlan_guard 10 32 64;  ok "1f under warn -> OK"                 "OK"
call vlan_guard 32 32 64;  ok "1f at warn -> OK (not above)"        "OK"
call vlan_guard 40 32 64;  ok "1f above warn -> WARN"               "WARN"
call vlan_guard 64 32 64;  ok "1f at limit -> WARN (not over)"      "WARN"
call vlan_guard 70 32 64;  ok "1f above limit -> OVER"              "OVER"
call vlan_guard 70 32 0;   ok "1f unlimited -> WARN not OVER"       "WARN"
call vlan_guard 5  32 0;   ok "1f unlimited under warn -> OK"       "OK"
call vlan_guard 20 32 10;  ok "1f limit below warn still fires"     "OVER"

call limit_fill "1 5 9 20" 2;  ok "1f fill lowest-2"                "1 5"
call limit_fill "9 1 5" 2;     ok "1f fill sorts before cut"        "1 5"
call limit_fill "1 5 9" 0;     ok "1f fill zero slots -> empty"     ""
call limit_fill "1 5" 10;      ok "1f fill slots exceed adds"       "1 5"

# ---------------------------------------------------------------------------
# 1g. assign_route_metrics / metric_conflict - VLAN_ROUTES metric assignment
#     assign_route_metrics KEPT_MAP ADDITIONS START MODE -> "id:metric ..." (sorted by id)
#       discovery: kept preserved verbatim; additions get max(START-1, highest kept)+1 ...
#       id: stateless metric = START + id for every id (kept map ignored)
#     metric_conflict UPLINK_METRIC MAP -> CONFLICT if any metric <= uplink, else OK
# ---------------------------------------------------------------------------

call assign_route_metrics "" "21 22" 100 discovery;            ok "1g discovery fresh start"              "21:100 22:101"
call assign_route_metrics "21:100 22:101" "18" 100 discovery;  ok "1g discovery new id continues, keeps"  "18:102 21:100 22:101"
call assign_route_metrics "21:100" "18 30" 100 discovery;      ok "1g discovery batch ascending"          "18:101 21:100 30:102"
call assign_route_metrics "21:100 22:101" "" 100 discovery;    ok "1g discovery no additions -> kept"     "21:100 22:101"
call assign_route_metrics "21:100" "25" 200 discovery;         ok "1g discovery raised START wins"        "21:100 25:200"
call assign_route_metrics "21:250" "25" 200 discovery;         ok "1g discovery high kept metric wins"    "21:250 25:251"
call assign_route_metrics "" "" 100 discovery;                 ok "1g discovery all empty -> empty"       ""
call assign_route_metrics "21:999" "18 22" 100 id;             ok "1g id mode stateless, ignores kept"    "18:118 21:121 22:122"
call assign_route_metrics "" "5" 100 id;                       ok "1g id mode fresh"                      "5:105"

call map_filter "18:102 21:100 22:101" "21 22";  ok "1g map_filter keeps listed ids"   "21:100 22:101"
call map_filter "18:102 21:100" "";              ok "1g map_filter empty ids -> empty" ""
call map_filter "" "21";                         ok "1g map_filter empty map -> empty" ""

call metric_conflict ""  "21:100 22:101";  ok "1g no uplink metric -> OK"        "OK"
call metric_conflict 10  "21:100 22:101";  ok "1g uplink below all -> OK"        "OK"
call metric_conflict 100 "21:100 22:101";  ok "1g tie with uplink -> CONFLICT"   "CONFLICT"
call metric_conflict 300 "21:100 22:101";  ok "1g uplink above -> CONFLICT"      "CONFLICT"
call metric_conflict 100 "";               ok "1g empty map -> OK"               "OK"

# ---------------------------------------------------------------------------
# 1g-bis. plan_route_metrics + map_ids - the FR-37 migration defect
#
# The bug this pins (found 2026-07-25, live in committed code): apply_change fed
# assign_route_metrics the ADDITIONS as the set needing metrics. The correct set
# is "target ids that do not already have one". Going isolated -> routed, EVERY
# owned id lacks a metric while additions is empty or partial, so generation hit
# "internal: no route metric assigned for VLAN N" and refused - permanently, and
# for every subsequent run, blocking new VLANs too. Routed mode only ever worked
# greenfield.
#
# Pinned as ONE function rather than a call sequence on purpose: --reapply (and
# any later drift check) must compute the map the SAME way apply_change does. Two
# call sites reimplementing this is how they silently diverge.
# ---------------------------------------------------------------------------

call map_ids "1:100 18:101"; ok "1g map_ids extracts ids" "1 18"
call map_ids ""; ok "1g map_ids of empty map -> empty" ""

# THE DEFECT: isolated -> routed on a box that already owns VLANs, no VLAN churn.
call plan_route_metrics "" "1 18 21" "" 100 discovery
ok "1g migration: every owned id gets a metric when none has one" "1:100 18:101 21:102"

# Same migration, with one genuinely new VLAN in the same run.
call plan_route_metrics "" "1 18 21 22" "22" 100 discovery
ok "1g migration + addition: all four assigned" "1:100 18:101 21:102 22:103"

# Steady state must be unchanged by the fix: kept metrics preserved verbatim.
call plan_route_metrics "1:100 18:101" "1 18 22" "22" 100 discovery
ok "1g steady state: kept verbatim, addition continues" "1:100 18:101 22:102"

# A reapply (zero additions, every id already has a metric) must NOT renumber.
call plan_route_metrics "1:100 18:101" "1 18" "" 100 discovery
ok "1g reapply with no churn does not renumber" "1:100 18:101"

# A removed VLAN's persisted metric is dropped, survivors keep theirs.
call plan_route_metrics "1:100 18:101 21:102" "1 18" "" 100 discovery
ok "1g removed VLAN's metric dropped, survivors verbatim" "1:100 18:101"

# id mode is stateless: START + id regardless of history.
call plan_route_metrics "" "18 22" "" 100 id
ok "1g id mode is stateless" "18:118 22:122"

# ---------------------------------------------------------------------------
# 1h. parse_version / version_ge - netplan version probe (FR-0)
#     `netplan --version` only exists on netplan >= 1.0; the 0.10x fleet is
#     identified through the package manager, so the parser must survive both
#     a bare "N.N" and a full Debian revision string.
# ---------------------------------------------------------------------------

call parse_version "netplan   1.0";               ok "1h netplan --version output"      "1.0"
call parse_version "0.107.1-3ubuntu0.22.04.4";    ok "1h dpkg revision suffix stripped" "0.107.1"
call parse_version "1:0.107.1-3ubuntu0.22.04.4";  ok "1h dpkg epoch prefix skipped"     "0.107.1"
call parse_version "0.106";                       ok "1h bare two-component version"    "0.106"
call parse_version "usage: /usr/sbin/netplan  [-h] [--debug]"; ok "1h help text -> empty" ""
call parse_version "";                            ok "1h empty input -> empty"          ""

ver_ge "1.0"     "0.106" "1h 1.0 >= 0.106 (sort -V, not string order)"
ver_ge "0.107.1" "0.106" "1h 0.107.1 >= 0.106"
ver_ge "0.106"   "0.106" "1h equal versions satisfy the floor"
ver_lt "0.105"   "0.106" "1h 0.105 below floor rejected"

# ---------------------------------------------------------------------------
# 1i. lldp_tagged_vlans - PVID exclusion (FR-4)
#     `lldpctl -f keyvalue` emits one flat block per advertised VLAN, and the
#     native VLAN is flagged pvid=yes. The native VLAN is UNTAGGED on the wire,
#     so a VLAN interface for it can never receive a frame; LLDP must not offer
#     it as a tagged candidate. Blocks are correlated by adjacency only, so the
#     parse is stateful: vlan-id opens a block, the following pvid closes it.
# ---------------------------------------------------------------------------

lldp_meraki='lldp.enp1s0.vlan.vlan-id=100
lldp.enp1s0.vlan.pvid=yes'

lldp_mixed='lldp.eth0.vlan.vlan-id=100
lldp.eth0.vlan.pvid=yes
lldp.eth0.vlan.vlan-id=21
lldp.eth0.vlan.pvid=no
lldp.eth0.vlan.vlan-id=22
lldp.eth0.vlan.pvid=no'

lldp_named='lldp.eth0.vlan=Voice
lldp.eth0.vlan.vlan-id=30
lldp.eth0.vlan.pvid=no
lldp.eth0.vlan=Native
lldp.eth0.vlan.vlan-id=1
lldp.eth0.vlan.pvid=yes'

lldp_no_pvid='lldp.eth0.vlan.vlan-id=100
lldp.eth0.vlan.vlan-id=21'

call lldp_tagged_vlans "$lldp_meraki";   ok "1i Meraki trunk: sole VLAN is the PVID -> empty" ""
call lldp_tagged_vlans "$lldp_mixed";    ok "1i PVID dropped, tagged VLANs kept"    "21 22"
call lldp_tagged_vlans "$lldp_named";    ok "1i named blocks, PVID dropped"         "30"
call lldp_tagged_vlans "$lldp_no_pvid";  ok "1i absent pvid key -> treated tagged"  "21 100"
call lldp_tagged_vlans "lldp.eth0.chassis.name=sw1"; ok "1i no vlan lines -> empty" ""

# Key-shape isolation (review 2026-07-25). The patterns must anchor on the VLAN
# TLV's own keys (`.vlan.vlan-id=` / `.vlan.pvid=yes`), not on any key that merely
# ENDS in `.vlan-id=`. Matching loosely, a foreign key landing between a VLAN's
# vlan-id and its pvid flushes that vlan-id as "tagged" before the pvid arrives -
# and the pvid then clears the WRONG pending id. That reintroduces FR-7a exactly:
# a dead interface built for the untagged native VLAN. lldpd's full key set is not
# documented here, so the parse must not depend on assuming what else it emits.
lldp_foreign_key='"'"'lldp.eth0.vlan.vlan-id=100
lldp.eth0.mgmt.vlan-id=999
lldp.eth0.vlan.pvid=yes'"'"'
call lldp_tagged_vlans "$lldp_foreign_key"; ok "1i foreign .vlan-id= key must not flush the pvid block" ""

lldp_med_policy='"'"'lldp.eth0.vlan.vlan-id=30
lldp.eth0.vlan.pvid=no
lldp.eth0.med.policy.vlan-id=200
lldp.eth0.vlan.vlan-id=100
lldp.eth0.vlan.pvid=yes'"'"'
call lldp_tagged_vlans "$lldp_med_policy"; ok "1i foreign key does not leak an id nor unmask the native VLAN" "30"
call lldp_tagged_vlans "";               ok "1i empty input -> empty"               ""

# ---------------------------------------------------------------------------
# 1j. render_timer_dropin - FR-21 timer interval drop-in
#     An empty assignment to ANY On*Sec= resets the ENTIRE monotonic timer
#     list, so the drop-in must restate every trigger, not just the interval.
#     Rendering only OnUnitActiveSec left the timer with no first-fire anchor
#     and it never elapsed (hardware-validated dead timer, 2026-07-25). The
#     exact-match assert pins both the content AND the ordering: the reset has
#     to come before the re-assignments or it wipes them too.
# ---------------------------------------------------------------------------

read -r -d '' expect_dropin <<'EOF' || true
# Rendered by dynavlan --reconfigure from RESCAN_MINUTES. Do not edit.
[Timer]
# An empty On*Sec= resets the ENTIRE monotonic timer list (not just the option
# assigned), so every trigger the base unit declares must be restated here.
OnUnitActiveSec=
OnActiveSec=2min
OnUnitActiveSec=7min
EOF

call render_timer_dropin 7; ok "1j drop-in restates first-fire + interval, reset first" "$expect_dropin"

call render_timer_dropin 5
tests=$((tests + 1))
case "$OUT" in
*"OnActiveSec="*) printf 'ok   - %s\n' "1j first-fire trigger is always present (regression guard)" ;;
*)
	fails=$((fails + 1))
	printf 'FAIL - %s\n       no first-fire trigger; timer would never elapse\n' "1j first-fire trigger is always present (regression guard)"
	;;
esac

# ---------------------------------------------------------------------------
# 1k. version_string - build provenance (FR-38)
#
# The format is asserted, not just the content: this string is what a journal
# line and `--version` both print, and it is the only way to tell two builds of
# the same unreleased semver apart. An empty build must degrade to "unknown"
# rather than render "(build )", so a botched install-time stamp is visible
# instead of looking like a legitimate identity.
# ---------------------------------------------------------------------------

call version_string "0.1.0" "source"
ok "1k version + source build" "0.1.0 (build source)"

call version_string "0.1.0" "18a6ea2"
ok "1k version + commit build" "0.1.0 (build 18a6ea2)"

call version_string "0.1.0" "18a6ea2-dirty"
ok "1k dirty build is carried verbatim" "0.1.0 (build 18a6ea2-dirty)"

call version_string "0.1.0" ""
ok "1k empty build degrades to unknown, never '(build )'" "0.1.0 (build unknown)"

# ---------------------------------------------------------------------------
# 1l. Build-stamp contract (FR-38) - guards a CROSS-FILE invariant
#
# install.sh rewrites the `build=` line at install time by matching /^build=/.
# That coupling is invisible from either file alone: rename the variable, indent
# it, compute it, or add a second `build=` line, and the stamp silently targets
# the wrong line or no line. The installer would still succeed, and every box
# installed afterwards would misreport which code it runs - the exact failure
# FR-38 exists to prevent, reintroduced by a tidy-up.
#
# So this asserts the contract itself rather than any function: the line exists,
# exactly once, at column 0, and the real stamping transform still produces a
# script that parses and differs by that one line only.
# ---------------------------------------------------------------------------

src="${here}/../dynavlan"

assert_eq() { # actual expected desc
	tests=$((tests + 1))
	if [ "$1" = "$2" ]; then
		printf 'ok   - %s\n' "$3"
	else
		fails=$((fails + 1))
		printf 'FAIL - %s\n       expected [%s], got [%s]\n' "$3" "$2" "$1"
	fi
}

assert_eq "$(grep -c '^build=' "$src")" "1" "1l exactly one column-0 build= line (install.sh stamps /^build=/)"
assert_eq "$(grep -c '^ver=' "$src")" "1" "1l exactly one column-0 ver= line"

# Apply the installer's exact transform and verify the result end to end.
stamp_tmp="$(mktemp)"
awk -v b="0000000-test" '
	!stamped && /^build=/ { printf "build=\"%s\"\n", b; stamped = 1; next }
	{ print }
' "$src" >"$stamp_tmp"

assert_eq "$(grep -c '^build="0000000-test"$' "$stamp_tmp")" "1" "1l stamping transform substitutes the build line"
assert_eq "$(diff "$src" "$stamp_tmp" | grep -c '^[<>]')" "2" "1l stamping changes exactly one line (one < and one >)"
assert_eq "$(wc -l <"$stamp_tmp" | tr -d ' ')" "$(wc -l <"$src" | tr -d ' ')" "1l stamping preserves line count"

if bash -n "$stamp_tmp" 2>/dev/null; then
	tests=$((tests + 1))
	printf 'ok   - %s\n' "1l stamped script still parses"
else
	tests=$((tests + 1))
	fails=$((fails + 1))
	printf 'FAIL - %s\n       stamped script fails bash -n\n' "1l stamped script still parses"
fi

# The stamped script must report the stamped identity, not the source default.
assert_eq "$(bash "$stamp_tmp" --version)" "dynavlan $ver (build 0000000-test)" "1l stamped script reports its stamped build via --version"
assert_eq "$(bash "$src" --version)" "dynavlan $ver (build source)" "1l unstamped checkout reports 'source'"

rm -f "$stamp_tmp"

# ---------------------------------------------------------------------------
# 1m. config_body_differs - FR-39 reapply comparison
#
# Line 1 is the `# Managed by dynavlan <ver> (build <id>)` header. FR-38 put the
# build id there, so a whole-file comparison would report a difference after every
# rebuild and make --reapply always apply - a no-change apply on the one operation
# that can strand a box. The skip is POSITIONAL (exactly line 1), never a pattern
# match on header text: a pattern match would silently stop working if the header
# format ever changed, and the failure would be an apply loop.
# ---------------------------------------------------------------------------

body_a='# Managed by dynavlan 0.1.0 (build aaaaaaa)
network:
  version: 2
  vlans:
    enp1s0.18:
      dhcp4: true'
body_b='# Managed by dynavlan 0.1.0 (build bbbbbbb-dirty)
network:
  version: 2
  vlans:
    enp1s0.18:
      dhcp4: true'
body_c='# Managed by dynavlan 0.1.0 (build aaaaaaa)
network:
  version: 2
  vlans:
    enp1s0.18:
      dhcp4: true
      accept-ra: false'
body_d='# Managed by dynavlan 0.1.0 (build aaaaaaa)
NETWORK-DIFFERS-ON-LINE-2:
  version: 2
  vlans:
    enp1s0.18:
      dhcp4: true'

call config_body_differs "$body_a" "$body_a"; ok "1m identical -> SAME" "SAME"
call config_body_differs "$body_a" "$body_b"; ok "1m header/build differs ONLY -> SAME (the FR-38 apply-loop guard)" "SAME"
call config_body_differs "$body_a" "$body_c"; ok "1m body differs -> DIFFERENT" "DIFFERENT"
call config_body_differs "$body_a" "$body_d"; ok "1m difference on line 2 is still caught" "DIFFERENT"
call config_body_differs "$body_a" ""; ok "1m empty live file -> DIFFERENT" "DIFFERENT"
call config_body_differs "" ""; ok "1m both empty -> SAME" "SAME"

# ---------------------------------------------------------------------------

printf '\n%s tests, %s failures\n' "$tests" "$fails"
[ "$fails" -eq 0 ]
