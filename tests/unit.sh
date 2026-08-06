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
# 1r. carrier_removals - full owned set removed only when BOTH carrier samples down
#     args: owned_on_trunk  c1  c2   (c1/c2 = up|down)
# ---------------------------------------------------------------------------

call carrier_removals "18 21 22" down down; ok "1r both down -> full set removed" "18 21 22"
call carrier_removals "18 21 22" up   down; ok "1r pass1 up (flap) -> none"       ""
call carrier_removals "18 21 22" down up;   ok "1r pass2 up (flap) -> none"       ""
call carrier_removals "18 21 22" up   up;   ok "1r both up -> none"               ""
call carrier_removals ""         down down; ok "1r empty owned -> none"           ""
call carrier_removals "22 18 21" down down; ok "1r output is sorted"              "18 21 22"

# ---------------------------------------------------------------------------
# 1s. have_routing - true iff a default route exists, its dev has carrier, AND at
#     least one physical NIC has carrier. The third clause is what stops a
#     tun/wireguard default (which reports carrier=1 whenever merely up) from
#     making an all-dark box look healthy and re-enabling FR-41 pruning (AC-4).
#     Stubs snapshot_default_route + has_carrier + discover_phys_ifaces.
# ---------------------------------------------------------------------------

_sdr_saved=$(declare -f snapshot_default_route)
_hc_saved=$(declare -f has_carrier)
_dpi_saved=$(declare -f discover_phys_ifaces)

