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

printf '\n%s tests, %s failures\n' "$tests" "$fails"
[ "$fails" -eq 0 ]