# STUB_UP is the set of ifaces with carrier; STUB_PHYS is what the box has.
snapshot_default_route() { printf '%s' "$STUB_DEV"; }
has_carrier() { case " $STUB_UP " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
discover_phys_ifaces() { printf '%s\n' $STUB_PHYS; }
routing_says() { if have_routing; then echo yes; else echo no; fi; }

STUB_PHYS="enp1s0 enp2s0"

STUB_DEV=enp1s0; STUB_UP="enp1s0"; call routing_says
ok "1s default route + carrier -> routing" "yes"
STUB_DEV=enp1s0; STUB_UP="enp2s0"; call routing_says
ok "1s default route, dead egress -> no routing" "no"
STUB_DEV="";     STUB_UP="enp1s0"; call routing_says
ok "1s no default route -> no routing" "no"

# Default egresses a live physical NIC while a second trunk is dark: still healthy.
# This is the mixed case FR-41 prunes in - it must NOT be blocked.
STUB_DEV=enp1s0; STUB_UP="enp1s0"; STUB_PHYS="enp1s0 enp2s0"; call routing_says
ok "1s live uplink + dark second trunk -> routing (prune allowed)" "yes"

# Tunnel default, every physical NIC dark: the wireguard netdev reports carrier,
# but the box is all-dark and must preserve.
STUB_DEV=wg0; STUB_UP="wg0"; STUB_PHYS="enp1s0 enp2s0"; call routing_says
ok "1s tunnel default, all physical dark -> no routing" "no"

# Tunnel default over a live physical uplink: legitimately routed VPN box, and
# FR-41 must keep working there.
STUB_DEV=wg0; STUB_UP="wg0 enp1s0"; STUB_PHYS="enp1s0 enp2s0"; call routing_says
ok "1s tunnel default over a live NIC -> routing" "yes"

# No physical NICs discovered at all (nothing to vouch for the route).
STUB_DEV=wg0; STUB_UP="wg0"; STUB_PHYS=""; call routing_says
ok "1s no physical NICs -> no routing" "no"

eval "$_sdr_saved"
eval "$_hc_saved"
eval "$_dpi_saved"
unset STUB_DEV STUB_UP STUB_PHYS

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

# M7: fill keeps the lowest NUMERIC ids (not lexical); output in numeric order
call limit_fill "eth0.1 eth0.5 eth0.9 eth0.20" 2;   ok "1f fill lowest-2 numeric (not eth0.20)" "eth0.1 eth0.5"
call limit_fill "eth0.2 eth0.10 eth0.100" 2;        ok "1f fill numeric vs lexical discriminator" "eth0.2 eth0.10"
call limit_fill "eth0.9 eth0.1 eth0.5" 2;     ok "1f fill sorts before cut"        "eth0.1 eth0.5"
call limit_fill "eth0.1 eth0.5 eth0.9" 0;     ok "1f fill zero slots -> empty"     ""
call limit_fill "eth0.1 eth0.5" 10;            ok "1f fill slots exceed adds"       "eth0.1 eth0.5"
# lowest numeric id globally, interface name as tie-break
call sort_tokens_by_id "enp2s0.10" "enp1s0.2" "enp1s0.100"; ok "1f sort_tokens_by_id numeric-then-iface" "enp1s0.2 enp2s0.10 enp1s0.100"

# ---------------------------------------------------------------------------
# 1g. assign_route_metrics / metric_conflict - VLAN_ROUTES metric assignment
#     assign_route_metrics KEPT_MAP ADDITIONS START -> "tok:metric ..." (sorted by tok)
#       kept preserved verbatim; additions get max(START-1, highest kept)+1 ...
#     metric_conflict UPLINK_METRIC MAP -> CONFLICT if any metric <= uplink, else OK
# ---------------------------------------------------------------------------

call assign_route_metrics "" "enp1s0.21 enp1s0.22" 100;                          ok "1g fresh start"              "enp1s0.21:100 enp1s0.22:101"
call assign_route_metrics "enp1s0.21:100 enp1s0.22:101" "enp1s0.18" 100;         ok "1g new id continues, keeps"  "enp1s0.18:102 enp1s0.21:100 enp1s0.22:101"
call assign_route_metrics "enp1s0.21:100" "enp1s0.18 enp1s0.30" 100;             ok "1g batch ascending"          "enp1s0.18:101 enp1s0.21:100 enp1s0.30:102"
call assign_route_metrics "enp1s0.21:100 enp1s0.22:101" "" 100;                  ok "1g no additions -> kept"     "enp1s0.21:100 enp1s0.22:101"
call assign_route_metrics "enp1s0.21:100" "enp1s0.25" 200;                       ok "1g raised START wins"        "enp1s0.21:100 enp1s0.25:200"
call assign_route_metrics "enp1s0.21:250" "enp1s0.25" 200;                       ok "1g high kept metric wins"    "enp1s0.21:250 enp1s0.25:251"
call assign_route_metrics "" "" 100;                                              ok "1g all empty -> empty"       ""
call map_filter "enp1s0.18:102 enp1s0.21:100 enp1s0.22:101" "enp1s0.21 enp1s0.22";  ok "1g map_filter keeps listed ids"   "enp1s0.21:100 enp1s0.22:101"
call map_filter "enp1s0.18:102 enp1s0.21:100" "";              ok "1g map_filter empty ids -> empty" ""
call map_filter "" "enp1s0.21";                                ok "1g map_filter empty map -> empty" ""

call metric_conflict ""  "enp1s0.21:100 enp1s0.22:101";  ok "1g no uplink metric -> OK"        "OK"
call metric_conflict 10  "enp1s0.21:100 enp1s0.22:101";  ok "1g uplink below all -> OK"        "OK"
call metric_conflict 100 "enp1s0.21:100 enp1s0.22:101";  ok "1g tie with uplink -> CONFLICT"   "CONFLICT"
call metric_conflict 300 "enp1s0.21:100 enp1s0.22:101";  ok "1g uplink above -> CONFLICT"      "CONFLICT"
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

call map_ids "enp1s0.1:100 enp1s0.18:101"; ok "1g map_ids extracts ids" "enp1s0.1 enp1s0.18"
call map_ids ""; ok "1g map_ids of empty map -> empty" ""

# THE DEFECT: isolated -> routed on a box that already owns VLANs, no VLAN churn.
call plan_route_metrics "" "enp1s0.1 enp1s0.18 enp1s0.21" "" 100
ok "1g migration: every owned id gets a metric when none has one" "enp1s0.1:100 enp1s0.18:101 enp1s0.21:102"

# Same migration, with one genuinely new VLAN in the same run.
call plan_route_metrics "" "enp1s0.1 enp1s0.18 enp1s0.21 enp1s0.22" "enp1s0.22" 100
ok "1g migration + addition: all four assigned" "enp1s0.1:100 enp1s0.18:101 enp1s0.21:102 enp1s0.22:103"

# Steady state must be unchanged by the fix: kept metrics preserved verbatim.
call plan_route_metrics "enp1s0.1:100 enp1s0.18:101" "enp1s0.1 enp1s0.18 enp1s0.22" "enp1s0.22" 100
ok "1g steady state: kept verbatim, addition continues" "enp1s0.1:100 enp1s0.18:101 enp1s0.22:102"

# A reapply (zero additions, every id already has a metric) must NOT renumber.
call plan_route_metrics "enp1s0.1:100 enp1s0.18:101" "enp1s0.1 enp1s0.18" "" 100
ok "1g reapply with no churn does not renumber" "enp1s0.1:100 enp1s0.18:101"

# A removed VLAN's persisted metric is dropped, survivors keep theirs.
call plan_route_metrics "enp1s0.1:100 enp1s0.18:101 enp1s0.21:102" "enp1s0.1 enp1s0.18" "" 100
ok "1g removed VLAN's metric dropped, survivors verbatim" "enp1s0.1:100 enp1s0.18:101"

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
# 1x. build-deb.sh binds the packaged version to the script's ver= (H7/FR-38)
#     A release is tag-triggered and CI passes the tag-derived version to
#     build-deb.sh. If that version disagrees with the script's ver=, the
#     package (and its --version) would misreport the build. build-deb.sh MUST
#     refuse rather than publish a mislabeled package. Asserted on the mismatch
#     MESSAGE, not a bare non-zero: a dev box without dpkg-deb also exits
#     non-zero, which would mask a missing guard.
# ---------------------------------------------------------------------------

mismatch_out="$(bash "${here}/../build-deb.sh" 9.9.9 2>&1)"; mismatch_rc=$?
tests=$((tests + 1))
if [ "$mismatch_rc" -ne 0 ] && printf '%s' "$mismatch_out" | grep -q "does not match"; then
	printf 'ok   - %s\n' "1x build-deb refuses a version != script ver="
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected non-zero + "does not match", rc=%s out=[%s]\n' \
		"1x build-deb refuses a version != script ver=" "$mismatch_rc" "$mismatch_out"
fi

# ---------------------------------------------------------------------------
# 1y. apply_settle_floor - C2 apply-evidence floor (minimal-#1)
#
# A no-addition change (removal-only, --reapply) has NO in-kernel apply signal
# during the netplan-try window: netplan try does not delete removed VLAN
# netdevs (dynavlan does, only post-ACCEPT), and a rerender changes no kernel
# state (SKELETON: "No-additions changes anchor at t=0"). So there is nothing to
# observe, and the box relies on a conservative settle floor sized to exceed a
# real apply, so the FIRST health sample lands POST-apply, not on pre-apply
# routing. apply_settle_floor returns that larger floor when no probe iface
# exists, and the normal fallback floor when one does. The no-evidence floor
# must still leave room for HEALTH_CONSEC health samples before accept_cutoff
# (= TRY_TIMEOUT - 2*POLL_INTERVAL); otherwise a no-addition change could never
# accept. Both relationships are asserted, not just the value, so tuning the
# constant on hardware cannot silently push it past the cutoff.
# ---------------------------------------------------------------------------

call apply_settle_floor "enp1s0.100"; ok "1y probe present -> fallback floor"       "$APPLY_FALLBACK_SETTLE"
call apply_settle_floor "";           ok "1y no probe -> larger no-evidence floor"  "$APPLY_NOEVIDENCE_SETTLE"

tests=$((tests + 1))
if [ -n "$APPLY_NOEVIDENCE_SETTLE" ] && [ "$APPLY_NOEVIDENCE_SETTLE" -gt "$APPLY_FALLBACK_SETTLE" ] 2>/dev/null; then
	printf 'ok   - %s\n' "1y no-evidence floor exceeds the fallback floor"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       APPLY_NOEVIDENCE_SETTLE=[%s] must be > APPLY_FALLBACK_SETTLE=[%s]\n' \
		"1y no-evidence floor exceeds the fallback floor" "$APPLY_NOEVIDENCE_SETTLE" "$APPLY_FALLBACK_SETTLE"
fi

y_cutoff=$((TRY_TIMEOUT - 2 * POLL_INTERVAL))
y_maxfloor=$((y_cutoff - HEALTH_CONSEC * POLL_INTERVAL))
tests=$((tests + 1))
if [ -n "$APPLY_NOEVIDENCE_SETTLE" ] && [ "$APPLY_NOEVIDENCE_SETTLE" -le "$y_maxfloor" ] 2>/dev/null; then
	printf 'ok   - %s\n' "1y no-evidence floor leaves room for HEALTH_CONSEC samples before cutoff"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       APPLY_NOEVIDENCE_SETTLE=[%s] must be <= cutoff(%s) - HEALTH_CONSEC*POLL(%s) = %s\n' \
		"1y no-evidence floor leaves room for HEALTH_CONSEC samples before cutoff" \
		"$APPLY_NOEVIDENCE_SETTLE" "$y_cutoff" "$((HEALTH_CONSEC * POLL_INTERVAL))" "$y_maxfloor"
fi

# ---------------------------------------------------------------------------
# 1z. Config isolation - parse-only allowlist (H2)
#
# load_config no longer SOURCES /etc/dynavlan.conf; config_load_file parses it
# declaratively so a config line can NEVER execute code or assign an internal /
# safety variable (NETPLAN_FILE, TRY_TIMEOUT, ver, PATH, ...). Only allowlisted
# KEY=value lines are honored; any unknown/protected key or non-assignment line
# refuses (non-zero, and a protected global is never written). Values are inert
# literals (printf -v), so a $(...) in a value is a harmless string the value
# validators reject later - proven here by asserting no side effect.
# ---------------------------------------------------------------------------

call config_allowed_key VLAN_MIN;       ok  "1z documented key allowed"           ""
call config_allowed_key RESTART_SNAPS;  ok  "1z documented list key allowed"      ""
call config_allowed_key NETPLAN_FILE;   err "1z internal name refused"
call config_allowed_key TRY_TIMEOUT;    err "1z safety constant refused"
call config_allowed_key ver;            err "1z build-identity var refused"
call config_allowed_key PATH;           err "1z PATH refused"
call config_allowed_key VLAN_MINN;      err "1z typo'd key refused"
call config_allowed_key PER_VLAN_MAC;   err "1z removed PER_VLAN_MAC key refused (0.4.3)"

call config_normalize_value '5   # id floor';          ok "1z unquoted + inline comment"     "5"
call config_normalize_value '"domotz agent"   # snap'; ok "1z quoted value keeps inner space" "domotz agent"
call config_normalize_value '""';                      ok "1z empty quoted -> empty"          ""
call config_normalize_value 'both';                    ok "1z bare token"                     "both"
call config_normalize_value '1,5,20-25';               ok "1z comma/range list"               "1,5,20-25"
call config_normalize_value 'a b c';                   ok "1z unquoted list preserved, not truncated" "a b c"
call config_normalize_value 'a b   # trailing';        ok "1z unquoted list + inline comment"  "a b"

# config_load_file exercised on real files (direct call, not `call`: the
# assignments must land in THIS shell to be asserted; `call` subshells them away).
z_tmp=$(mktemp)

printf 'VLAN_MIN=5   # floor\nRESTART_SERVICES="a b c"\n# a comment\n\n' > "$z_tmp"
VLAN_MIN=1; RESTART_SERVICES=""
config_load_file "$z_tmp" >/dev/null 2>&1; z_rc=$?
tests=$((tests + 1))
if [ "$z_rc" -eq 0 ] && [ "$VLAN_MIN" = 5 ] && [ "$RESTART_SERVICES" = "a b c" ]; then
	printf 'ok   - %s\n' "1z valid file: allowlisted keys assigned (quotes + comment stripped)"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       rc=%s VLAN_MIN=[%s] RESTART_SERVICES=[%s]\n' \
		"1z valid file: allowlisted keys assigned (quotes + comment stripped)" "$z_rc" "$VLAN_MIN" "$RESTART_SERVICES"
fi

printf 'NETPLAN_FILE=/tmp/evil.yaml\n' > "$z_tmp"
z_np_before="$NETPLAN_FILE"
config_load_file "$z_tmp" >/dev/null 2>&1; z_rc=$?
tests=$((tests + 1))
if [ "$z_rc" -ne 0 ] && [ "$NETPLAN_FILE" = "$z_np_before" ]; then
	printf 'ok   - %s\n' "1z protected internal assignment refused, global untouched"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       rc=%s NETPLAN_FILE=[%s] (was [%s])\n' \
		"1z protected internal assignment refused, global untouched" "$z_rc" "$NETPLAN_FILE" "$z_np_before"
fi

printf 'rm -rf /\n' > "$z_tmp"
config_load_file "$z_tmp" >/dev/null 2>&1; z_rc=$?
tests=$((tests + 1))
if [ "$z_rc" -ne 0 ]; then
	printf 'ok   - %s\n' "1z non-assignment line refused"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected non-zero for a non-assignment line\n' "1z non-assignment line refused"
fi

z_sentinel=$(mktemp -u)
printf 'VLAN_IGNORE="$(touch %s)"\n' "$z_sentinel" > "$z_tmp"
VLAN_IGNORE=""
config_load_file "$z_tmp" >/dev/null 2>&1; z_rc=$?
tests=$((tests + 1))
if [ "$z_rc" -eq 0 ] && [ ! -e "$z_sentinel" ] && [ "$VLAN_IGNORE" = "\$(touch $z_sentinel)" ]; then
	printf 'ok   - %s\n' "1z command substitution in a value is an inert literal (no exec)"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       rc=%s sentinel-exists=%s VLAN_IGNORE=[%s]\n' \
		"1z command substitution in a value is an inert literal (no exec)" \
		"$z_rc" "$([ -e "$z_sentinel" ] && echo yes || echo no)" "$VLAN_IGNORE"
fi

rm -f "$z_tmp" "$z_sentinel"

# ---------------------------------------------------------------------------
# 1aa. default_iface_in_removals - C1 routed-mode delete guard
#
# In routed mode a dynavlan VLAN can be the box's default egress (FR-37). If that
# VLAN is also in the removal set, the post-ACCEPT `ip link delete` would tear down
# the default route AFTER netplan try already committed (health passed because the
# VLAN is still up during the try; the delete is post-accept) - unrevertable.
# apply_change refuses the whole reconcile BEFORE any disk change when this holds.
# The guard fires only for a NON-EMPTY snap_iface that exactly matches a removal
# token: the base uplink (isolation default) is never a token, no default route
# means nothing to protect, and a same-id VLAN on a DIFFERENT trunk is a distinct
# token that must NOT false-positive.
# ---------------------------------------------------------------------------

call default_iface_in_removals "enp1s0.100" "enp1s0.100 enp1s0.101"; ok  "1aa default VLAN in removals -> guard fires"          ""
call default_iface_in_removals "enp1s0"     "enp1s0.100";            err "1aa base uplink never a removal token (isolation)"
call default_iface_in_removals ""           "enp1s0.100";            err "1aa no default route -> nothing to guard"
call default_iface_in_removals "enp1s0.100" "enp1s0.101 enp1s0.102"; err "1aa default VLAN not being removed -> proceed"
call default_iface_in_removals "enp2s0.100" "enp1s0.100";            err "1aa same id on a different trunk is distinct, no false positive"
call default_iface_in_removals "enp1s0.100" "enp1s0.1000 enp1s0.101"; err "1aa no substring false-match (.100 vs .1000)"
call default_iface_in_removals "enp1s0.10"  "enp1s0.100";            err "1aa no prefix false-match (.10 vs .100)"
call default_iface_in_removals "enp1s0.100" "";                      err "1aa empty removals -> proceed"

# ---------------------------------------------------------------------------
# 1ab. detection_sample_valid - H1: a detector failure must not read as absence
#
# A capture method that FAILED at runtime (tcpdump could not open the device / bad
# filter, lldpctl daemon down, or promisc could not be set) returns an empty or
# truncated id set that is indistinguishable from a trunk that genuinely carries
# nothing. A partial (failure-truncated) set must NOT authorize a detection-diff
# removal. This pure helper decides, from the per-method run statuses, whether a
# boot detection sample is complete enough to be trusted for REMOVALS (additions
# still proceed on whatever positive evidence exists). METHOD SNIFF LLDP PREP,
# each status ok|fail (na for a method the mode does not run); prints "valid" or
# empty. A prep failure invalidates regardless of method. Under "both" only SNIFF
# must have succeeded: sniff is the primary/authoritative wire signal and a failed
# sniff is the real removal hazard, while LLDP is a supplement whose failure is
# non-fatal (a down lldpd must not block removals on sniff-authoritative trunks).
# ---------------------------------------------------------------------------

call detection_sample_valid both  ok   ok   ok; ok  "1ab both: both methods ok -> valid"        "valid"
call detection_sample_valid both  fail ok   ok; ok  "1ab both: sniff failed -> invalid"          ""
call detection_sample_valid both  ok   fail ok; ok  "1ab both: lldp failed, sniff ok -> valid"   "valid"
call detection_sample_valid both  fail fail ok; ok  "1ab both: both failed -> invalid"           ""
call detection_sample_valid sniff ok   na   ok; ok  "1ab sniff: sniff ok -> valid"               "valid"
call detection_sample_valid sniff fail na   ok; ok  "1ab sniff: sniff failed -> invalid"         ""
call detection_sample_valid lldp  na   ok   ok; ok  "1ab lldp: lldp ok -> valid"                 "valid"
call detection_sample_valid lldp  na   fail ok; ok  "1ab lldp: lldp failed -> invalid"           ""
call detection_sample_valid both  ok   ok   fail; ok "1ab prep failure invalidates a good sample" ""
call detection_sample_valid sniff ok   na   fail; ok "1ab prep failure invalidates sniff-only"    ""

# ---------------------------------------------------------------------------
# 1ac. store_detection - H1: the detect_iface "SNIFF LLDP IDS..." parse round-trip
#
# Locks the string contract between detect_iface (emits "SNIFFSTATUS LLDPSTATUS
# IDS...") and store_detection (parses it, stashes TAGS_ + VALID_). The hazard case
# the fix exists for: sniff FAILED but LLDP returned a partial set, so the tag set
# is non-empty (still usable for additions) yet the sample is INVALID (must not
# authorize a removal). Also covers a missing/empty raw line defaulting to invalid.
# ---------------------------------------------------------------------------

DETECT_METHOD=both
# valid sample, ids from both methods -> TAGS unioned, VALID=valid
unset PREPFAIL_v0 TAGS_v0 VALID_v0
store_detection v0 "ok ok 100 200"
assert_eq "$(iface_valid v0)|$(iface_tags v0)" "valid|100 200" "1ac both ok -> valid, tags unioned"
# H1 hazard: sniff failed, LLDP partial -> tags survive for additions, VALID=invalid
unset PREPFAIL_v1 TAGS_v1 VALID_v1
store_detection v1 "fail ok 200"
assert_eq "$(iface_valid v1)|$(iface_tags v1)" "invalid|200" "1ac sniff fail + partial lldp -> invalid, tags kept"
# prep failure invalidates even when both methods returned ids
PREPFAIL_v2=1
unset TAGS_v2 VALID_v2
store_detection v2 "ok ok 100 200"
assert_eq "$(iface_valid v2)|$(iface_tags v2)" "invalid|100 200" "1ac prep fail -> invalid, tags kept"
# empty raw (missing scratch file) defaults to invalid, no tags
unset PREPFAIL_v3 TAGS_v3 VALID_v3
store_detection v3 ""
assert_eq "$(iface_valid v3)|$(iface_tags v3)" "invalid|" "1ac empty raw -> invalid, no tags"
# valid but genuinely empty (quiet trunk) -> valid, no tags (removal-diff still allowed)
unset PREPFAIL_v4 TAGS_v4 VALID_v4
store_detection v4 "ok ok"
assert_eq "$(iface_valid v4)|$(iface_tags v4)" "valid|" "1ac quiet trunk -> valid, no tags"
unset PREPFAIL_v0 PREPFAIL_v2 TAGS_v0 TAGS_v1 TAGS_v2 TAGS_v4 VALID_v0 VALID_v1 VALID_v2 VALID_v3 VALID_v4

# ---------------------------------------------------------------------------
# 1ad. ifaces_without_carrier - M4: additions computed from the pass-1 detection
#      sample get dropped for any addition-bearing iface that has no carrier RIGHT
#      NOW, regardless of ownership. The existing pruned_ifaces guard only covers
#      OWNED trunks on the carrier-down removal path, so a newly-detected but
#      not-yet-owned trunk that dies between detection and apply otherwise keeps
#      its stanzas on a dead parent. Single sample: dropping an addition is
#      fail-toward-no-change (retried next rescan), unlike a removal.
#      Re-stubs has_carrier (the §1s stub was restored at line 173).
# ---------------------------------------------------------------------------

_hc_saved_1ad=$(declare -f has_carrier)
has_carrier() { case " $STUB_UP " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

STUB_UP="enp1s0"
call ifaces_without_carrier "enp1s0.100 enp2s0.40"
ok "1ad down addition iface reported (enp2s0 dead)" "enp2s0"
call ifaces_without_carrier "enp1s0.100 enp1s0.21"
ok "1ad all additions on a live iface -> none down" ""
STUB_UP=""
call ifaces_without_carrier "enp1s0.100 enp2s0.40"
ok "1ad both ifaces dead -> both reported" "enp1s0 enp2s0"
STUB_UP="enp1s0 enp2s0"
call ifaces_without_carrier "enp1s0.100 enp2s0.40"
ok "1ad both live -> none" ""
call ifaces_without_carrier ""
ok "1ad no additions -> none down" ""

# End-to-end drop: fold the down set into pruned_ifaces, then drop_iface_tokens.
STUB_UP="enp1s0"
_m4_adds="enp1s0.100 enp2s0.40 enp2s0.41"
call drop_iface_tokens "$_m4_adds" "$(ifaces_without_carrier "$_m4_adds")"
ok "1ad additions on the dead trunk dropped, live trunk kept" "enp1s0.100"

eval "$_hc_saved_1ad"

# ---------------------------------------------------------------------------
# 1ae. pending-delete record + drain - M5: a post-ACCEPT `ip link delete` that
#      failed is remembered in /run and retried on the next reconcile, never
#      forgotten. Uses a temp file (not /run) and stubs backend_remove_vlan so
#      the drain's retry is exercised without touching the kernel.
# ---------------------------------------------------------------------------
_pd_saved=$PENDING_DELETE_FILE
PENDING_DELETE_FILE=$(mktemp)
rm -f "$PENDING_DELETE_FILE" # start from "no record" (absent file)

call pending_deletes
ok "1ae absent record -> empty" ""

call write_pending_deletes "enp2s0.40 enp1s0.100 enp2s0.40"
ok "1ae empty write succeeds silently" ""
call pending_deletes
ok "1ae round-trip is sorted-unique" "enp1s0.100 enp2s0.40"

record_pending_delete "enp1s0.18"
call pending_deletes
ok "1ae record appends and dedups" "enp1s0.100 enp1s0.18 enp2s0.40"

call write_pending_deletes ""
ok "1ae empty write succeeds" ""
call pending_deletes
ok "1ae emptied record -> empty" ""

# Drain: stub backend_remove_vlan to fail for a token marked "stuck", succeed
# otherwise; survivors (failures) stay recorded, successes are dropped.
_brv_saved=$(declare -f backend_remove_vlan)
backend_remove_vlan() { case "$1" in *stuck*) return 1 ;; *) return 0 ;; esac; }
write_pending_deletes "enp1s0.stuck enp1s0.100 enp2s0.40"
drain_pending_deletes
call pending_deletes
ok "1ae drain keeps only the still-failing token" "enp1s0.stuck"

backend_remove_vlan() { return 0; } # now everything deletes cleanly
drain_pending_deletes
call pending_deletes
ok "1ae a clean drain clears the record" ""
eval "$_brv_saved"

rm -f "$PENDING_DELETE_FILE"
PENDING_DELETE_FILE=$_pd_saved

# ---------------------------------------------------------------------------
# 1af. restart-failure must not consume the new-subnet event - M6: a TOTAL
#      monitoring-target restart failure previously still recorded the subnet as
#      seen, so it was never retried and the agent never learned it this uptime.
#      Total-failure only: a partial success consumes (one broken target must not
#      force a perpetual re-restart of the working ones). Stubs current_subnets +
#      snap/systemctl so the real restart_targets and seen-write logic run.
# ---------------------------------------------------------------------------
_seen_saved=$SEEN_FILE
_cs_saved=$(declare -f current_subnets)
SEEN_FILE=$(mktemp)
current_subnets() { emit_tokens "enp2s0:10.0.40.0/24"; }
snap() { case "$2" in *fail*) return 1 ;; *) return 0 ;; esac; } # $1=restart $2=name
systemctl() { return 0; }
RESTART_ON_NEW_SUBNET=true
RESTART_SERVICES=""

# Case 1: total failure (the only target fails) -> unseen, so next run retries.
rm -f "$SEEN_FILE"
unset RESTARTED_THIS_RUN RESTART_NONE_SUCCEEDED_THIS_RUN
RESTART_SNAPS="agent-fail"
maybe_restart_on_new_subnet
call read_seen
ok "1af total restart failure leaves the new subnet unseen" ""

# Case 2: restart succeeds -> new subnet consumed (recorded as seen).
rm -f "$SEEN_FILE"
unset RESTARTED_THIS_RUN RESTART_NONE_SUCCEEDED_THIS_RUN
RESTART_SNAPS="agent"
maybe_restart_on_new_subnet
call read_seen
ok "1af successful restart records the new subnet as seen" "enp2s0:10.0.40.0/24"

# Case 3: partial failure (one of two targets restarts) -> consumed. A single
# broken target must not force a perpetual re-restart of the working one.
rm -f "$SEEN_FILE"
unset RESTARTED_THIS_RUN RESTART_NONE_SUCCEEDED_THIS_RUN
RESTART_SNAPS="agent-ok agent-fail"
maybe_restart_on_new_subnet
call read_seen
ok "1af a partial success consumes the new subnet" "enp2s0:10.0.40.0/24"

# Case 4: total failure across two targets -> unseen (the multi-target total path).
rm -f "$SEEN_FILE"
unset RESTARTED_THIS_RUN RESTART_NONE_SUCCEEDED_THIS_RUN
RESTART_SNAPS="agent-fail other-fail"
maybe_restart_on_new_subnet
call read_seen
ok "1af total failure across all targets leaves the subnet unseen" ""

# Case 5: apply_change already restarted this run and it TOTALLY failed (dedup
# branch, RESTART_NONE_SUCCEEDED_THIS_RUN preset) -> still must not consume.
rm -f "$SEEN_FILE"
unset RESTARTED_THIS_RUN RESTART_NONE_SUCCEEDED_THIS_RUN
RESTARTED_THIS_RUN=1
RESTART_NONE_SUCCEEDED_THIS_RUN=1
maybe_restart_on_new_subnet
call read_seen
ok "1af failed apply-restart (dedup branch) leaves the subnet unseen" ""

unset -f snap systemctl
eval "$_cs_saved"
unset RESTARTED_THIS_RUN RESTART_NONE_SUCCEEDED_THIS_RUN RESTART_ON_NEW_SUBNET
RESTART_SNAPS=""; RESTART_SERVICES=""
rm -f "$SEEN_FILE"
SEEN_FILE=$_seen_saved

# ---------------------------------------------------------------------------
# 1ag. check_detect_deps - M8: the non-mutating detection dependency gate shared
#      by check_preconditions and --status. A missing detection tool must FAIL it,
#      so --status reports "unavailable" + non-zero instead of a false "detected:
#      [none]" exit 0. Stubs have_cmd / netplan_version / tcpdump_supports_inbound
#      so presence is controlled deterministically, independent of the host.
# ---------------------------------------------------------------------------
_hc_saved_1ag=$(declare -f have_cmd)
_nv_saved_1ag=$(declare -f netplan_version)
_ti_saved_1ag=$(declare -f tcpdump_supports_inbound)
_dm_saved_1ag=$DETECT_METHOD
HAVE="netplan tcpdump lldpctl"
have_cmd() { case " $HAVE " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
netplan_version() { printf '0.107'; }
tcpdump_supports_inbound() { return 0; }

DETECT_METHOD=both
HAVE="netplan tcpdump lldpctl"
call check_detect_deps; ok "1ag both: all present -> ok" ""
HAVE="netplan lldpctl" # tcpdump missing
call check_detect_deps; err "1ag both: tcpdump missing -> fail"
HAVE="netplan tcpdump" # lldpctl missing
call check_detect_deps; err "1ag both: lldpctl missing -> fail"
HAVE="netplan tcpdump lldpctl"
tcpdump_supports_inbound() { return 1; } # present but no -Q in
call check_detect_deps; err "1ag both: tcpdump lacks -Q in -> fail"
tcpdump_supports_inbound() { return 0; }
HAVE="tcpdump lldpctl" # netplan missing
call check_detect_deps; err "1ag netplan missing -> fail"
HAVE="netplan tcpdump lldpctl"
netplan_version() { printf '0.104'; } # below MIN_NETPLAN (0.106)
call check_detect_deps; err "1ag netplan too old -> fail"
netplan_version() { printf '0.107'; }

DETECT_METHOD=lldp # tcpdump not required for lldp-only
HAVE="netplan lldpctl"
call check_detect_deps; ok "1ag lldp: tcpdump not required -> ok" ""
DETECT_METHOD=sniff # lldpctl not required for sniff-only
HAVE="netplan tcpdump"
call check_detect_deps; ok "1ag sniff: lldpctl not required -> ok" ""

DETECT_METHOD=$_dm_saved_1ag
unset HAVE
eval "${_hc_saved_1ag:-unset -f have_cmd}"
eval "${_nv_saved_1ag:-unset -f netplan_version}"
eval "${_ti_saved_1ag:-unset -f tcpdump_supports_inbound}"

# ---------------------------------------------------------------------------
# 1ah. ids_in_ignore / ids_out_of_range - M8: per-trunk excluded/ignored detail
#      for --status (FR-35). Pure display helpers: which detected VLANs status
#      shows as excluded and why. emit_set output is numeric-sorted, deduped.
# ---------------------------------------------------------------------------
call ids_in_ignore "10 20 30 40" "20 40 99"
ok "1ah ignored = detected intersect ignore" "20 40"
call ids_in_ignore "10 20 30" ""
ok "1ah empty ignore -> none" ""
call ids_in_ignore "" "20 40"
ok "1ah empty detected -> none" ""
call ids_out_of_range "5 10 1500 2000" "1" "1000"
ok "1ah out-of-range = detected outside [min,max]" "1500 2000"
call ids_out_of_range "10 20 30" "1" "1000"
ok "1ah all in range -> none" ""
call ids_out_of_range "" "1" "1000"
ok "1ah empty detected out-of-range -> none" ""

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
# 1n. iface.id token helpers - the all-trunks canonical key (spec section 3)
#
# Every set in the pipeline holds iface.id tokens (e.g. "enp1s0.100"), not
# bare VLAN ids. These helpers convert between the two representations.
# Cross-parent aliasing returns if any pipeline set holds bare ids.
# ---------------------------------------------------------------------------

call tok_iface "enp1s0.100";       ok "1n tok_iface extracts parent"         "enp1s0"
call tok_iface "enp2s0.21";        ok "1n tok_iface different parent"         "enp2s0"
call tok_id "enp1s0.100";          ok "1n tok_id extracts vlan id"            "100"
call tok_id "enp2s0.21";           ok "1n tok_id different id"                "21"

call tag_tokens "enp1s0" "18 21 100"; ok "1n tag_tokens prefixes iface" "enp1s0.100 enp1s0.18 enp1s0.21"
call tag_tokens "enp2s0" "18";        ok "1n tag_tokens single id"     "enp2s0.18"
call tag_tokens "enp1s0" "";          ok "1n tag_tokens empty ids"     ""

# H6: an iface.id name over IFNAMSIZ (15) is dropped (kernel would reject it)
call tag_tokens "enx001122334455" "100";  ok "1n tag_tokens drops >15-char name (H6)"      ""
call tag_tokens "aaaaaaaaaaaaa" "1 100";   ok "1n tag_tokens keeps <=15, drops >15 (H6)"    "aaaaaaaaaaaaa.1"
call tag_tokens "enp0s31f6" "4094";        ok "1n tag_tokens keeps a 14-char name (H6)"     "enp0s31f6.4094"

# M1: iface_key is injective across . - _ (no aliasing of distinct trunks)
call iface_key "enp1s0";     ok "1n iface_key leaves alnum name unchanged"  "enp1s0"
call iface_key "wan-uplink"; ok "1n iface_key escapes dash"                 "wan_2duplink"
call iface_key "wan_uplink"; ok "1n iface_key escapes underscore"           "wan_5fuplink"
call tags_var "wan-uplink";  ok "1n tags_var dash key"                      "TAGS_wan_2duplink"
call tags_var "wan_uplink";  ok "1n tags_var underscore key (no alias)"     "TAGS_wan_5fuplink"

call untag_tokens "enp1s0.18 enp2s0.18 enp1s0.100"; ok "1n untag_tokens extracts bare ids (deduped)" "18 100"
call untag_tokens "";                                ok "1n untag_tokens empty -> empty"              ""

call tokens_for_iface "enp1s0.18 enp1s0.100 enp2s0.21" "enp1s0"; ok "1n tokens_for_iface filters" "enp1s0.100 enp1s0.18"
call tokens_for_iface "enp1s0.18 enp2s0.21" "enp3s0";            ok "1n tokens_for_iface no match" ""

call distinct_ifaces "enp1s0.18 enp2s0.21 enp1s0.100"; ok "1n distinct_ifaces" "enp1s0 enp2s0"
call distinct_ifaces "";                                ok "1n distinct_ifaces empty" ""

# emit_tokens sorts lexicographically (iface.id tokens), not numerically
call emit_tokens "enp2s0.18" "enp1s0.100" "enp1s0.18"; ok "1n emit_tokens lex-sorts and dedupes" "enp1s0.100 enp1s0.18 enp2s0.18"

# ---------------------------------------------------------------------------
# 1o. Multi-parent backend parsing - stanza header (spec section 5)
#
# backend_owned_vlans and backend_owned_metrics parse the stanza header line
# (    <iface>.<id>:) rather than correlating id:/link: by position. The
# header unambiguously carries both iface and id, and handles multi-parent
# (VLANs on different trunks) without a head-1 single-parent assumption.
# ---------------------------------------------------------------------------

# Multi-parent owned file fixture
read -r -d '' multi_parent_yaml <<'YAML' || true
# Managed by dynavlan 0.2.0 (build source)
network:
  version: 2
  vlans:
    enp1s0.18:
      id: 18
      link: enp1s0
      dhcp4: true
      accept-ra: false
      dhcp4-overrides:
        use-routes: false
        use-dns: false
        use-ntp: false
        use-domains: false
    enp1s0.100:
      id: 100
      link: enp1s0
      dhcp4: true
      accept-ra: false
      dhcp4-overrides:
        use-routes: false
        use-dns: false
        use-ntp: false
        use-domains: false
    enp2s0.21:
      id: 21
      link: enp2s0
      dhcp4: true
      accept-ra: false
      dhcp4-overrides:
        use-routes: false
        use-dns: false
        use-ntp: false
        use-domains: false
YAML

# Multi-parent routed file fixture
read -r -d '' multi_parent_routed_yaml <<'YAML' || true
# Managed by dynavlan 0.2.0 (build source)
network:
  version: 2
  vlans:
    enp1s0.18:
      id: 18
      link: enp1s0
      dhcp4: true
      accept-ra: false
      dhcp4-overrides:
        use-routes: true
        route-metric: 100
        use-dns: false
        use-ntp: false
        use-domains: false
    enp2s0.21:
      id: 21
      link: enp2s0
      dhcp4: true
      accept-ra: false
      dhcp4-overrides:
        use-routes: true
        route-metric: 101
        use-dns: false
        use-ntp: false
        use-domains: false
YAML

# Single-parent file (migration: existing v0.1.0 file must parse correctly)
read -r -d '' single_parent_yaml <<'YAML' || true
# Managed by dynavlan 0.1.0 (build e225a1c)
network:
  version: 2
  vlans:
    enp1s0.18:
      id: 18
      link: enp1s0
      dhcp4: true
      accept-ra: false
      dhcp4-overrides:
        use-routes: false
        use-dns: false
        use-ntp: false
        use-domains: false
    enp1s0.21:
      id: 21
      link: enp1s0
      dhcp4: true
      accept-ra: false
      dhcp4-overrides:
        use-routes: false
        use-dns: false
        use-ntp: false
        use-domains: false
YAML

# Tests need a temp file to simulate NETPLAN_FILE; save/restore the global.
_saved_npf="$NETPLAN_FILE"

_write_fixture() {
	NETPLAN_FILE=$(mktemp)
	printf '%s\n' "$1" >"$NETPLAN_FILE"
}

_cleanup_fixture() {
	rm -f "$NETPLAN_FILE"
	NETPLAN_FILE="$_saved_npf"
}

# backend_owned_vlans -> iface.id token set
_write_fixture "$multi_parent_yaml"
call backend_owned_vlans; ok "1o multi-parent owned vlans" "enp1s0.100 enp1s0.18 enp2s0.21"
_cleanup_fixture

_write_fixture "$single_parent_yaml"
call backend_owned_vlans; ok "1o single-parent (migration) owned vlans" "enp1s0.18 enp1s0.21"
_cleanup_fixture

# backend_owned_metrics -> iface.id:metric map
_write_fixture "$multi_parent_routed_yaml"
call backend_owned_metrics; ok "1o multi-parent routed metrics" "enp1s0.18:100 enp2s0.21:101"
_cleanup_fixture

# empty file -> empty
NETPLAN_FILE="/nonexistent/path/$$"
call backend_owned_vlans;   ok "1o no file -> empty owned" ""
call backend_owned_metrics; ok "1o no file -> empty metrics" ""
NETPLAN_FILE="$_saved_npf"

# backend_list_managed_vlans netplan-get awk parse: id: appears BEFORE link:
# in real netplan 0.107 output (verified on hardware 2026-07-30). The awk must
# handle either order; this fixture uses the real id-before-link order.
read -r -d '' _np_get_fixture <<'YAML' || true
enp1s0.1:
  dhcp4: true
  dhcp4-overrides:
    use-dns: false
  accept-ra: false
  id: 1
  link: "enp1s0"
enp1s0.100:
  dhcp4: true
  accept-ra: false
  id: 100
  link: "enp1s0"
enp2s0.18:
  dhcp4: true
  accept-ra: false
  id: 18
  link: "enp2s0"
YAML

_np_get_awk() {
    local iface="$1"
    printf '%s' "$_np_get_fixture" | awk -v iface="$iface" '
        /^[a-zA-Z0-9_.-]+\.[0-9]+:/ {
            if (vid != "" && lnk == iface) print vid
            vid = ""; lnk = ""
        }
        /^[[:space:]]+id:/ { vid = $2 }
        /^[[:space:]]+link:/ { gsub(/"/, "", $2); lnk = $2 }
        END { if (vid != "" && lnk == iface) print vid }
    ' | sort -n -u | tr '\n' ' ' | sed 's/ $//'
}
call _np_get_awk "enp1s0"; ok "1o netplan-get parse: id-before-link order (enp1s0)" "1 100"
call _np_get_awk "enp2s0"; ok "1o netplan-get parse: id-before-link order (enp2s0)" "18"
call _np_get_awk "eth99";  ok "1o netplan-get parse: no match -> empty" ""

# ---------------------------------------------------------------------------
# 1p. Multi-trunk pipeline integration (spec section 8 data flow)
#
# Exercises the pure helpers in the all-trunks configuration: overlapping
# VLAN ids on different trunks, per-interface managed-elsewhere, iface.id
# token round-trips, and multi-parent metric assignment.
# ---------------------------------------------------------------------------

# Overlapping ids: same VLAN id on two trunks -> two distinct tokens
call tag_tokens "enp1s0" "18 100"; _t1="$OUT"
call tag_tokens "enp2s0" "18 101"; _t2="$OUT"
call set_union "$_t1" "$_t2"; ok "1p overlapping ids produce distinct tokens" "enp1s0.100 enp1s0.18 enp2s0.101 enp2s0.18"

# compute_candidates per-iface, then tag, then union (the boot/rescan pattern)
call compute_candidates "18 21 100" 2 1000 "" "" "18"; _c1="$OUT"  # enp1s0: 18 owned, 21+100 new
call tag_tokens "enp1s0" "$_c1"; _a1="$OUT"
call compute_candidates "18 21 101" 2 1000 "" "" ""; _c2="$OUT"    # enp2s0: all new
call tag_tokens "enp2s0" "$_c2"; _a2="$OUT"
call set_union "$_a1" "$_a2"; ok "1p multi-trunk additions union" "enp1s0.100 enp1s0.21 enp2s0.101 enp2s0.18 enp2s0.21"

# boot_removals per-trunk, then tag (bare id removals are per-iface)
call boot_removals "18 21 100" "18 21" "18 21"; _r1="$OUT"  # 100 absent both passes on enp1s0
call tag_tokens "enp1s0" "$_r1"; ok "1p per-trunk removal tagged" "enp1s0.100"

# plan_route_metrics with iface.id tokens
call plan_route_metrics "" "enp1s0.18 enp1s0.100 enp2s0.21" "" 100
ok "1p multi-trunk metric assignment" "enp1s0.100:100 enp1s0.18:101 enp2s0.21:102"

# Kept metrics preserved across trunks
call plan_route_metrics "enp1s0.18:100 enp2s0.21:101" "enp1s0.18 enp1s0.100 enp2s0.21" "enp1s0.100" 100
ok "1p kept metrics preserved, new addition appended" "enp1s0.100:102 enp1s0.18:100 enp2s0.21:101"

# limit_fill with tokens: lowest NUMERIC id across trunks (M7), not lexical
call limit_fill "enp2s0.18 enp1s0.100 enp1s0.21" 2
ok "1p fill lowest-2 by numeric id (18,21 not lexical 100,21)" "enp2s0.18 enp1s0.21"

# count_ids counts tokens
call count_ids "enp1s0.18 enp1s0.100 enp2s0.21"; ok "1p count_ids on tokens" "3"

# ---------------------------------------------------------------------------
# 1q. ipv4_network - address+prefix -> network address (FR-40 subnet keying)
#     Keying subnet tokens on the network (not the host address) is what makes a
#     same-pool DHCP renewal produce an identical token, so it must NOT restart.
call ipv4_network 10.0.5.55 24;   ok "1q /24 zeroes the last octet"        "10.0.5.0"
call ipv4_network 10.0.5.200 25;  ok "1q /25 non-octet boundary (.128)"    "10.0.5.128"
call ipv4_network 10.0.5.55 26;   ok "1q /26 non-octet boundary (.0)"      "10.0.5.0"
call ipv4_network 172.16.9.4 12;  ok "1q /12 masks into the third octet"   "172.16.0.0"
call ipv4_network 10.11.12.13 8;  ok "1q /8 keeps only first octet"        "10.0.0.0"
call ipv4_network 10.0.5.55 32;   ok "1q /32 is the host itself"           "10.0.5.55"
call ipv4_network 192.168.1.1 0;  ok "1q /0 is all-zero network"           "0.0.0.0"

# ---------------------------------------------------------------------------
# 1t. Rescan combine math (FR-41) - rescan's first removal path.
#
# Through v3.6 rescan was add-only, so `owned` fed gate_vlan_count and set_union
# directly. It now feeds `set_minus owned all_removals`. These pin that
# composition: a removal must shrink the count the gate sees, and must not
# survive into the target.
# ---------------------------------------------------------------------------

_owned="enp1s0.18 enp1s0.21 enp2s0.30"

# Carrier teardown of enp2s0 while enp1s0 gains a VLAN.
call carrier_removals "30" down down; _rm_ids="$OUT"
call tag_tokens "enp2s0" "$_rm_ids"; _rm="$OUT"
ok "1t carrier removal tagged to its trunk" "enp2s0.30"

call tag_tokens "enp1s0" "100"; _add="$OUT"
call set_minus "$_owned" "$_rm"; _kept="$OUT"
ok "1t kept set excludes the carrier removal" "enp1s0.18 enp1s0.21"

call set_union "$_kept" "$_add"
ok "1t target = kept + additions, removal gone" "enp1s0.100 enp1s0.18 enp1s0.21"

# The gate counts the shrunken kept set, not the pre-removal owned set.
call count_ids "$_kept"; ok "1t gate sees the shrunken kept count" "2"

# Removals-only rescan: no additions, target is just the survivors.
call set_minus "$_owned" "$_rm"; _kept2="$OUT"
call set_union "$_kept2" ""
ok "1t removals-only target is the survivors" "enp1s0.18 enp1s0.21"

# Full teardown of every owned trunk collapses the target to empty.
call carrier_removals "18 21" down down; _rm_all1="$OUT"
call tag_tokens "enp1s0" "$_rm_all1"; _rt1="$OUT"
call set_union "$_rt1" "$_rm"; _rm_all="$OUT"
call set_minus "$_owned" "$_rm_all"
ok "1t full teardown leaves an empty target" ""

# ---------------------------------------------------------------------------
# 1w. drop_iface_tokens - strip additions on a trunk confirmed carrier-down.
#     Additions are computed from tags sniffed before the carrier verdict, so a
#     trunk that dies mid-sniff would otherwise gain new VLANs in the same apply
#     that tears its old ones down (they can never lease).
# ---------------------------------------------------------------------------

_adds="enp1s0.100 enp1s0.21 enp2s0.40"

call drop_iface_tokens "$_adds" "enp2s0"
ok "1w drops the dead trunk's additions" "enp1s0.100 enp1s0.21"
call drop_iface_tokens "$_adds" "enp1s0"
ok "1w drops the other trunk's additions" "enp2s0.40"
call drop_iface_tokens "$_adds" "enp1s0 enp2s0"
ok "1w every trunk dead -> no additions" ""
call drop_iface_tokens "$_adds" ""
ok "1w no dead trunks -> unchanged" "enp1s0.100 enp1s0.21 enp2s0.40"
call drop_iface_tokens "$_adds" "enp9s0"
ok "1w unrelated trunk -> unchanged" "enp1s0.100 enp1s0.21 enp2s0.40"
call drop_iface_tokens "" "enp1s0"
ok "1w empty additions -> empty" ""

# Prefix collision: enp1s0 must not match enp1s0b's tokens.
call drop_iface_tokens "enp1s0.18 enp1s0b.18" "enp1s0"
ok "1w iface match is exact, not a prefix" "enp1s0b.18"

# ---------------------------------------------------------------------------
# 1u. Mixed-trunk removal composition (FR-41 + FR-23).
#
# One trunk contributes a detection-diff removal (carrier UP, VLAN gone from
# both boot passes) while another contributes a carrier full-teardown, both
# into the same apply. The two producers are independent; this pins that their
# outputs combine without clobbering each other.
# ---------------------------------------------------------------------------

# enp1s0: carrier up, owns 18/21/100; 100 absent from both passes -> diff removal.
call boot_removals "18 21 100" "18 21" "18 21"; _d_ids="$OUT"
ok "1u detection-diff removal on the live trunk" "100"
call tag_tokens "enp1s0" "$_d_ids"; _d="$OUT"

# enp2s0: carrier down both samples, owns 30/31 -> full teardown.
call carrier_removals "30 31" down down; _c_ids="$OUT"
ok "1u carrier teardown on the dead trunk" "30 31"
call tag_tokens "enp2s0" "$_c_ids"; _c="$OUT"

call set_union "$_d" "$_c"; _mixed="$OUT"
ok "1u mixed removals combine, both trunks represented" "enp1s0.100 enp2s0.30 enp2s0.31"

# The live trunk keeps its still-detected VLANs; the dead trunk keeps nothing.
_owned_mixed="enp1s0.18 enp1s0.21 enp1s0.100 enp2s0.30 enp2s0.31"
call set_minus "$_owned_mixed" "$_mixed"
ok "1u mixed target keeps only the live trunk's survivors" "enp1s0.18 enp1s0.21"

# A live trunk may add while a dead one is torn down, in one apply.
call tag_tokens "enp1s0" "22"; _mixed_add="$OUT"
call set_minus "$_owned_mixed" "$_mixed"; _mixed_kept="$OUT"
call set_union "$_mixed_kept" "$_mixed_add"
ok "1u mixed apply adds on the live trunk while pruning the dead one" "enp1s0.18 enp1s0.21 enp1s0.22"

# Idempotence: re-running against the already-pruned set removes nothing more.
call set_minus "enp1s0.18 enp1s0.21" "$_mixed"
ok "1u re-applying the removal set is a no-op" "enp1s0.18 enp1s0.21"

# ---------------------------------------------------------------------------
# 1v. load_config validation of REMOVE_ON_CARRIER_LOSS (FR-41 config surface).
#
# The knob gates a destructive path, so a typo must refuse to run rather than
# silently defaulting. Uses a CONF_FILE fixture; the root-ownership guard is
# skipped when not running as root, so this works unprivileged.
# ---------------------------------------------------------------------------

_conf_saved="$CONF_FILE"
_conf_dir=$(mktemp -d)

_load_with() { # CONF_BODY -> echoes the effective value, rc from load_config
	printf '%s\n' "$1" >"$_conf_dir/dynavlan.conf"
	CONF_FILE="$_conf_dir/dynavlan.conf"
	load_config >/dev/null 2>&1 || return 1
	printf '%s' "$REMOVE_ON_CARRIER_LOSS"
}

call _load_with "REMOVE_ON_CARRIER_LOSS=true";  ok "1v explicit true accepted"  "true"
call _load_with "REMOVE_ON_CARRIER_LOSS=false"; ok "1v explicit false accepted" "false"
call _load_with "# nothing set";                ok "1v default is true"         "true"

refuses() { # DESC CONF_BODY  (asserts load_config exits non-zero)
	local rc
	_load_with "$2" >/dev/null 2>&1
	rc=$?
	tests=$((tests + 1))
	if [ "$rc" -ne 0 ]; then
		printf 'ok   - %s\n' "$1"
	else
		fails=$((fails + 1))
		printf 'FAIL - %s (expected rc 1, got 0)\n' "$1"
	fi
}

refuses "1v invalid value refuses to run" "REMOVE_ON_CARRIER_LOSS=yes"
refuses "1v empty value refuses to run"   "REMOVE_ON_CARRIER_LOSS="
refuses "1v numeric value refuses to run" "REMOVE_ON_CARRIER_LOSS=1"

# CARRIER_DEBOUNCE_SECONDS: a settle too short to tell a port bounce from a real
# loss is clamped for the FR-41 samples, but only while the destructive path is
# armed, and BOOT_SETTLE_SECONDS itself is never rewritten (the sniff comparison
# keeps the configured value).
_debounce_with() { # CONF_BODY -> "BOOT_SETTLE/CARRIER_DEBOUNCE"
	printf '%s\n' "$1" >"$_conf_dir/dynavlan.conf"
	CONF_FILE="$_conf_dir/dynavlan.conf"
	load_config >/dev/null 2>&1 || return 1
	printf '%s/%s' "$BOOT_SETTLE_SECONDS" "$CARRIER_DEBOUNCE_SECONDS"
}

call _debounce_with "BOOT_SETTLE_SECONDS=20"
ok "1v normal settle is used as-is" "20/20"
call _debounce_with "BOOT_SETTLE_SECONDS=0"
ok "1v zero settle clamped for carrier samples only" "0/5"
call _debounce_with "BOOT_SETTLE_SECONDS=4"
ok "1v sub-floor settle clamped" "4/5"
call _debounce_with "BOOT_SETTLE_SECONDS=5"
ok "1v settle at the floor is unchanged" "5/5"
call _debounce_with "$(printf 'BOOT_SETTLE_SECONDS=0\nREMOVE_ON_CARRIER_LOSS=false')"
ok "1v knob off leaves a zero settle alone" "0/0"

rm -rf "$_conf_dir"
CONF_FILE="$_conf_saved"
unset _conf_dir _conf_saved

# ---------------------------------------------------------------------------

printf '\n%s tests, %s failures\n' "$tests" "$fails"
[ "$fails" -eq 0 ]
