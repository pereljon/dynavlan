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
# P3: equal-metric multi-uplink must be order-independent - the snapshot iface still
# holds a min-metric default, so a route-listing order flip must not spuriously FAIL.
call health_check_eval "enp1s0" "enp1s0:10 enp2s0:10";  ok "1c P3 equal-metric, snap listed first -> PASS"  "PASS"
call health_check_eval "enp1s0" "enp2s0:10 enp1s0:10";  ok "1c P3 equal-metric, snap listed second -> PASS" "PASS"
call health_check_eval "enp2s0" "enp1s0:10 enp2s0:10";  ok "1c P3 equal-metric, other snap iface -> PASS"   "PASS"
call health_check_eval "enp1s0" "enp2s0:5 enp1s0:10";   ok "1c P3 snap iface no longer at min -> FAIL"       "FAIL"

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
# 1l-bis. Frozen CLI exit codes (COMPATIBILITY.md): requested --help/-V succeed
#   (0); a usage error - no mode or an unknown mode - is 2. Guards the exit-code
#   surface so a dispatch edit cannot silently flip these. --version/-V/--help
#   answer before load_config and the root check, so this runs unprivileged.
bash "$src" --help >/dev/null 2>&1; assert_eq "$?" "0" "1l-bis --help exits 0 (requested help is success)"
bash "$src" -h     >/dev/null 2>&1; assert_eq "$?" "0" "1l-bis -h exits 0"
bash "$src" -V     >/dev/null 2>&1; assert_eq "$?" "0" "1l-bis -V exits 0"
bash "$src"        >/dev/null 2>&1; assert_eq "$?" "2" "1l-bis no mode exits 2 (usage error)"
bash "$src" --bogus >/dev/null 2>&1; assert_eq "$?" "2" "1l-bis unknown mode exits 2"

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
# otherwise; survivors (failures) stay recorded, successes are dropped. Also
# stub snapshot_default_route/backend_netplan_vlan_tokens (D1/L7 re-checks
# drain_pending_deletes now runs on every call) so this M5-only test stays
# hermetic on a real box, instead of relying on this dev machine's absent
# ip/netplan binaries to make both calls harmlessly empty by accident.
_brv_saved=$(declare -f backend_remove_vlan)
_sdr_pd_saved=$(declare -f snapshot_default_route)
_bnvt_pd_saved=$(declare -f backend_netplan_vlan_tokens)
backend_remove_vlan() { case "$1" in *stuck*) return 1 ;; *) return 0 ;; esac; }
snapshot_default_route() { :; }
backend_netplan_vlan_tokens() { :; }
write_pending_deletes "enp1s0.stuck enp1s0.100 enp2s0.40"
drain_pending_deletes
call pending_deletes
ok "1ae drain keeps only the still-failing token" "enp1s0.stuck"

backend_remove_vlan() { return 0; } # now everything deletes cleanly
drain_pending_deletes
call pending_deletes
ok "1ae a clean drain clears the record" ""
eval "$_brv_saved"
eval "$_sdr_pd_saved"
eval "$_bnvt_pd_saved"
unset _sdr_pd_saved _bnvt_pd_saved

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
# 1ai. Netplan VLAN identity is link:+id:, never the mapping key (L1 adversarial
#      review finding). A stanza may be keyed ANY way ("vlan20", "en-vpn", ...);
#      backend_netplan_vlan_tokens, backend_list_managed_vlans and warn_overlap
#      must all derive iface.id from the stanza's own fields, not its key.
#      Stubs netplan/ip as plain shell functions (neither binary exists on this
#      dev machine; there is no real one to save via declare -f, so restore is
#      a plain unset -f) to feed canned `netplan get network.vlans` YAML and an
#      empty `ip -d link show type vlan` half of the union.
# ---------------------------------------------------------------------------

_ai_netplan_yaml=""
netplan() { # stub: only `netplan get network.vlans` is exercised here
	case "$1 $2" in
	"get network.vlans") printf '%s\n' "$_ai_netplan_yaml" ;;
	esac
}
ip() { :; } # stub: contributes nothing to the kernel-VLAN half of the union

_ai_tokens() { backend_netplan_vlan_tokens | tr '\n' ' ' | sed 's/ $//'; }

# Core bug: two arbitrarily-keyed stanzas on the SAME parent must not collapse
# into one (the old awk only flushed at an <iface>.<id>: header, so neither
# "vlan20:" nor "vlan30:" ever flushed and only the last id/link pair survived).
read -r -d '' _ai_arbitrary_keys_yaml <<'YAML' || true
vlan20:
  id: 20
  link: enp1s0
vlan30:
  id: 30
  link: enp1s0
YAML
_ai_netplan_yaml="$_ai_arbitrary_keys_yaml"
call _ai_tokens
ok "1ai arbitrary-keyed stanzas on the same parent both survive" "enp1s0.20 enp1s0.30"

# id: before link: (netplan 0.107) and link: before id: both parse.
read -r -d '' _ai_mixed_order_yaml <<'YAML' || true
enp1s0.5:
  id: 5
  link: enp1s0
enp2s0.6:
  link: enp2s0
  id: 6
YAML
_ai_netplan_yaml="$_ai_mixed_order_yaml"
call _ai_tokens
ok "1ai id-before-link and link-before-id both parse" "enp1s0.5 enp2s0.6"

# Multiple parent ifaces in one fixture: tokens attributed to their own parent.
read -r -d '' _ai_multi_parent_yaml <<'YAML' || true
vlan20:
  id: 20
  link: enp1s0
en-vpn:
  id: 99
  link: enp2s0
vlan30:
  id: 30
  link: enp1s0
YAML
_ai_netplan_yaml="$_ai_multi_parent_yaml"
call _ai_tokens
ok "1ai multiple parent ifaces attributed to their own parent" "enp1s0.20 enp2s0.99 enp1s0.30"

# Identity-only: a VLAN live only in this merged config (not one dynavlan owns)
# still appears - the function does not know or care about ownership. NETPLAN_FILE
# (dynavlan's own file) holds a completely different VLAN throughout.
_write_fixture "$multi_parent_yaml"
_ai_netplan_yaml='vlan99:
  id: 99
  link: enp3s0'
call _ai_tokens
ok "1ai VLAN not owned by dynavlan still appears (identity-only)" "enp3s0.99"
_cleanup_fixture

# Duplicate (link,id) under two different keys: BOTH occurrences retained, not
# deduped - warn_overlap below needs to count raw occurrences.
read -r -d '' _ai_duplicate_yaml <<'YAML' || true
vlan40:
  id: 40
  link: enp1s0
enp1s0.40:
  id: 40
  link: enp1s0
YAML
_ai_netplan_yaml="$_ai_duplicate_yaml"
call _ai_tokens
ok "1ai duplicate (link,id) under two keys is retained, not deduped" "enp1s0.40 enp1s0.40"
_ai_dupcount=$(backend_netplan_vlan_tokens | grep -cx "enp1s0.40")
tests=$((tests + 1))
if [ "$_ai_dupcount" = "2" ]; then
	printf 'ok   - %s\n' "1ai duplicate (link,id) occurrence count is exactly 2"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected 2, got %s\n' "1ai duplicate (link,id) occurrence count is exactly 2" "$_ai_dupcount"
fi

# backend_list_managed_vlans: an arbitrary-keyed external stanza sharing a
# parent with a dynavlan-owned enp1s0.18-shaped entry - the external VLAN is
# reported managed-elsewhere, the owned id is correctly subtracted.
read -r -d '' _ai_owned_yaml <<'YAML' || true
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
YAML
read -r -d '' _ai_merged_yaml <<'YAML' || true
enp1s0.18:
  id: 18
  link: enp1s0
vlan20:
  id: 20
  link: enp1s0
vlan30:
  id: 30
  link: enp1s0
YAML
_write_fixture "$_ai_owned_yaml"
_ai_netplan_yaml="$_ai_merged_yaml"
call backend_list_managed_vlans "enp1s0"
ok "1ai backend_list_managed_vlans: arbitrary-keyed external VLANs reported, owned id subtracted" "20 30"
_cleanup_fixture

# warn_overlap: an owned token whose (link,id) also appears under a different
# key elsewhere warns; one with no other definition does not. A single stanza
# contributing exactly one token (count 1) models the exact-same-key case too
# - netplan itself would have already merged an identical key before dynavlan
# ever sees this output, so it can't be constructed as two entries.
read -r -d '' _ai_overlap_yaml <<'YAML' || true
enp1s0.18:
  id: 18
  link: enp1s0
dup-vlan18:
  id: 18
  link: enp1s0
enp1s0.100:
  id: 100
  link: enp1s0
YAML
_ai_netplan_yaml="$_ai_overlap_yaml"
_ai_warn() { warn_overlap "$1" 2>&1; }

call _ai_warn "enp1s0.18"
ok "1ai warn_overlap warns: owned VLAN also defined under a different key" "dynavlan[warning]: dynavlan VLAN enp1s0.18 also defined in another netplan file (FR-11); keeping dynavlan's entry"

call _ai_warn "enp1s0.100"
ok "1ai warn_overlap silent: no other definition (count 1, incl. exact-same-key case)" ""

unset -f netplan ip _ai_tokens _ai_warn
unset _ai_netplan_yaml _ai_arbitrary_keys_yaml _ai_mixed_order_yaml _ai_multi_parent_yaml \
	_ai_duplicate_yaml _ai_dupcount _ai_owned_yaml _ai_merged_yaml _ai_overlap_yaml

# do_rescan calls warn_overlap before its "no changes" early return (mirroring
# do_boot, which already had this right). Codex review 2026-09-05 (finding 5,
# tightened by the correction re-review's finding 4) asked for direct coverage
# of this specific ordering AND that it prove warn_overlap actually receives
# the owned token set, not merely that a same-named stub fired: stub do_rescan's
# seam dependencies just enough to reach a steady no-change rescan
# deterministically (including `backend_list_managed_vlans`, whose real body
# now fails on this dev machine per the correction re-review's finding 2 fix,
# since there is no real `netplan`/`ip` binary here - stubbing it isolates this
# ordering test from that unrelated query-failure path), and capture the
# argument warn_overlap was actually called with.
_dr_saved_rd=$(declare -f run_detection)
_dr_saved_wo=$(declare -f warn_overlap)
_dr_saved_bov=$(declare -f backend_owned_vlans)
_dr_saved_it=$(declare -f iface_tags)
_dr_saved_drain=$(declare -f drain_pending_deletes)
_dr_saved_blmv=$(declare -f backend_list_managed_vlans)
_dr_saved_dt="$DETECTED_TRUNKS"
_dr_saved_rocl="$REMOVE_ON_CARRIER_LOSS"

drain_pending_deletes() { return 0; }
run_detection() {
	DETECTED_TRUNKS="enp1s0"
	return 0
}
backend_owned_vlans() { printf '%s' "enp1s0.18"; }
iface_tags() { printf '%s' "18"; } # detected == owned -> zero additions, steady state
backend_list_managed_vlans() { return 0; } # nothing managed elsewhere; query succeeds
REMOVE_ON_CARRIER_LOSS=false
_dr_warn_arg="(not called)"
warn_overlap() { _dr_warn_arg="$1"; }

do_rescan >/dev/null 2>&1
_dr_rc=$?
tests=$((tests + 1))
if [ "$_dr_rc" -eq 0 ] && [ "$_dr_warn_arg" = "enp1s0.18" ]; then
	printf 'ok   - %s\n' "1ai do_rescan: warn_overlap runs on a steady no-change rescan with the owned token set"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       warn_overlap arg=[%s] (expected enp1s0.18) rc=%s\n' "1ai do_rescan: warn_overlap runs on a steady no-change rescan with the owned token set" "$_dr_warn_arg" "$_dr_rc"
fi

eval "$_dr_saved_rd"
eval "$_dr_saved_wo"
eval "$_dr_saved_bov"
eval "$_dr_saved_it"
eval "$_dr_saved_drain"
eval "$_dr_saved_blmv"
DETECTED_TRUNKS="$_dr_saved_dt"
REMOVE_ON_CARRIER_LOSS="$_dr_saved_rocl"
unset _dr_saved_rd _dr_saved_wo _dr_saved_bov _dr_saved_it _dr_saved_drain _dr_saved_blmv \
	_dr_saved_dt _dr_saved_rocl _dr_warn_arg _dr_rc

# Codex review 2026-09-05 (correction re-review, finding 3): every existing
# query-failure case replaces backend_netplan_vlan_tokens itself, so regressing
# its `return "$rc"` line would leave the suite green. This stubs the `netplan`
# COMMAND instead (not the wrapper function) and exercises the REAL
# backend_netplan_vlan_tokens, the REAL backend_list_managed_vlans, and a real
# applying-mode caller (do_boot), proving a genuine netplan-command failure
# actually reaches the applying boundary and is not swallowed anywhere in
# between.
netplan() { return 1; }

call backend_netplan_vlan_tokens
tests=$((tests + 1))
if [ "$STATUS" -ne 0 ]; then
	printf 'ok   - %s\n' "1ai finding-3: real backend_netplan_vlan_tokens propagates a netplan-command failure"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected non-zero rc, got 0\n' "1ai finding-3: real backend_netplan_vlan_tokens propagates a netplan-command failure"
fi

call backend_list_managed_vlans "enp1s0"
tests=$((tests + 1))
if [ "$STATUS" -ne 0 ]; then
	printf 'ok   - %s\n' "1ai finding-3: real backend_list_managed_vlans propagates the same failure"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected non-zero rc, got 0\n' "1ai finding-3: real backend_list_managed_vlans propagates the same failure"
fi

_f3_saved_rd=$(declare -f run_detection)
_f3_saved_bov=$(declare -f backend_owned_vlans)
_f3_saved_it=$(declare -f iface_tags)
_f3_saved_drain=$(declare -f drain_pending_deletes)
_f3_saved_dt="$DETECTED_TRUNKS"
drain_pending_deletes() { return 0; }
run_detection() {
	DETECTED_TRUNKS="enp1s0"
	return 0
}
backend_owned_vlans() { :; }
iface_tags() { printf '%s' "18"; }

_f3_out=$(do_boot 2>&1)
_f3_rc=$?
tests=$((tests + 1))
if [ "$_f3_rc" -eq 1 ]; then
	case "$_f3_out" in
	*"could not determine externally-managed VLANs"*)
		printf 'ok   - %s\n' "1ai finding-3: the real chain reaches do_boot's applying boundary and aborts"
		;;
	*)
		fails=$((fails + 1))
		printf 'FAIL - %s\n       got [%s]\n' "1ai finding-3: the real chain reaches do_boot's applying boundary and aborts" "$_f3_out"
		;;
	esac
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected rc=1, got rc=%s\n' "1ai finding-3: the real chain reaches do_boot's applying boundary and aborts" "$_f3_rc"
fi

eval "$_f3_saved_rd"
eval "$_f3_saved_bov"
eval "$_f3_saved_it"
eval "$_f3_saved_drain"
DETECTED_TRUNKS="$_f3_saved_dt"
unset -f netplan
unset _f3_saved_rd _f3_saved_bov _f3_saved_it _f3_saved_drain _f3_saved_dt _f3_out _f3_rc

# ---------------------------------------------------------------------------
# 1aj. drain_pending_deletes re-checks CURRENT state, not just historical
#      ownership (D1 + L7 adversarial review findings). A pending token proves
#      only that a delete FAILED in some earlier run; by the time of a later
#      drain, the box's current default route or its current Netplan
#      configuration may have changed underneath it. Stubs snapshot_default_route
#      (declare -f save/restore, matching the 1s convention) and
#      backend_netplan_vlan_tokens (same convention - L1 made this a real
#      function) so both guards are deterministic; stubs backend_remove_vlan
#      like 1ae so every ordinary delete "succeeds" and only preserve-vs-drain
#      is under test.
# ---------------------------------------------------------------------------
_pd2_saved=$PENDING_DELETE_FILE
PENDING_DELETE_FILE=$(mktemp)
_sdr2_saved=$(declare -f snapshot_default_route)
_bnvt_saved=$(declare -f backend_netplan_vlan_tokens)
_brv2_saved=$(declare -f backend_remove_vlan)
backend_remove_vlan() { return 0; }

# D1: the pending token IS the box's current default-route interface.
snapshot_default_route() { printf '%s' "enp1s0.100"; }
backend_netplan_vlan_tokens() { :; }
write_pending_deletes "enp1s0.100 enp2s0.40"
_1aj_out=$(drain_pending_deletes 2>&1)
call pending_deletes
ok "1aj D1: current-default token is preserved, the other still drains" "enp1s0.100"
tests=$((tests + 1))
case "$_1aj_out" in
*"enp1s0.100 is now the box's CURRENT default-route interface"*)
	printf 'ok   - %s\n' "1aj D1 warning names the preserved token"
	;;
*)
	fails=$((fails + 1))
	printf 'FAIL - %s\n       got [%s]\n' "1aj D1 warning names the preserved token" "$_1aj_out"
	;;
esac

# L7: the pending token is now defined in current Netplan configuration (an
# operator or another file adopted the same link,id since the delete failed).
snapshot_default_route() { :; }
backend_netplan_vlan_tokens() { printf '%s\n' "enp1s0.100"; }
write_pending_deletes "enp1s0.100 enp2s0.40"
_1aj_out=$(drain_pending_deletes 2>&1)
call pending_deletes
ok "1aj L7: externally-adopted token is preserved, the other still drains" "enp1s0.100"
tests=$((tests + 1))
case "$_1aj_out" in
*"enp1s0.100 is now defined in the current Netplan configuration"*)
	printf 'ok   - %s\n' "1aj L7 warning names the preserved token"
	;;
*)
	fails=$((fails + 1))
	printf 'FAIL - %s\n       got [%s]\n' "1aj L7 warning names the preserved token" "$_1aj_out"
	;;
esac

# Ordinary case unchanged: no default-route match, nothing externally
# configured -> both pending tokens drain cleanly (one survivor never blocks
# another - the D1/L7 cases above already show this for their own guard; this
# confirms the ordinary path is not itself over-cautious).
snapshot_default_route() { :; }
backend_netplan_vlan_tokens() { :; }
write_pending_deletes "enp1s0.100 enp2s0.40"
drain_pending_deletes
call pending_deletes
ok "1aj ordinary drain with neither guard triggered clears the record" ""

# Codex review 2026-09-05 (finding 1): a FAILED current-Netplan ownership query
# must fail SAFE, not open - an empty "configured" set is indistinguishable
# from "nothing else owns any pending token", so a query failure must preserve
# the ENTIRE record untouched and return non-zero, never attempt a delete on
# unknown evidence.
_brv_qf_calls=0
backend_remove_vlan() {
	_brv_qf_calls=$((_brv_qf_calls + 1))
	return 0
}
snapshot_default_route() { :; }
backend_netplan_vlan_tokens() { return 1; }
write_pending_deletes "enp1s0.100 enp2s0.40"
drain_pending_deletes
_drain_qf_rc=$?
tests=$((tests + 1))
if [ "$_drain_qf_rc" -eq 1 ]; then
	printf 'ok   - %s\n' "1aj query failure: drain_pending_deletes returns non-zero"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected rc=1, got rc=%s\n' "1aj query failure: drain_pending_deletes returns non-zero" "$_drain_qf_rc"
fi
call pending_deletes
ok "1aj query failure: the entire pending record is preserved untouched" "enp1s0.100 enp2s0.40"
tests=$((tests + 1))
if [ "$_brv_qf_calls" -eq 0 ]; then
	printf 'ok   - %s\n' "1aj query failure: no delete is attempted (fail safe, not open)"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       backend_remove_vlan was called %s time(s), expected 0\n' "1aj query failure: no delete is attempted (fail safe, not open)" "$_brv_qf_calls"
fi

# Finding 1 also requires the SURVIVING-record write failure to be visible/
# non-zero (the approved HV-14 case), not just the query failure above.
backend_netplan_vlan_tokens() { :; } # query succeeds this time; nothing configured
backend_remove_vlan() { return 1; } # every token still fails -> non-empty survivors
write_pending_deletes "enp1s0.100 enp2s0.40" # seed with the REAL writer first
_wpd_saved=$(declare -f write_pending_deletes)
write_pending_deletes() { return 1; } # now fail only the drain's own internal write
_drain_wf_out=$(drain_pending_deletes 2>&1)
_drain_wf_rc=$?
eval "$_wpd_saved"
tests=$((tests + 1))
case "$_drain_wf_rc" in
1)
	case "$_drain_wf_out" in
	*"could not persist the surviving pending-delete record"*)
		printf 'ok   - %s\n' "1aj surviving-record write failure: drain_pending_deletes returns non-zero and logs it"
		;;
	*)
		fails=$((fails + 1))
		printf 'FAIL - %s\n       rc=1 but missing the expected log line: [%s]\n' "1aj surviving-record write failure: drain_pending_deletes returns non-zero and logs it" "$_drain_wf_out"
		;;
	esac
	;;
*)
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected rc=1, got rc=%s\n' "1aj surviving-record write failure: drain_pending_deletes returns non-zero and logs it" "$_drain_wf_rc"
	;;
esac

eval "$_sdr2_saved"
eval "$_bnvt_saved"
eval "$_brv2_saved"
rm -f "$PENDING_DELETE_FILE"
PENDING_DELETE_FILE=$_pd2_saved
unset _pd2_saved _sdr2_saved _bnvt_saved _brv2_saved _1aj_out \
	_brv_qf_calls _drain_qf_rc _wpd_saved _drain_wf_out _drain_wf_rc

# Finding 1 also requires do_boot/do_rescan to visibly HONOR a failed drain
# rather than continuing to detect/apply on top of unknown pending-delete
# state. Stub drain_pending_deletes itself (its own internals are covered
# above) and confirm each caller aborts, propagating non-zero, before ever
# reaching detection.
_dpd_saved=$(declare -f drain_pending_deletes)
_rd_saved_prop=$(declare -f run_detection)
drain_pending_deletes() { return 1; }
_rd_calls=0
run_detection() {
	_rd_calls=$((_rd_calls + 1))
	return 0
}

do_boot >/dev/null 2>&1
_boot_rc=$?
tests=$((tests + 1))
if [ "$_boot_rc" -eq 1 ] && [ "$_rd_calls" -eq 0 ]; then
	printf 'ok   - %s\n' "1aj do_boot: a failed drain aborts the run before detection"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       rc=%s run_detection calls=%s\n' "1aj do_boot: a failed drain aborts the run before detection" "$_boot_rc" "$_rd_calls"
fi

_rd_calls=0
do_rescan >/dev/null 2>&1
_rescan_rc=$?
tests=$((tests + 1))
if [ "$_rescan_rc" -eq 1 ] && [ "$_rd_calls" -eq 0 ]; then
	printf 'ok   - %s\n' "1aj do_rescan: a failed drain aborts the run before detection"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       rc=%s run_detection calls=%s\n' "1aj do_rescan: a failed drain aborts the run before detection" "$_rescan_rc" "$_rd_calls"
fi

eval "$_dpd_saved"
eval "$_rd_saved_prop"
unset _dpd_saved _rd_saved_prop _rd_calls _boot_rc _rescan_rc

# ---------------------------------------------------------------------------
# 1ak. Apply/recovery reporting must not overstate what is actually known
#      (L6 adversarial review finding), and a post-accept cleanup failure that
#      cannot even be recorded is a truthful operational failure, not a
#      silent success (D1's implementation-boundary point 5). Stubs the
#      backend_* seam functions apply_change already treats as its boundary
#      (declare -f save/restore, matching 1s/1ae's convention) so the real
#      apply_change / backend_apply_with_revert / restore_prior run, without a
#      real netplan/ip/systemd underneath them.
# ---------------------------------------------------------------------------

# backend_apply_with_revert: a pre-try failure (fifo setup) never even started
# a try - it must still return 1 like every other non-accept outcome (there is
# no longer a status global to distinguish sub-cases; see apply_change below).
mkfifo() { return 1; }
backend_apply_with_revert "" "" >/dev/null 2>&1
_bawr_rc=$?
tests=$((tests + 1))
if [ "$_bawr_rc" -eq 1 ]; then
	printf 'ok   - %s\n' "1ak backend_apply_with_revert: fifo setup failure returns 1"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected rc=1, got rc=%s\n' "1ak backend_apply_with_revert: fifo setup failure returns 1" "$_bawr_rc"
fi
unset -f mkfifo

# apply_change's FAIL branch must never claim a completed revert - a non-accept
# covers several distinct backend outcomes (fifo setup never started a try, the
# child died before accept, or it is still running past the wall-clock guard)
# and none of them is positive proof of a COMPLETED revert. Codex review
# 2026-09-05 found the prior three-way APPLY_STATUS split still let every dead
# child reach "reverted" regardless of why it died; the corrected disposition
# collapses to one conservative caller-side message and drops that global
# entirely rather than adding a fourth state.
_bc_saved=$(declare -f backup_current)
_bgc_saved=$(declare -f backend_generate_config)
_bv_saved=$(declare -f backend_validate)
_sdr3_saved=$(declare -f snapshot_default_route)
_bawr_saved=$(declare -f backend_apply_with_revert)
backup_current() { return 0; }
backend_generate_config() { return 0; }
backend_validate() { return 0; }
snapshot_default_route() { :; }
VLAN_ROUTES=false
_saved_npf3="$NETPLAN_FILE"
NETPLAN_FILE=$(mktemp -u)
backend_apply_with_revert() { return 1; }

_out=$(apply_change "enp1s0.999" "" "enp1s0.999" 2>&1)
_rc=$?
tests=$((tests + 1))
if [ "$_rc" -eq 1 ]; then
	case "$_out" in
	*"apply not accepted; live state may be uncertain; no deletes/restarts"*)
		printf 'ok   - %s\n' "1ak apply_change: non-accept never claims a completed revert"
		;;
	*)
		fails=$((fails + 1))
		printf 'FAIL - %s\n       got [%s]\n' "1ak apply_change: non-accept never claims a completed revert" "$_out"
		;;
	esac
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected rc=1, got rc=%s\n' "1ak apply_change: non-accept never claims a completed revert" "$_rc"
fi
tests=$((tests + 1))
case "$_out" in
*"reverted"*)
	fails=$((fails + 1))
	printf 'FAIL - %s\n       message still claims a completed revert: [%s]\n' "1ak apply_change: non-accept message never says reverted" "$_out"
	;;
*) printf 'ok   - %s\n' "1ak apply_change: non-accept message never says reverted" ;;
esac

# A post-accept delete failure that cannot even be recorded must surface as an
# operational failure, and the run's OWN summary must never contradict it by
# still claiming that token as removed (Codex review 2026-09-05, finding 3:
# the prior code logged the accurate error, then unconditionally logged
# "reconcile applied ... removed [token]" right after it).
# Codex review 2026-09-05 (correction re-review, finding 1, HIGH): these accepted-
# path cases reach the REAL prune_backups via the real apply_change, which prunes
# whatever BACKUP_DIR points at - the production default is /var/backups/dynavlan.
# A root run of this suite on the actual appliance would prune REAL audit backups
# beyond BACKUP_KEEP. Redirect to a throwaway temp dir for the whole accepted-path
# region below; restored in the cleanup block at the end of this section.
_brv3_saved=$(declare -f backend_remove_vlan)
_rpd_saved=$(declare -f record_pending_delete)
_wl2_saved=$(declare -f wait_leases)
_rt2_saved=$(declare -f restart_targets)
_bd_saved="$BACKUP_DIR"
BACKUP_DIR=$(mktemp -d)
backend_apply_with_revert() { return 0; }
backend_remove_vlan() { return 1; }
record_pending_delete() { return 1; }
wait_leases() { :; }
restart_targets() { :; }

_out=$(apply_change "" "" "enp1s0.999" 2>&1)
_rc=$?
tests=$((tests + 1))
if [ "$_rc" -eq 1 ]; then
	case "$_out" in
	*"failed to delete interface for enp1s0.999 AND failed to record it"*)
		printf 'ok   - %s\n' "1ak apply_change: an unrecordable post-accept delete failure is a truthful operational failure"
		;;
	*)
		fails=$((fails + 1))
		printf 'FAIL - %s\n       got [%s]\n' "1ak apply_change: an unrecordable post-accept delete failure is a truthful operational failure" "$_out"
		;;
	esac
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected rc=1, got rc=%s\n' "1ak apply_change: an unrecordable post-accept delete failure is a truthful operational failure" "$_rc"
fi

tests=$((tests + 1))
case "$_out" in
*"removed [enp1s0.999]"*)
	fails=$((fails + 1))
	printf 'FAIL - %s\n       failure output still claims the token was removed: [%s]\n' "1ak apply_change: accept-branch delete failure never claims that token was removed" "$_out"
	;;
*) printf 'ok   - %s\n' "1ak apply_change: accept-branch delete failure never claims that token was removed" ;;
esac

# Contrast: the ORDINARY M5 case (delete fails but the record succeeds) is
# unchanged - apply_change still returns 0 and still reports the removal,
# since a retry is safely queued and the token genuinely is gone from our file.
eval "$_rpd_saved"
_pd3_saved=$PENDING_DELETE_FILE
PENDING_DELETE_FILE=$(mktemp)
rm -f "$PENDING_DELETE_FILE"
apply_change "" "" "enp1s0.999" >/dev/null 2>&1
_rc=$?
tests=$((tests + 1))
if [ "$_rc" -eq 0 ]; then
	printf 'ok   - %s\n' "1ak apply_change: an ordinary M5 recorded-retry delete failure still returns 0"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected rc=0, got rc=%s\n' "1ak apply_change: an ordinary M5 recorded-retry delete failure still returns 0" "$_rc"
fi
rm -f "$PENDING_DELETE_FILE"
PENDING_DELETE_FILE=$_pd3_saved

rm -rf "$BACKUP_DIR"
BACKUP_DIR="$_bd_saved"
eval "$_bc_saved"
eval "$_bgc_saved"
eval "$_bv_saved"
eval "$_sdr3_saved"
eval "$_bawr_saved"
eval "$_brv3_saved"
eval "$_wl2_saved"
eval "$_rt2_saved"
NETPLAN_FILE="$_saved_npf3"
unset _bawr_rc _bc_saved _bgc_saved _bv_saved _sdr3_saved _bawr_saved \
	_saved_npf3 _out _rc _brv3_saved _rpd_saved _wl2_saved _rt2_saved _pd3_saved _bd_saved

# restore_prior: a failure to remove a first-install candidate (no prior file
# existed) must be logged, not silently swallowed - a read-only-directory
# failure is a real, reproducible (non-root) way to trigger it.
_rp_dir=$(mktemp -d)
_rp_file="$_rp_dir/90-dynavlan.yaml"
printf 'candidate\n' >"$_rp_file"
chmod 555 "$_rp_dir"
_saved_npf4="$NETPLAN_FILE"
NETPLAN_FILE="$_rp_file"
_rp_out=$(restore_prior 0 2>&1)
chmod 755 "$_rp_dir"
tests=$((tests + 1))
case "$_rp_out" in
*"could not remove the newly-generated $_rp_file candidate"*)
	printf 'ok   - %s\n' "1ak restore_prior logs a first-install candidate-removal failure"
	;;
*)
	fails=$((fails + 1))
	printf 'FAIL - %s\n       got [%s]\n' "1ak restore_prior logs a first-install candidate-removal failure" "$_rp_out"
	;;
esac
rm -rf "$_rp_dir"
NETPLAN_FILE="$_saved_npf4"
unset _rp_dir _rp_file _rp_out _saved_npf4

# ---------------------------------------------------------------------------
# 1al. Release workflow cross-job version handoff (D3).
#
#      `publish-apt` is a SEPARATE job from `build-deb`, so a `steps.*` context
#      from the other job evaluates to the empty string - the just-published
#      guard then tests for `dynavlan__all.deb`, always misses, and every
#      publish fails (observed live: the public index stayed at 0.4.2 while
#      v0.4.11 was released). Static assertions only: the workflow cannot be
#      executed here, so these pin the expression wiring, not a run result.
# ---------------------------------------------------------------------------

_wf="${here}/../.github/workflows/release.yml"
# The publish-apt job is the last job in the file; slice from its header to EOF
# so "does publish-apt reference X" is asked of that job alone.
_wf_publish=$(sed -n '/^  publish-apt:/,$p' "$_wf")
_wf_build=$(sed -n '/^  build-deb:/,/^  publish-apt:/p' "$_wf")

tests=$((tests + 1))
if printf '%s' "$_wf_publish" | grep -q 'steps\.version\.outputs\.version'; then
	fails=$((fails + 1))
	printf 'FAIL - %s\n       publish-apt still reads a steps.* context from another job\n' \
		"1al publish-apt does not read build-deb's steps context"
else
	printf 'ok   - %s\n' "1al publish-apt does not read build-deb's steps context"
fi

tests=$((tests + 1))
if printf '%s' "$_wf_publish" | grep -q 'needs\.build-deb\.outputs\.version'; then
	printf 'ok   - %s\n' "1al publish-apt takes the version from build-deb's job output"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       publish-apt does not consume needs.build-deb.outputs.version\n' \
		"1al publish-apt takes the version from build-deb's job output"
fi

tests=$((tests + 1))
if printf '%s' "$_wf_build" | grep -q '^    outputs:' &&
	printf '%s' "$_wf_build" | grep -qE '^      version: \$\{\{ steps\.version\.outputs\.version \}\}'; then
	printf 'ok   - %s\n' "1al build-deb publishes version as an explicit job output"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       build-deb declares no version job output\n' \
		"1al build-deb publishes version as an explicit job output"
fi

# The M2 hard failure must survive the rewiring: a publish whose own package is
# absent from the rebuilt repo must still fail loudly rather than ship an index
# missing the version it announces.
tests=$((tests + 1))
if printf '%s' "$_wf_publish" | grep -q 'test -f "debs/dynavlan_\${PKG_VERSION}_all.deb"' &&
	printf '%s' "$_wf_publish" | grep -q 'just-published dynavlan_\${PKG_VERSION}_all.deb missing from rebuild'; then
	printf 'ok   - %s\n' "1al just-published-package guard is retained"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       the just-published .deb hard-fail guard is missing or reworded\n' \
		"1al just-published-package guard is retained"
fi

unset _wf _wf_publish _wf_build

# ---------------------------------------------------------------------------
# 1am. build-deb.sh version-extraction diagnostics survive pipefail.
#
#      `SCRIPT_VER=$(grep '^ver=' file | head -1 | sed …)` under `set -euo
#      pipefail` aborts the script silently when grep fails, so the intended
#      "could not extract ver=" diagnostic never printed in either case it
#      exists for. The two paths must stay DISTINCT: an unreadable script
#      (transport/read failure) and a readable script with no ver= line
#      (empty parsed result).
# ---------------------------------------------------------------------------

_bd_dir=$(mktemp -d)
cp "${here}/../build-deb.sh" "$_bd_dir/build-deb.sh"

# (a) read failure: no dynavlan script next to build-deb.sh at all.
_bd_out=$(bash "$_bd_dir/build-deb.sh" 2>&1); _bd_rc=$?
tests=$((tests + 1))
if [ "$_bd_rc" -ne 0 ] && printf '%s' "$_bd_out" | grep -qi "could not read"; then
	printf 'ok   - %s\n' "1am build-deb reports an unreadable dynavlan script distinctly"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected non-zero + a distinct read-failure message, rc=%s out=[%s]\n' \
		"1am build-deb reports an unreadable dynavlan script distinctly" "$_bd_rc" "$_bd_out"
fi

# (b) empty parsed result: the script exists and is readable, but carries no ver=.
printf '#!/usr/bin/env bash\n# no version assignment here\n' >"$_bd_dir/dynavlan"
_bd_out=$(bash "$_bd_dir/build-deb.sh" 2>&1); _bd_rc=$?
tests=$((tests + 1))
if [ "$_bd_rc" -ne 0 ] && printf '%s' "$_bd_out" | grep -q "could not extract ver="; then
	printf 'ok   - %s\n' "1am build-deb reports an absent ver= line distinctly"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected non-zero + "could not extract ver=", rc=%s out=[%s]\n' \
		"1am build-deb reports an absent ver= line distinctly" "$_bd_rc" "$_bd_out"
fi

# The two messages must not collapse into one another.
tests=$((tests + 1))
if printf '%s' "$_bd_out" | grep -qi "could not read"; then
	fails=$((fails + 1))
	printf 'FAIL - %s\n       the empty-parse case emitted the read-failure message\n' \
		"1am the two diagnostics stay distinct"
else
	printf 'ok   - %s\n' "1am the two diagnostics stay distinct"
fi

rm -rf "$_bd_dir"
unset _bd_dir _bd_out _bd_rc

# ---------------------------------------------------------------------------
# 1an. get.sh APT bootstrap must never destroy prior repository state (L4).
#
#      The installer wrote the final keyring/source paths directly and `rm -f`'d
#      both on key, update, or install failure, without tracking whether they
#      pre-existed. On a box that already had a working dynavlan APT source, a
#      transient apt failure therefore left dynavlan installed but undiscoverable
#      by future `apt update`/`apt upgrade`. `install_via_apt` also runs as an
#      `if !` condition, which disables set -e inside it, so every staging write
#      needs its own check.
#
#      get.sh is run as a SUBPROCESS with a stubbed PATH rather than sourced:
#      the documented production invocation is `curl … | sudo bash`, so its
#      execution model is left exactly as it ships. The production script has
#      NO environment-variable override for the keyring/source/repo paths - a
#      script fetched and run via `curl | sudo bash` should not have the paths
#      it writes credential material to silently redirectable by whatever the
#      caller's environment happens to export. To exercise it against
#      throwaway paths, this test instead runs a byte-identical COPY with only
#      those three literal constant lines substituted; everything else in the
#      copy, including its logic and control flow, is untouched.
# ---------------------------------------------------------------------------

_gs_dir=$(mktemp -d)
_gs="$_gs_dir/get.sh"
_gs_stub="$_gs_dir/bin"
_gs_apt="$_gs_dir/apt"
_gs_tmp="$_gs_dir/tmp"
_gs_key="$_gs_apt/keyrings/dynavlan.gpg"
_gs_src="$_gs_apt/sources.list.d/dynavlan.sources"
mkdir -p "$_gs_stub"

# Byte-identical copy of the real script with only its three literal path
# constants substituted; everything else, including the surrounding comment,
# is untouched. Fails loudly (rather than silently testing nothing) if the
# production lines ever stop matching this exact literal form.
sed \
	-e "s#^APT_REPO_URL=\"https://pereljon.github.io/dynavlan\"\$#APT_REPO_URL=\"http://example.invalid/dynavlan\"#" \
	-e "s#^APT_KEYRING=\"/etc/apt/keyrings/dynavlan.gpg\"\$#APT_KEYRING=\"$_gs_key\"#" \
	-e "s#^APT_SOURCE=\"/etc/apt/sources.list.d/dynavlan.sources\"\$#APT_SOURCE=\"$_gs_src\"#" \
	"${here}/../get.sh" >"$_gs"
# Each substitution must actually have fired - not just "some line matched
# some pattern" - or this test would silently exercise the real production
# paths instead of the throwaway ones.
if ! grep -qF "APT_REPO_URL=\"http://example.invalid/dynavlan\"" "$_gs" ||
	! grep -qF "APT_KEYRING=\"$_gs_key\"" "$_gs" ||
	! grep -qF "APT_SOURCE=\"$_gs_src\"" "$_gs"; then
	echo "FATAL - 1an: get.sh's APT_* constant lines no longer match the expected literal form; the test copy is not exercising the real substitution" >&2
	exit 1
fi

cat >"$_gs_stub/id" <<'STUB'
#!/bin/sh
echo 0
STUB

cat >"$_gs_stub/curl" <<'STUB'
#!/bin/sh
# Two independent outcomes: the GitHub releases API and everything else (the
# APT signing key). Failures are requested with STUB_CURL_*_RC.
out=""
url=""
prev=""
for a in "$@"; do
	if [ "$prev" = "-o" ]; then
		out=$a
	fi
	case "$a" in
	http*) url=$a ;;
	esac
	prev=$a
done

case "$url" in
*api.github.com*)
	rc=${STUB_CURL_API_RC:-0}
	[ "$rc" -eq 0 ] || exit "$rc"
	printf '%s\n' "${STUB_CURL_API_BODY:-}"
	exit 0
	;;
esac

rc=${STUB_CURL_KEY_RC:-0}
[ "$rc" -eq 0 ] || exit "$rc"
if [ -n "$out" ]; then
	printf 'STUB-KEYRING\n' >"$out"
else
	printf 'STUB-KEYRING\n'
fi
exit 0
STUB

cat >"$_gs_stub/apt-get" <<'STUB'
#!/bin/sh
for a in "$@"; do
	case "$a" in
	update) exit "${STUB_APT_UPDATE_RC:-0}" ;;
	install) exit "${STUB_APT_INSTALL_RC:-0}" ;;
	esac
done
exit 0
STUB

cat >"$_gs_stub/dpkg" <<'STUB'
#!/bin/sh
# `dpkg -s dynavlan` decides whether an unmanaged tarball fallback is refused.
exit "${STUB_DPKG_RC:-1}"
STUB

cat >"$_gs_stub/cp" <<'STUB'
#!/bin/sh
# Delegates to the real cp for every call, and fails only the one whose FINAL
# argument (the destination) equals STUB_CP_FAIL_DEST. `command -p` uses the
# POSIX default PATH, so it reaches the real cp regardless of this stub
# directory being ahead of it on PATH. Backup copies land under the mktemp'd
# staging directory, never matching a live final path, so only a restore copy
# back onto the live path can ever be selected.
dest=""
for a in "$@"; do
	dest=$a
done
if [ -n "${STUB_CP_FAIL_DEST:-}" ] && [ "$dest" = "$STUB_CP_FAIL_DEST" ]; then
	echo "cp: stub failure for $dest" >&2
	exit 1
fi
command -p cp "$@"
STUB

chmod 755 "$_gs_stub/id" "$_gs_stub/curl" "$_gs_stub/apt-get" "$_gs_stub/dpkg" "$_gs_stub/cp"

export STUB_CURL_KEY_RC=0 STUB_CURL_API_RC=0 STUB_CURL_API_BODY=""
export STUB_APT_UPDATE_RC=0 STUB_APT_INSTALL_RC=0 STUB_DPKG_RC=1

_gs_reset() { # "prior" seeds an already-working repo config; anything else starts clean
	rm -rf "$_gs_apt" "$_gs_tmp"
	mkdir -p "$_gs_apt/keyrings" "$_gs_apt/sources.list.d" "$_gs_tmp"
	if [ "${1:-}" = "prior" ]; then
		printf 'PRIOR-KEYRING\n' >"$_gs_key"
		printf 'PRIOR-SOURCE\n' >"$_gs_src"
	fi
}

_gs_run() { # sets _gs_out / _gs_rc; TMPDIR is redirected so staging leaks are visible
	_gs_out=$(PATH="$_gs_stub:$PATH" TMPDIR="$_gs_tmp" bash "$_gs" 2>&1)
	_gs_rc=$?
	return 0
}

_gs_is() { # desc expected actual
	tests=$((tests + 1))
	if [ "$2" = "$3" ]; then
		printf 'ok   - %s\n' "$1"
	else
		fails=$((fails + 1))
		printf 'FAIL - %s\n       expected [%s], got [%s]\n' "$1" "$2" "$3"
	fi
}

_gs_no_leftovers() { # desc
	local leftovers
	leftovers=$(
		find "$_gs_apt" -name '*dynavlan-new*' 2>/dev/null
		find "$_gs_tmp" -mindepth 1 2>/dev/null
	)
	_gs_is "$1" "" "$leftovers"
}

# (a) key download fails with a working repo config already in place.
_gs_reset prior
STUB_CURL_KEY_RC=22 STUB_DPKG_RC=0
_gs_run
_gs_is "1an key-download failure leaves a pre-existing keyring byte-identical" \
	"PRIOR-KEYRING" "$(cat "$_gs_key" 2>/dev/null)"
_gs_is "1an key-download failure leaves a pre-existing source byte-identical" \
	"PRIOR-SOURCE" "$(cat "$_gs_src" 2>/dev/null)"
_gs_no_leftovers "1an key-download failure leaves no staging files behind"

# (b) apt-get update fails with a working repo config already in place.
_gs_reset prior
STUB_CURL_KEY_RC=0 STUB_APT_UPDATE_RC=100 STUB_DPKG_RC=0
_gs_run
_gs_is "1an apt-get update failure restores the pre-existing keyring" \
	"PRIOR-KEYRING" "$(cat "$_gs_key" 2>/dev/null)"
_gs_is "1an apt-get update failure restores the pre-existing source" \
	"PRIOR-SOURCE" "$(cat "$_gs_src" 2>/dev/null)"
_gs_no_leftovers "1an apt-get update failure leaves no staging files behind"

# (c) apt-get install fails with a working repo config already in place.
_gs_reset prior
STUB_APT_UPDATE_RC=0 STUB_APT_INSTALL_RC=100 STUB_DPKG_RC=0
_gs_run
_gs_is "1an apt-get install failure restores the pre-existing keyring" \
	"PRIOR-KEYRING" "$(cat "$_gs_key" 2>/dev/null)"
_gs_is "1an apt-get install failure restores the pre-existing source" \
	"PRIOR-SOURCE" "$(cat "$_gs_src" 2>/dev/null)"
_gs_no_leftovers "1an apt-get install failure leaves no staging files behind"

# The approved fallback contract: an existing dpkg-managed install refuses the
# unmanaged tarball fallback rather than desyncing dpkg's records.
tests=$((tests + 1))
case "$_gs_out" in
*"already installed via apt/dpkg"*)
	printf 'ok   - %s\n' "1an an existing dpkg install still refuses the tarball fallback"
	;;
*)
	fails=$((fails + 1))
	printf 'FAIL - %s\n       got [%s]\n' \
		"1an an existing dpkg install still refuses the tarball fallback" "$_gs_out"
	;;
esac

# (d) the source-file write itself fails. `chmod` cannot induce this
#     root-independently - root bypasses directory write permission entirely,
#     so a permission-only fault would silently pass this test when run as
#     root and prove nothing. Instead pre-place a dangling symlink at the
#     EXACT staging path the write targets, pointing through a directory that
#     does not exist: `open()` then fails with ENOENT regardless of caller
#     privilege, since it is a path-resolution failure, not a permission
#     check. Touches nothing else in the tree - the pre-existing source file
#     itself is untouched and still backed up normally.
_gs_reset prior
STUB_APT_INSTALL_RC=0 STUB_DPKG_RC=0
ln -s "/dynavlan-test-nonexistent-dir-$$/target" "$_gs_src.dynavlan-new"
_gs_run
_gs_is "1an source-write failure leaves a pre-existing keyring byte-identical" \
	"PRIOR-KEYRING" "$(cat "$_gs_key" 2>/dev/null)"
_gs_is "1an source-write failure leaves a pre-existing source byte-identical" \
	"PRIOR-SOURCE" "$(cat "$_gs_src" 2>/dev/null)"
_gs_no_leftovers "1an source-write failure leaves no staging files behind"

# (e) a first install that fails must not leave partial state behind. dpkg
# reports nothing installed, so the documented tarball fallback is attempted -
# it dies on the stubbed API, which is what keeps this case out of the network.
_gs_reset
STUB_CURL_KEY_RC=0 STUB_APT_UPDATE_RC=100 STUB_DPKG_RC=1 STUB_CURL_API_RC=7
_gs_run
_gs_is "1an a failed first install leaves no keyring behind" "" "$(cat "$_gs_key" 2>/dev/null)"
_gs_is "1an a failed first install leaves no source behind" "" "$(cat "$_gs_src" 2>/dev/null)"
tests=$((tests + 1))
if [ ! -e "$_gs_key" ] && [ ! -e "$_gs_src" ]; then
	printf 'ok   - %s\n' "1an a failed first install removes the files it created"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       key exists=%s source exists=%s\n' \
		"1an a failed first install removes the files it created" \
		"$([ -e "$_gs_key" ] && echo yes || echo no)" \
		"$([ -e "$_gs_src" ] && echo yes || echo no)"
fi
_gs_no_leftovers "1an a failed first install leaves no staging files behind"

# (f) tag-lookup diagnostics: a transport failure and a successful fetch that
# parses to nothing must be DIFFERENT specific messages, and neither may abort
# silently (the single `curl | grep | head | sed` pipeline under pipefail did).
tests=$((tests + 1))
if [ "$_gs_rc" -ne 0 ] && printf '%s' "$_gs_out" | grep -q "could not reach the GitHub releases API"; then
	printf 'ok   - %s\n' "1an a tag-lookup transport failure reports itself distinctly"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected non-zero + a transport-failure message, rc=%s out=[%s]\n' \
		"1an a tag-lookup transport failure reports itself distinctly" "$_gs_rc" "$_gs_out"
fi

tests=$((tests + 1))
case "$_gs_out" in
*"returned no tag_name"*)
	fails=$((fails + 1))
	printf 'FAIL - %s\n       the transport failure emitted the empty-parse message\n' \
		"1an the two tag-lookup diagnostics stay distinct"
	;;
*) printf 'ok   - %s\n' "1an the two tag-lookup diagnostics stay distinct" ;;
esac

_gs_reset
STUB_CURL_API_RC=0 STUB_CURL_API_BODY='{"name":"no tag here"}'
_gs_run
tests=$((tests + 1))
if [ "$_gs_rc" -ne 0 ] && printf '%s' "$_gs_out" | grep -q "returned no tag_name"; then
	printf 'ok   - %s\n' "1an an unparseable release payload reports itself distinctly"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       expected non-zero + the no-tag_name message, rc=%s out=[%s]\n' \
		"1an an unparseable release payload reports itself distinctly" "$_gs_rc" "$_gs_out"
fi

# (g) happy path: both files written, success reported, nothing staged left over.
_gs_reset
STUB_CURL_KEY_RC=0 STUB_APT_UPDATE_RC=0 STUB_APT_INSTALL_RC=0 STUB_DPKG_RC=1
_gs_run
_gs_is "1an happy path exits 0" "0" "$_gs_rc"
_gs_is "1an happy path installs the fetched keyring" "STUB-KEYRING" "$(cat "$_gs_key" 2>/dev/null)"
_gs_is "1an happy path writes the source file" \
	"Types: deb
URIs: http://example.invalid/dynavlan
Suites: stable
Components: main
Signed-By: $_gs_key" "$(cat "$_gs_src" 2>/dev/null)"
tests=$((tests + 1))
case "$_gs_out" in
*"installed via apt"*) printf 'ok   - %s\n' "1an happy path reports the apt install" ;;
*)
	fails=$((fails + 1))
	printf 'FAIL - %s\n       got [%s]\n' "1an happy path reports the apt install" "$_gs_out"
	;;
esac
_gs_no_leftovers "1an happy path leaves no staging files behind"

# (h) the documented production invocation is `curl … | sudo bash`, i.e. the
# script arrives on stdin with no file behind it. Prove that form still runs
# the top-level logic identically.
_gs_reset
_gs_out=$(PATH="$_gs_stub:$PATH" TMPDIR="$_gs_tmp" bash -s <"$_gs" 2>&1)
_gs_rc=$?
_gs_is "1an piped-stdin invocation exits 0" "0" "$_gs_rc"
_gs_is "1an piped-stdin invocation installs the keyring" "STUB-KEYRING" "$(cat "$_gs_key" 2>/dev/null)"

# (i) a cleanup command itself can fail (e.g. a leftover staging file cannot
#     be removed). This must never invent its own transaction/result model -
#     the function still reports exactly the real bootstrap/restore outcome,
#     with cleanup failure only ever a visible warning, never a silent drop
#     and never a change to the return code. Root-independent by the same
#     reasoning as (d): `rm` (without -r) refuses ANY directory regardless of
#     caller privilege, so pre-placing a directory at the exact staging path
#     forces `rm -f` to fail structurally, not on a permission check.
_gs_reset prior
mkdir "$_gs_src.dynavlan-new"
_gs_run
_gs_is "1an a cleanup failure does not change the reported return code" "1" "$_gs_rc"
tests=$((tests + 1))
if printf '%s' "$_gs_out" | grep -q "WARNING: could not remove leftover staging file"; then
	printf 'ok   - %s\n' "1an a cleanup failure is reported, not silently dropped"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       got [%s]\n' "1an a cleanup failure is reported, not silently dropped" "$_gs_out"
fi
_gs_is "1an a cleanup failure leaves a pre-existing keyring byte-identical" \
	"PRIOR-KEYRING" "$(cat "$_gs_key" 2>/dev/null)"
_gs_is "1an a cleanup failure leaves a pre-existing source byte-identical" \
	"PRIOR-SOURCE" "$(cat "$_gs_src" 2>/dev/null)"
# The un-removable directory is the EXPECTED leftover here, not a defect -
# confirm it is still exactly what was pre-placed, not silently miscounted.
_gs_is "1an the un-removable staging directory is still present, as expected" \
	"d" "$([ -d "$_gs_src.dynavlan-new" ] && echo d || echo missing)"
rmdir "$_gs_src.dynavlan-new"

# (j) apt_bootstrap fails only after a pre-existing file has already been
#     backed up AND replaced, and restoring that one file back then itself
#     fails. (a)-(c) never exercise apt_restore_prior's own failure branch:
#     they always leave the underlying restore cp free to succeed, so none of
#     them proves what happens when it doesn't.
#
#     Root-independent: the cp stub above fails only the ONE call whose final
#     destination is the live keyring path (STUB_CP_FAIL_DEST) - the backup
#     copy (into the staging directory) and the source's own restore are
#     untouched, so only the keyring's restore-back is made to fail, and it
#     fails on every caller identically, not on a permission check. The
#     assertions below check exactly the file whose restore was made to fail
#     (keyring.prior), not a different one, so the injection and the evidence
#     line up directly: this is the retained copy an operator would actually
#     need for the warning's "restore them manually".
_gs_reset prior
STUB_CURL_KEY_RC=0 STUB_APT_UPDATE_RC=100 STUB_DPKG_RC=0
STUB_CP_FAIL_DEST=$_gs_key
export STUB_CP_FAIL_DEST
_gs_run
unset STUB_CP_FAIL_DEST
_gs_is "1an a restore failure after a successful backup is reported non-zero" "1" "$_gs_rc"
# The stage path is recovered from the warning text rather than by searching
# $_gs_tmp: bare `mktemp -d` is not guaranteed to honor TMPDIR. Native macOS
# /usr/bin/mktemp uses the Darwin per-user temp dir regardless (observed
# directly; man mktemp: bare -d acts as `-t tmp`), while some sandboxed
# environments honor TMPDIR. Parsing the warning works under both, and it
# also proves the warning names a usable retained location.
_gs_stage=$(printf '%s\n' "$_gs_out" | sed -n 's/.*saved copies are kept in \([^ ]*\) (keyring\.prior.*/\1/p')
_gs_is "1an the restore-failure warning names a concrete retained stage path" \
	"d" "$([ -n "$_gs_stage" ] && [ -d "$_gs_stage" ] && echo d || echo missing)"
_gs_is "1an the retained keyring.prior still has its original bytes" \
	"PRIOR-KEYRING" "$(cat "$_gs_stage/keyring.prior" 2>/dev/null)"
rm -rf "$_gs_stage"

unset -f _gs_reset _gs_run _gs_is _gs_no_leftovers
unset STUB_CURL_KEY_RC STUB_CURL_API_RC STUB_CURL_API_BODY
unset STUB_APT_UPDATE_RC STUB_APT_INSTALL_RC STUB_DPKG_RC STUB_CP_FAIL_DEST
rm -rf "$_gs_dir"
unset _gs _gs_dir _gs_stub _gs_apt _gs_tmp _gs_key _gs_src _gs_out _gs_rc

# ---------------------------------------------------------------------------
# 1ao. D2 (Group 2a): a service stop before ACCEPT must revert, never confirm.
#
#      `systemctl stop` / a start timeout sends SIGTERM; under KillMode=mixed it
#      reaches only the main Bash process. The TERM trap sets
#      STOP_REQUESTED and closes the (unaccepted) FIFO writer so netplan try sees
#      EOF and reverts (the P2-validated path). Bash must stay alive until the
#      child has exited, restore_prior must run, and no delete/lease-wait/restart
#      may follow an unaccepted change. Design:
#      docs/superpowers/plans/2026-10-01-group2a-d2-graceful-stop-design.md
#
#      Each scenario runs in a subshell so its function overrides and traps never
#      leak. TERM is delivered with `kill -TERM $!` (the captured child PID); `$$`
#      inside a subshell still names the parent. Deterministic mid-function
#      delivery uses a `stop_requested` shadow that raises TERM at a chosen check:
#      the trap then runs right after that check returns, i.e. in the exact window
#      under test.
# ---------------------------------------------------------------------------

_d2_dir=$(mktemp -d)
_d2_ev="$_d2_dir/events"
_d2_log="$_d2_dir/log"
_d2_res="$_d2_dir/result"

_d2_netplan() { # stub `netplan try`; stdin is the FIFO
	[ "$1" = try ] || return 0
	echo np_start >>"$_d2_ev"
	if IFS= read -r _; then
		echo np_accept >>"$_d2_ev"
		sleep "${D2_ACCEPT_LINGER:-0}"
		echo np_exit >>"$_d2_ev"
		return 0
	fi
	echo np_eof >>"$_d2_ev"
	if [ "${D2_NP_MODE:-revert}" = stubborn ]; then
		sleep 9 # ignores EOF and outlives the cleanup deadline
	else
		sleep "${D2_REVERT_DELAY:-1}"
	fi
	echo np_exit >>"$_d2_ev"
	return 1
}

_d2_env() { # call at the top of every scenario subshell
	POLL_INTERVAL=1
	TRY_TIMEOUT=4
	STOP_CHILD_MARGIN=1
	APPLY_NOEVIDENCE_SETTLE=0
	APPLY_FALLBACK_SETTLE=0
	HEALTH_CONSEC=1
	: >"$_d2_ev"
	: >"$_d2_log"
	: >"$_d2_res"
	rm -f "$_d2_dir"/fifo.* "$_d2_dir/health_pass" "$_d2_dir/fired"
	netplan() { _d2_netplan "$@"; }
	mktemp() { printf '%s\n' "$_d2_dir/fifo.$RANDOM"; }
	log() { printf '[%s] %s\n' "$1" "${*:2}" >>"$_d2_log"; }
	post_apply_health() {
		if [ "${D2_HEALTH:-FAIL}" = PASS ]; then
			: >"$_d2_dir/health_pass"
		fi
		echo "${D2_HEALTH:-FAIL}"
	}
	sh -c 'echo $PPID' >"$_d2_dir/self"
	D2_SELF=$(cat "$_d2_dir/self")
}

# Raises TERM at a chosen stop_requested() call (D2_FIRE_AT_CALL) or at the first
# call after a health PASS (D2_FIRE_AFTER_HEALTH): both land the signal in a
# precise window; the trap runs when the call returns.
_d2_shadow_stop() {
	d2_calls=0
	stop_requested() {
		local r=1
		d2_calls=$((d2_calls + 1))
		[ "${STOP_REQUESTED:-0}" = 1 ] && r=0
		# Result is computed BEFORE the signal: Bash runs a trap after the `kill`
		# command, so the check below has already answered when the trap fires.
		if [ ! -e "$_d2_dir/fired" ]; then
			if { [ -n "${D2_FIRE_AT_CALL:-}" ] && [ "$d2_calls" -eq "$D2_FIRE_AT_CALL" ]; } ||
				{ [ -n "${D2_FIRE_AFTER_HEALTH:-}" ] && [ -e "$_d2_dir/health_pass" ]; }; then
				: >"$_d2_dir/fired"
				builtin kill -TERM "$D2_SELF"
			fi
		fi
		return "$r"
	}
}

_d2_wait_start() { # bounded wait for the stub netplan to have started (a fixed sleep can pass vacuously)
	local i=0
	while [ "$i" -lt 20 ] && ! grep -q '^np_start$' "$_d2_ev"; do
		sleep 1
		i=$((i + 1))
	done
}
_d2_has() { grep -q -- "$1" "${2:-$_d2_ev}"; }
_d2_absent() { ! grep -q -- "$1" "${2:-$_d2_ev}"; }
_d2_assert() { # desc cmd...
	local desc="$1"
	shift
	tests=$((tests + 1))
	if "$@"; then
		printf 'ok   - %s\n' "$desc"
	else
		fails=$((fails + 1))
		printf 'FAIL - %s\n       events: %s\n       result: %s\n       log: %s\n' "$desc" \
			"$(tr '\n' ' ' <"$_d2_ev" 2>/dev/null)" "$(tr '\n' ' ' <"$_d2_res" 2>/dev/null)" \
			"$(tr '\n' ' ' <"$_d2_log" 2>/dev/null)"
	fi
}
_d2_rc_nonzero() { ! grep -q '^rc=0$' "$_d2_res" && grep -q '^rc=' "$_d2_res"; }
_d2_rc_zero() { grep -q '^rc=0$' "$_d2_res"; }
_d2_order() { # EVENT_A before EVENT_B in the events file
	local a b
	a=$(grep -n -- "^$1\$" "$_d2_ev" | head -1 | cut -d: -f1)
	b=$(grep -n -- "^$2\$" "$_d2_ev" | head -1 | cut -d: -f1)
	[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

# (1) STOP already set: nothing is launched and no FIFO is left behind.
(
	_d2_env
	STOP_REQUESTED=1
	backend_apply_with_revert "" ""
	echo "rc=$?" >"$_d2_res"
)
_d2_assert "1ao STOP before launch: returns non-zero" _d2_rc_nonzero
_d2_assert "1ao STOP before launch: netplan try is never started" _d2_absent np_start
_d2_assert "1ao STOP before launch: no FIFO left behind" test -z "$(ls "$_d2_dir"/fifo.* 2>/dev/null)"

# (2) TERM mid-loop, never healthy: writer revoked -> EOF -> revert; Bash waits.
(
	_d2_env
	D2_REVERT_DELAY=2
	(
		stop_trap_on
		backend_apply_with_revert "" ""
		echo "rc=$?" >"$_d2_res"
		echo returned >>"$_d2_ev"
	) &
	pid=$!
	sleep 2
	kill -TERM "$pid"
	wait "$pid"
)
_d2_assert "1ao TERM before ACCEPT: returns non-zero" _d2_rc_nonzero
_d2_assert "1ao TERM before ACCEPT: netplan try saw EOF (revert path)" _d2_has np_eof
_d2_assert "1ao TERM before ACCEPT: no confirmation was ever written" _d2_absent np_accept
_d2_assert "1ao TERM before ACCEPT: Bash returned only after the child exited" _d2_order np_exit returned

# (2b) a second TERM during the wait must not abandon the child.
(
	_d2_env
	D2_REVERT_DELAY=3
	(
		stop_trap_on
		backend_apply_with_revert "" ""
		echo "rc=$?" >"$_d2_res"
		echo returned >>"$_d2_ev"
	) &
	pid=$!
	sleep 2
	kill -TERM "$pid"
	sleep 1
	kill -TERM "$pid"
	wait "$pid"
)
_d2_assert "1ao a repeated TERM does not end the child wait early" _d2_order np_exit returned

# (3) ACCEPT race: TERM lands between the final STOP check and the confirming
# write. The trap revokes the writer, so no confirmation can exist.
(
	_d2_env
	D2_HEALTH=PASS D2_FIRE_AFTER_HEALTH=1
	_d2_shadow_stop
	stop_trap_on
	backend_apply_with_revert "" ""
	echo "rc=$?" >"$_d2_res"
)
_d2_assert "1ao ACCEPT race: no confirmation after TERM at the accept instant" _d2_absent np_accept
_d2_assert "1ao ACCEPT race: not reported as accepted" _d2_rc_nonzero
_d2_assert "1ao ACCEPT race: netplan try saw EOF" _d2_has np_eof

# (3b) TERM after the confirmation was written: the accept stands, and Bash still
# waits for the (slow-exiting) child instead of treating an interrupted wait as done.
(
	_d2_env
	D2_HEALTH=PASS D2_ACCEPT_LINGER=2
	kill() { # fire TERM on the first liveness probe after the accept landed
		if [ "$1" = -0 ] && _d2_has np_accept && [ ! -e "$_d2_dir/fired" ]; then
			: >"$_d2_dir/fired"
			builtin kill -TERM "$D2_SELF"
		fi
		builtin kill "$@"
	}
	stop_trap_on
	backend_apply_with_revert "" ""
	echo "rc=$?" >"$_d2_res"
	echo returned >>"$_d2_ev"
)
_d2_assert "1ao TERM after confirmation: the accept stands" _d2_rc_zero
_d2_assert "1ao TERM after confirmation: waits for the child to exit" _d2_order np_exit returned

# (4) A1: TERM after the pre-launch check but before the writer opens. The trap
# closes an unopened fd 9, then `exec 9>"$fifo"` reopens it; STOP must be rechecked
# after the open and the cleanup must close fd 9 itself. The probe interface is
# absent and `ip` records every call and fails: with the STOP recheck after the
# open, the loop never polls for the probe, so a missing loop-top STOP check
# (cleanup left behind the 90s wall guard, past systemd's 60s bound) shows up as
# probe polls after STOP was set. Event assertions, no elapsed-time thresholds.
(
	_d2_env
	D2_FIRE_AT_CALL=2
	ip() { echo ip_probe >>"$_d2_ev"; return 1; }
	_d2_shadow_stop
	stop_trap_on
	backend_apply_with_revert "" "enp1s0.9"
	echo "rc=$?" >"$_d2_res"
	echo returned >>"$_d2_ev"
)
_d2_assert "1ao TERM before the writer opens: no confirmation" _d2_absent np_accept
_d2_assert "1ao TERM before the writer opens: reopened writer is closed (EOF seen)" _d2_has np_eof
_d2_assert "1ao TERM before the writer opens: returns non-zero" _d2_rc_nonzero
_d2_assert "1ao TERM before the writer opens: no probe polling after STOP was set" _d2_absent ip_probe
_d2_assert "1ao TERM before the writer opens: child exited before return" _d2_order np_exit returned

# (5) Deadline: a child that ignores EOF is not waited on forever.
(
	_d2_env
	D2_NP_MODE=stubborn
	SECONDS=0
	(
		stop_trap_on
		backend_apply_with_revert "" ""
		echo "rc=$?" >"$_d2_res"
		echo "elapsed=$SECONDS" >>"$_d2_res"
	) &
	pid=$!
	sleep 2
	kill -TERM "$pid"
	wait "$pid"
)
_d2_assert "1ao wedged child: returns non-zero at the deadline" _d2_rc_nonzero
_d2_assert "1ao wedged child: the uncertain state is logged" _d2_has "uncertain" "$_d2_log"
_d2_assert "1ao wedged child: bounded (deadline TRY_TIMEOUT+margin, not the child's 9s)" \
	bash -c "e=\$(sed -n 's/^elapsed=//p' '$_d2_res'); [ -n \"\$e\" ] && [ \"\$e\" -le 9 ]"

# (6) apply_change: a stop before ACCEPT restores the prior file and runs no
# delete, lease wait, or restart.
(
	_d2_env
	NETPLAN_FILE="$_d2_dir/90-dynavlan.yaml"
	BACKUP_DIR="$_d2_dir/backups"
	mkdir -p "$BACKUP_DIR"
	printf 'PRIOR\n' >"$NETPLAN_FILE"
	backend_generate_config() { printf 'CANDIDATE\n' >"$NETPLAN_FILE"; }
	backend_validate() { return 0; }
	snapshot_default_route() { :; }
	backend_remove_vlan() { echo remove >>"$_d2_ev"; return 0; }
	wait_leases() { echo leases >>"$_d2_ev"; }
	restart_targets() { echo restart >>"$_d2_ev"; }
	VLAN_ROUTES=false
	(
		apply_change "enp1s0.9" "enp1s0.9" ""
		echo "rc=$?" >"$_d2_res"
	) &
	pid=$!
	_d2_wait_start
	kill -TERM "$pid"
	wait "$pid"
	cat "$NETPLAN_FILE" >"$_d2_dir/file_after"
)
_d2_assert "1ao apply_change stop before ACCEPT: netplan try was running when TERM was sent" _d2_has np_start
_d2_assert "1ao apply_change stop before ACCEPT: non-zero" _d2_rc_nonzero
_d2_assert "1ao apply_change stop before ACCEPT: netplan try saw EOF" _d2_has np_eof
_d2_assert "1ao apply_change stop before ACCEPT: prior owned file restored" \
	test "$(cat "$_d2_dir/file_after" 2>/dev/null)" = PRIOR
_d2_assert "1ao apply_change stop before ACCEPT: no delete" _d2_absent remove
_d2_assert "1ao apply_change stop before ACCEPT: no lease wait" _d2_absent leases
_d2_assert "1ao apply_change stop before ACCEPT: no restart" _d2_absent restart

# (7) apply_change: a stop after ACCEPT runs the deletes but skips lease wait and restarts.
(
	_d2_env
	D2_HEALTH=PASS D2_ACCEPT_LINGER=2
	NETPLAN_FILE="$_d2_dir/90-dynavlan.yaml"
	BACKUP_DIR="$_d2_dir/backups"
	mkdir -p "$BACKUP_DIR"
	printf 'PRIOR\n' >"$NETPLAN_FILE"
	backend_generate_config() { printf 'CANDIDATE\n' >"$NETPLAN_FILE"; }
	backend_validate() { return 0; }
	snapshot_default_route() { :; }
	backend_remove_vlan() { echo remove >>"$_d2_ev"; return 0; }
	wait_leases() { echo leases >>"$_d2_ev"; }
	restart_targets() { echo restart >>"$_d2_ev"; }
	VLAN_ROUTES=false
	kill() {
		if [ "$1" = -0 ] && _d2_has np_accept && [ ! -e "$_d2_dir/fired" ]; then
			: >"$_d2_dir/fired"
			builtin kill -TERM "$D2_SELF"
		fi
		builtin kill "$@"
	}
	apply_change "enp1s0.9" "" "enp1s0.8"
	echo "rc=$?" >"$_d2_res"
	cat "$NETPLAN_FILE" >"$_d2_dir/file_after"
)
_d2_assert "1ao apply_change stop after ACCEPT: the accepted file is kept" \
	test "$(cat "$_d2_dir/file_after" 2>/dev/null)" = CANDIDATE
_d2_assert "1ao apply_change stop after ACCEPT: removals still run" _d2_has remove
_d2_assert "1ao apply_change stop after ACCEPT: no lease wait" _d2_absent leases
_d2_assert "1ao apply_change stop after ACCEPT: no restart" _d2_absent restart
_d2_assert "1ao apply_change stop after ACCEPT: reports non-zero (stop requested)" _d2_rc_nonzero

# (8) A2: helpers observe STOP themselves.
(
	_d2_env
	LEASE_SETTLE_SECONDS=8
	iface_has_lease() { return 1; }
	SECONDS=0
	(
		stop_trap_on
		wait_leases "enp1s0.9"
		echo "elapsed=$SECONDS" >"$_d2_res"
	) &
	pid=$!
	sleep 1
	kill -TERM "$pid"
	wait "$pid"
)
_d2_assert "1ao wait_leases stops waiting once STOP is set" \
	bash -c "e=\$(sed -n 's/^elapsed=//p' '$_d2_res'); [ -n \"\$e\" ] && [ \"\$e\" -le 4 ]"

(
	_d2_env
	RESTART_SNAPS="a b c"
	RESTART_SERVICES=""
	snap() { # TERM during the first restart: it finishes, the rest are skipped
		echo "snap_$2" >>"$_d2_ev"
		if [ "$2" = a ]; then builtin kill -TERM "$D2_SELF"; fi
		return 0
	}
	stop_trap_on
	restart_targets
	echo "rc=$?" >"$_d2_res"
)
_d2_assert "1ao restart_targets: the already-started restart finishes" _d2_has snap_a
_d2_assert "1ao restart_targets: later targets are not started after STOP" _d2_absent "snap_b"
_d2_assert "1ao restart_targets: reports non-zero when it stopped early" _d2_rc_nonzero

# (9) Composed: real main --rescan, real TERM from outside. Exit 1, owned file
# restored, no confirmation, and none of FR-40's restart or seen write.
(
	_d2_env
	D2_REVERT_DELAY=1
	LOCK_FILE="$_d2_dir/lock"
	NETPLAN_FILE="$_d2_dir/90-dynavlan.yaml"
	BACKUP_DIR="$_d2_dir/backups"
	SEEN_FILE="$_d2_dir/seen"
	mkdir -p "$BACKUP_DIR"
	printf 'PRIOR\n' >"$NETPLAN_FILE"
	load_config() { return 0; }
	check_preconditions() { return 0; }
	flock() { return 0; } # util-linux flock is absent on macOS; the lock itself is not under test
	RESTART_ON_NEW_SUBNET=true
	RESTART_SNAPS="a"
	RESTART_SERVICES=""
	drain_pending_deletes() { return 0; }
	run_detection() { DETECTED_TRUNKS="enp1s0"; }
	iface_tags() { echo 9; }
	backend_owned_vlans() { :; }
	backend_list_managed_vlans() { :; }
	ifaces_without_carrier() { :; }
	warn_overlap() { :; }
	backend_generate_config() { printf 'CANDIDATE\n' >"$NETPLAN_FILE"; }
	backend_validate() { return 0; }
	snapshot_default_route() { :; }
	current_subnets() { echo "enp1s0:10.0.0.0/24"; }
	snap() { echo snap_restart >>"$_d2_ev"; return 0; }
	VLAN_ROUTES=false
	(
		main --rescan
		echo "rc=$?" >"$_d2_res"
		echo returned >>"$_d2_ev"
	) &
	pid=$!
	_d2_wait_start
	kill -TERM "$pid"
	wait "$pid"
	cat "$NETPLAN_FILE" >"$_d2_dir/file_after"
)
_d2_assert "1ao main --rescan on TERM: netplan try was actually running when TERM was sent" _d2_has np_start
_d2_assert "1ao main --rescan on TERM: exits 1" grep -q '^rc=1$' "$_d2_res"
_d2_assert "1ao main --rescan on TERM: netplan try saw EOF" _d2_has np_eof
_d2_assert "1ao main --rescan on TERM: child exited before main returned" _d2_order np_exit returned
_d2_assert "1ao main --rescan on TERM: prior owned file restored" \
	test "$(cat "$_d2_dir/file_after" 2>/dev/null)" = PRIOR
_d2_assert "1ao main --rescan on TERM: no confirmation written" _d2_absent np_accept
_d2_assert "1ao main --rescan on TERM: no agent restart (whole FR-40 pass suppressed)" _d2_absent snap_restart
_d2_assert "1ao main --rescan on TERM: seen file not written" test ! -e "$_d2_dir/seen"

# (10) Static: both units stop mixed, and the nominal budget fits the stop bound.
for _d2_u in dynavlan.service dynavlan-rescan.service; do
	_d2_assert "1ao $_d2_u uses KillMode=mixed" grep -qx 'KillMode=mixed' "${here}/../$_d2_u"
	_d2_assert "1ao $_d2_u nominal stop budget fits TimeoutStopSec" bash -c "
		t=\$(sed -n 's/^TimeoutStopSec=//p' '${here}/../$_d2_u')
		[ -n \"\$t\" ] && [ \$((${POLL_INTERVAL} + ${TRY_TIMEOUT} + ${STOP_CHILD_MARGIN:-15} + 5)) -lt \"\$t\" ]"
done

rm -rf "$_d2_dir"
unset -f _d2_netplan _d2_env _d2_shadow_stop _d2_wait_start _d2_has _d2_absent _d2_assert _d2_rc_nonzero _d2_rc_zero _d2_order
unset _d2_dir _d2_ev _d2_log _d2_res _d2_u

# ---------------------------------------------------------------------------
# 1ap. do_reconfigure must not report success when systemd did not reload (D10).
# ---------------------------------------------------------------------------

_rc_dir=$(mktemp -d)
_rc_saved_drop="$TIMER_DROPIN_DIR"
_rc_saved_run="$SYSTEMD_RUN_DIR"
_rc_saved_min="${RESCAN_MINUTES:-}"
TIMER_DROPIN_DIR="$_rc_dir/dropin"
SYSTEMD_RUN_DIR="$_rc_dir/run"
RESCAN_MINUTES=5
mkdir -p "$SYSTEMD_RUN_DIR"

systemctl() { return 5; }
_rc_out=$(do_reconfigure 2>&1)
_rc_rc=$?
tests=$((tests + 1))
if [ "$_rc_rc" -ne 0 ] && [ -f "$TIMER_DROPIN_DIR/interval.conf" ]; then
	printf 'ok   - %s\n' "1ap do_reconfigure returns non-zero when daemon-reload fails (drop-in still written)"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       rc=%s out=[%s]\n' "1ap do_reconfigure returns non-zero when daemon-reload fails" "$_rc_rc" "$_rc_out"
fi
tests=$((tests + 1))
case "$_rc_out" in
*"NOT active until it succeeds"*) printf 'ok   - %s\n' "1ap do_reconfigure names the unreloaded interval" ;;
*)
	fails=$((fails + 1))
	printf 'FAIL - %s\n       got [%s]\n' "1ap do_reconfigure names the unreloaded interval" "$_rc_out"
	;;
esac
tests=$((tests + 1))
case "$_rc_out" in
*"timer interval set to"*)
	fails=$((fails + 1))
	printf 'FAIL - %s\n       a failed reload still logged success: [%s]\n' "1ap do_reconfigure never logs success after a failed reload" "$_rc_out"
	;;
*) printf 'ok   - %s\n' "1ap do_reconfigure never logs success after a failed reload" ;;
esac

systemctl() { return 0; }
_rc_out=$(do_reconfigure 2>&1)
_rc_rc=$?
tests=$((tests + 1))
if [ "$_rc_rc" -eq 0 ]; then
	printf 'ok   - %s\n' "1ap do_reconfigure succeeds when the reload succeeds"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       rc=%s out=[%s]\n' "1ap do_reconfigure succeeds when the reload succeeds" "$_rc_rc" "$_rc_out"
fi

# No manager running (chroot/container): the reload is skipped, not treated as a failure.
rmdir "$SYSTEMD_RUN_DIR"
systemctl() { return 5; }
_rc_out=$(do_reconfigure 2>&1)
_rc_rc=$?
tests=$((tests + 1))
if [ "$_rc_rc" -eq 0 ]; then
	printf 'ok   - %s\n' "1ap do_reconfigure skips the reload only where systemd is positively absent"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       rc=%s out=[%s]\n' "1ap do_reconfigure skips the reload only where systemd is positively absent" "$_rc_rc" "$_rc_out"
fi

unset -f systemctl
TIMER_DROPIN_DIR="$_rc_saved_drop"
SYSTEMD_RUN_DIR="$_rc_saved_run"
RESCAN_MINUTES="$_rc_saved_min"
rm -rf "$_rc_dir"
unset _rc_dir _rc_saved_drop _rc_saved_run _rc_saved_min _rc_out _rc_rc

# ---------------------------------------------------------------------------
# 1ar. Dry-run, status and subnet reporting (Group 4: S2 S3 L8 L9 D5 L13 L10).
#      The real do_dryrun / do_status / restart_targets / maybe_restart_on_new_subnet
#      run with narrow stubs at the detection, netplan and systemd boundaries. Each case
#      is a subshell so overrides never leak.
# ---------------------------------------------------------------------------

_g4_dir=$(mktemp -d)

_g4_is() { # desc expected actual
	tests=$((tests + 1))
	if [ "$2" = "$3" ]; then
		printf 'ok   - %s\n' "$1"
	else
		fails=$((fails + 1))
		printf 'FAIL - %s\n       expected [%s], got [%s]\n' "$1" "$2" "$3"
	fi
}
_g4_has() { # desc needle haystack
	tests=$((tests + 1))
	if printf '%s' "$3" | grep -qF -- "$2"; then
		printf 'ok   - %s\n' "$1"
	else
		fails=$((fails + 1))
		printf 'FAIL - %s\n       missing [%s] in [%s]\n' "$1" "$2" "$3"
	fi
}
_g4_lacks() { # desc needle haystack
	tests=$((tests + 1))
	if printf '%s' "$3" | grep -qF -- "$2"; then
		fails=$((fails + 1))
		printf 'FAIL - %s\n       unexpected [%s] in [%s]\n' "$1" "$2" "$3"
	else
		printf 'ok   - %s\n' "$1"
	fi
}

_g4_dry_env() { # defaults + stubs for one do_dryrun scenario
	RESET_ON_BOOT=true REMOVE_ON_CARRIER_LOSS=false RESTART_ON_NEW_SUBNET=true
	RESTART_SNAPS="" RESTART_SERVICES=""
	VLAN_MIN=2 VLAN_MAX=4094 IGNORE_SET="" VLAN_WARN=100 VLAN_LIMIT=0 VLAN_LIMIT_MODE=refuse VLAN_ROUTES=false
	PENDING_DELETE_FILE="$_g4_dir/pending" SEEN_FILE="$_g4_dir/seen"
	rm -f "$PENDING_DELETE_FILE" "$SEEN_FILE" "$_g4_dir/calls" "$_g4_dir/gen"
	DETECTED_TRUNKS="enp1s0"
	G4_TAGS="100" G4_VALID=valid G4_OWNED="enp1s0.100"
	run_detection() { return 0; }
	iface_tags() { printf '%s' "$G4_TAGS"; }
	iface_valid() { printf '%s' "$G4_VALID"; }
	backend_owned_vlans() { printf '%s' "$G4_OWNED"; }
	have_routing() { return 0; }
	backend_list_managed_vlans() { return 0; }
	has_carrier() { return 0; }
	snapshot_default_route() { printf '%s' "enp9s0"; }
	backend_netplan_vlan_tokens() { printf '%s' ""; }
	current_subnets() { printf '%s' "enp1s0:10.0.0.0/24"; }
	mktemp() { command mktemp -d "$_g4_dir/tree.XXXXXX"; }
	cp() { return 0; }
	backend_generate_config() { printf '%s' "$1" >"$_g4_dir/gen"; return 0; }
	backend_validate() { echo validate >>"$_g4_dir/calls"; return 0; }
	backend_remove_vlan() { echo remove >>"$_g4_dir/calls"; return 0; }
}
_g4_printed_target() { printf '%s\n' "$1" | sed -n 's/^  target:    \[\(.*\)\]$/\1/p'; }
_g4_removals() { printf '%s\n' "$1" | sed -n 's/^  removals:  \[\([^]]*\)\].*/\1/p'; }

# S2: an invalid sample must not authorize a detection-diff removal - including a
# NONEMPTY partial one (owned {100,200}, the failed sniff only saw 100).
_g4_out=$(
	_g4_dry_env
	G4_OWNED="enp1s0.100 enp1s0.200" G4_TAGS="100" G4_VALID=invalid
	do_dryrun 2>&1
)
_g4_is "1ar dry-run: a nonempty partial invalid sample removes nothing" "none" "$(_g4_removals "$_g4_out")"
_g4_has "1ar dry-run: the incomplete detection is reported" "detection incomplete" "$_g4_out"
_g4_is "1ar dry-run: both owned VLANs are in the preserved target" "enp1s0.100 enp1s0.200" "$(_g4_printed_target "$_g4_out")"
_g4_out=$(
	_g4_dry_env
	G4_OWNED="enp1s0.100 enp1s0.200" G4_TAGS="100" G4_VALID=valid
	do_dryrun 2>&1
)
_g4_is "1ar dry-run: the same sample, trusted, does remove the absent VLAN (control)" "enp1s0.200" "$(_g4_removals "$_g4_out")"

# S3: the real count gate. Refuse: additions AND removals cancelled, owned target, rc 1, no validation.
_g4_out=$(
	_g4_dry_env
	G4_OWNED="enp1s0.100" G4_TAGS="200 300" G4_VALID=valid VLAN_LIMIT=1 VLAN_LIMIT_MODE=refuse
	do_dryrun 2>&1
	echo "rc=$?"
	[ -e "$_g4_dir/calls" ] && echo "CALLS:$(cat "$_g4_dir/calls")"
	[ -e "$_g4_dir/gen" ] && echo "GEN:$(cat "$_g4_dir/gen")"
)
_g4_has "1ar dry-run count-gate refusal returns 1" "rc=1" "$_g4_out"
_g4_has "1ar dry-run count-gate refusal says so" "count gate REFUSED" "$_g4_out"
_g4_is "1ar dry-run count-gate refusal reports the unchanged owned target" "enp1s0.100" "$(_g4_printed_target "$_g4_out")"
_g4_is "1ar dry-run count-gate refusal cancels removals" "none" "$(_g4_removals "$_g4_out")"
_g4_lacks "1ar dry-run count-gate refusal never validates the rejected candidate" "CALLS:validate" "$_g4_out"
_g4_lacks "1ar dry-run count-gate refusal never generates a candidate" "GEN:" "$_g4_out"
# Fill: the filled target is printed AND generated.
_g4_out=$(
	_g4_dry_env
	G4_OWNED="enp1s0.100" G4_TAGS="100 200 300" G4_VALID=valid VLAN_LIMIT=2 VLAN_LIMIT_MODE=fill
	do_dryrun 2>&1
	echo "GEN:$(cat "$_g4_dir/gen" 2>/dev/null)"
)
_g4_is "1ar dry-run fill previews the filled target (lowest ids that fit)" "enp1s0.100 enp1s0.200" "$(_g4_printed_target "$_g4_out")"
_g4_is "1ar dry-run fill: the generated target equals the printed one" \
	"$(_g4_printed_target "$_g4_out")" "$(printf '%s\n' "$_g4_out" | sed -n 's/^GEN://p')"

# L8: a failed copy of the base tree is non-zero and never validates.
_g4_out=$(
	_g4_dry_env
	cp() { return 1; }
	do_dryrun 2>&1
	echo "rc=$?"
	[ -e "$_g4_dir/calls" ] && echo "CALLS:$(cat "$_g4_dir/calls")"
)
_g4_has "1ar dry-run base-tree copy failure returns non-zero" "rc=1" "$_g4_out"
_g4_has "1ar dry-run base-tree copy failure says it did not validate a partial tree" "not validating a partial tree" "$_g4_out"
_g4_lacks "1ar dry-run base-tree copy failure never calls validation" "CALLS:validate" "$_g4_out"

# L9 + L10: a quiet wire still previews guarded pending retries and the no-target subnet state,
# validates, and changes nothing (no delete, no pending/seen write).
_g4_out=$(
	_g4_dry_env
	DETECTED_TRUNKS="" G4_OWNED="" G4_TAGS=""
	printf '%s\n' enp1s0.100 enp1s0.101 enp1s0.102 >"$PENDING_DELETE_FILE"
	snapshot_default_route() { printf '%s' "enp1s0.101"; }          # D1: 101 is now the default route
	backend_netplan_vlan_tokens() { printf '%s' "enp1s0.102"; }      # L7: 102 is configured elsewhere
	command cp -f "$PENDING_DELETE_FILE" "$_g4_dir/pending.before"
	do_dryrun 2>&1
	echo "rc=$?"
	cmp -s "$PENDING_DELETE_FILE" "$_g4_dir/pending.before" && echo "PENDING:unchanged"
	[ -e "$SEEN_FILE" ] && echo "SEEN:written"
	[ -e "$_g4_dir/calls" ] && echo "CALLS:$(tr '\n' ',' <"$_g4_dir/calls")"
)
_g4_has "1ar quiet wire: dry-run still completes and validates" "validate:  OK" "$_g4_out"
_g4_has "1ar quiet wire: dry-run returns 0" "rc=0" "$_g4_out"
_g4_has "1ar quiet wire: the retryable pending delete is previewed" "would retry): [enp1s0.100]" "$_g4_out"
_g4_has "1ar quiet wire: guarded pending deletes are previewed as preserved" "PRESERVED" "$_g4_out"
_g4_has "1ar quiet wire: the default-route-guarded token is named" "enp1s0.101" "$_g4_out"
_g4_has "1ar quiet wire: the configured-elsewhere token is named" "enp1s0.102" "$_g4_out"
_g4_has "1ar quiet wire: the pending record is untouched" "PENDING:unchanged" "$_g4_out"
_g4_lacks "1ar quiet wire: the seen record is not written" "SEEN:written" "$_g4_out"
_g4_lacks "1ar quiet wire: no link is deleted" "remove" "$(printf '%s' "$_g4_out" | grep '^CALLS:')"
_g4_has "1ar quiet wire: no restart targets is reported, not 'would restart'" "no restart targets configured" "$_g4_out"
_g4_lacks "1ar quiet wire: never claims it would restart without targets" "(would restart)" "$_g4_out"
_g4_out=$(
	_g4_dry_env
	RESTART_SNAPS="a"
	do_dryrun 2>&1
)
_g4_has "1ar dry-run with a target still says it would restart" "(would restart)" "$_g4_out"

# Pending preview follows the snapshot the real drain takes BEFORE detection; the apply/C1
# preview keeps the later one. Detection changes the default route here (enp1s0.101 -> enp1s0.200).
_g4_out=$(
	_g4_dry_env
	G4_OWNED="enp1s0.100 enp1s0.200" G4_TAGS="100" G4_VALID=valid
	printf '%s\n' enp1s0.101 >"$PENDING_DELETE_FILE"
	run_detection() { : >"$_g4_dir/detected"; return 0; }
	snapshot_default_route() { if [ -e "$_g4_dir/detected" ]; then printf '%s' enp1s0.200; else printf '%s' enp1s0.101; fi; }
	rm -f "$_g4_dir/detected"
	do_dryrun 2>&1
)
_g4_has "1ar pending preview follows the pre-detection snapshot (101 was the default then)" "PRESERVED" "$_g4_out"
_g4_has "1ar the C1 apply preview keeps the later snapshot (200 is the default now and is being removed)" "current default iface (enp1s0.200) is in removals" "$_g4_out"
_g4_lacks "1ar the pending token is not retried under the later snapshot" "would retry): [enp1s0.101]" "$_g4_out"

# Pending preview: a failed netplan query is UNAVAILABLE, non-zero, and touches nothing.
_g4_out=$(
	_g4_dry_env
	printf '%s\n' enp1s0.100 >"$PENDING_DELETE_FILE"
	command cp -f "$PENDING_DELETE_FILE" "$_g4_dir/pending.before"
	backend_netplan_vlan_tokens() { return 1; }
	do_dryrun 2>&1
	echo "rc=$?"
	cmp -s "$PENDING_DELETE_FILE" "$_g4_dir/pending.before" && echo "PENDING:unchanged"
	[ -e "$_g4_dir/calls" ] && echo "CALLS:$(tr '\n' ',' <"$_g4_dir/calls")"
)
_g4_has "1ar pending preview query failure is reported UNAVAILABLE" "pending re-delete: UNAVAILABLE" "$_g4_out"
_g4_has "1ar pending preview query failure returns 1" "rc=1" "$_g4_out"
_g4_has "1ar pending preview query failure leaves the pending record unchanged" "PENDING:unchanged" "$_g4_out"
_g4_lacks "1ar pending preview query failure deletes no link" "remove" "$(printf '%s' "$_g4_out" | grep '^CALLS:')"

# D5: status aggregates detector validity across ALL sampled interfaces.
_g4_status_env() {
	RESTART_ON_NEW_SUBNET=false DETECT_METHOD=both VLAN_MIN=2 VLAN_MAX=4094 IGNORE_SET=""
	SEEN_FILE="$_g4_dir/seen"
	G4_OWNED="" G4_TAGS="" DETECTED_TRUNKS="" DETECT_INVALID=""
	check_detect_deps() { return 0; }
	run_detection() { return 0; }
	backend_owned_vlans() { printf '%s' "$G4_OWNED"; }
	iface_tags() { eval "printf '%s' \"\${G4_TAGS_$1:-}\""; }
	backend_list_managed_vlans() { return 0; }
	has_carrier() { return 0; }
	current_subnets() { printf '%s' ""; }
}
_g4_out=$(
	_g4_status_env
	DETECT_INVALID="enp9s0" # failed interface OUTSIDE the owned/detected union, nothing detected
	do_status 2>&1
	echo "rc=$?"
)
_g4_has "1ar status: invalid-empty detection (failed iface outside the union) returns 1" "rc=1" "$_g4_out"
_g4_has "1ar status: invalid-empty detection says unavailable" "detected trunks: unavailable" "$_g4_out"
_g4_out=$(
	_g4_status_env
	DETECTED_TRUNKS="enp1s0" G4_TAGS_enp1s0="100" DETECT_INVALID="enp1s0"
	do_status 2>&1
	echo "rc=$?"
)
_g4_has "1ar status: invalid-partial detection returns 1" "rc=1" "$_g4_out"
_g4_has "1ar status: invalid-partial detection is marked incomplete" "may be incomplete" "$_g4_out"
_g4_has "1ar status: invalid-partial detection still prints the partial trunk list" "detected trunks: [enp1s0]" "$_g4_out"
_g4_has "1ar status: invalid-partial detection still prints the detected=[100] row" "enp1s0: carrier=up configured=[none] detected=[100]" "$_g4_out"
_g4_out=$(
	_g4_status_env
	do_status 2>&1
	echo "rc=$?"
)
_g4_has "1ar status: a quiet valid wire is still successful" "rc=0" "$_g4_out"
_g4_has "1ar status: a quiet valid wire still reads none" "detected trunks: [none]" "$_g4_out"

# D5 (real aggregation): the `both` policy is preserved - a failed LLDP beside a successful
# sniff is valid; a failed sniff is not, even on an interface that has no tags and no ownership.
_g4_out=$(
	DETECT_METHOD=both CARRIER_WAIT_SECONDS=0
	discover_phys_ifaces() { printf '%s\n' enp1s0 enp2s0; }
	prep_iface() { :; }
	has_carrier() { return 0; }
	mktemp() { return 1; }
	detect_iface() { if [ "$1" = enp1s0 ]; then printf 'ok fail 100'; else printf 'fail ok '; fi; }
	run_detection >/dev/null 2>&1
	echo "INVALID=[$DETECT_INVALID] TRUNKS=[$DETECTED_TRUNKS]"
)
_g4_is "1ar run_detection: supplementary LLDP failure alone stays valid; only the failed sniff is invalid" \
	"INVALID=[enp2s0] TRUNKS=[enp1s0]" "$_g4_out"

# L13: one row per owned-or-detected trunk.
_g4_out=$(
	_g4_status_env
	G4_OWNED="enp1s0.100 enp2s0.200"
	DETECTED_TRUNKS="enp1s0 enp3s0" G4_TAGS_enp1s0="100 300" G4_TAGS_enp3s0="400"
	has_carrier() { [ "$1" != enp2s0 ]; }
	do_status 2>&1
)
_g4_has "1ar status: a shared trunk gets configured and detected on one row" "enp1s0: carrier=up configured=[enp1s0.100] detected=[100 300]" "$_g4_out"
_g4_has "1ar status: an owned-only trunk gets a row (carrier down, nothing detected)" "enp2s0: carrier=down configured=[enp2s0.200] detected=[none]" "$_g4_out"
_g4_has "1ar status: a detected-only trunk gets a row with nothing configured" "enp3s0: carrier=up configured=[none] detected=[400]" "$_g4_out"

# Status: a failed managed-elsewhere query for an OWNED-ONLY trunk is unavailable and non-zero.
_g4_out=$(
	_g4_status_env
	G4_OWNED="enp2s0.200"
	backend_list_managed_vlans() { return 1; }
	do_status 2>&1
	echo "rc=$?"
)
_g4_has "1ar status: an owned-only trunk's failed managed query reads managed-elsewhere=[unavailable]" "managed-elsewhere=[unavailable]" "$_g4_out"
_g4_has "1ar status: an owned-only trunk's failed managed query returns 1" "rc=1" "$_g4_out"

# L10 (core, composed): the real restart_targets with no targets, then the real subnet pass -
# the sequence reached after an accepted apply.
_g4_out=$(
	SEEN_FILE="$_g4_dir/seen2"; rm -f "$SEEN_FILE"
	RESTART_ON_NEW_SUBNET=true RESTART_SNAPS="" RESTART_SERVICES=""
	RESTARTED_THIS_RUN=0 RESTART_NONE_SUCCEEDED_THIS_RUN=0
	current_subnets() { printf '%s' "enp1s0:10.0.0.0/24"; }
	snap() { echo snap_$2 >>"$_g4_dir/snaps"; return 0; }
	rm -f "$_g4_dir/snaps"
	restart_targets >/dev/null 2>&1
	maybe_restart_on_new_subnet >/dev/null 2>&1
	echo "A:$(cat "$SEEN_FILE" 2>/dev/null)"
	# a target is configured later and the next run succeeds: consumed exactly once
	RESTART_SNAPS="a" RESTARTED_THIS_RUN=0 RESTART_NONE_SUCCEEDED_THIS_RUN=0
	maybe_restart_on_new_subnet >/dev/null 2>&1
	echo "B:$(cat "$SEEN_FILE" 2>/dev/null)"
	RESTARTED_THIS_RUN=0
	maybe_restart_on_new_subnet >/dev/null 2>&1
	echo "RESTARTS:$(grep -c snap_ "$_g4_dir/snaps")"
)
_g4_is "1ar no targets (apply path then subnet pass): the new subnet stays unseen" "A:" "$(printf '%s\n' "$_g4_out" | grep '^A:')"
_g4_is "1ar a later configured target consumes the subnet" "B:enp1s0:10.0.0.0/24" "$(printf '%s\n' "$_g4_out" | grep '^B:')"
_g4_is "1ar the catch-up restart happens exactly once" "RESTARTS:1" "$(printf '%s\n' "$_g4_out" | grep '^RESTARTS:')"
_g4_out=$(
	SEEN_FILE="$_g4_dir/seen3"; rm -f "$SEEN_FILE"; rm -f "$_g4_dir/snaps"
	RESTART_ON_NEW_SUBNET=true RESTART_SNAPS="a" RESTART_SERVICES=""
	current_subnets() { printf '%s' "enp1s0:10.0.0.0/24"; }
	snap() { echo snap_$2 >>"$_g4_dir/snaps"; return 1; }
	for _ in 1 2; do
		RESTARTED_THIS_RUN=0 RESTART_NONE_SUCCEEDED_THIS_RUN=0
		maybe_restart_on_new_subnet >/dev/null 2>&1
	done
	echo "SEEN:[$(cat "$SEEN_FILE" 2>/dev/null)] TRIES:$(grep -c snap_ "$_g4_dir/snaps")"
)
_g4_is "1ar an attempted total failure leaves the subnet unseen and retries" "SEEN:[] TRIES:2" "$_g4_out"
_g4_out=$(
	SEEN_FILE="$_g4_dir/seen4"; rm -f "$SEEN_FILE"; rm -f "$_g4_dir/snaps"
	RESTART_ON_NEW_SUBNET=true RESTART_SNAPS="a b" RESTART_SERVICES=""
	current_subnets() { printf '%s' "enp1s0:10.0.0.0/24"; }
	snap() { echo snap_$2 >>"$_g4_dir/snaps"; [ "$2" = a ]; }
	for _ in 1 2; do
		RESTARTED_THIS_RUN=0 RESTART_NONE_SUCCEEDED_THIS_RUN=0
		maybe_restart_on_new_subnet >/dev/null 2>&1
	done
	echo "SEEN:[$(cat "$SEEN_FILE" 2>/dev/null)] RESTARTS:$(grep -c snap_ "$_g4_dir/snaps")"
)
_g4_is "1ar a partial success consumes the subnet with no restart storm (a and b once, not again)" \
	"SEEN:[enp1s0:10.0.0.0/24] RESTARTS:2" "$_g4_out"

# ---------------------------------------------------------------------------
# 1at. dynavlan --teardown (Group 6, D7): attended removal of owned network state.
#      Reuses apply_change "" "" "$owned" "" (empty candidate through the health-gated
#      netplan try path). Stubs sit at the systemd / ip / netplan boundary; one composed
#      case runs the REAL apply_change, backend_generate_config and backend_remove_vlan.
# ---------------------------------------------------------------------------

_g6_dir=$(mktemp -d)
# Real definitions, kept so the composed case can restore them after _g6_env stubs them.
_g6_real_apply=$(declare -f apply_change)
_g6_real_drain=$(declare -f drain_pending_deletes)
_g6_real_owned=$(declare -f backend_owned_vlans)

_g6_env() { # defaults + stubs for one do_teardown/main --teardown scenario
	LOCK_FILE="$_g6_dir/lock" CONF_FILE="$_g6_dir/none.conf" SEEN_FILE="$_g6_dir/seen"
	PENDING_DELETE_FILE="$_g6_dir/pending" NETPLAN_FILE="$_g6_dir/90-dynavlan.yaml"
	SYSTEMD_RUN_DIR="$_g6_dir/run"; mkdir -p "$SYSTEMD_RUN_DIR"
	SYSTEMD_UNIT_ETC="$_g6_dir/uetc"; SYSTEMD_UNIT_LIB="$_g6_dir/ulib"; mkdir -p "$SYSTEMD_UNIT_ETC" "$SYSTEMD_UNIT_LIB"
	: >"$SYSTEMD_UNIT_LIB/dynavlan.timer"; : >"$SYSTEMD_UNIT_LIB/dynavlan.service"
	rm -f "$_g6_dir/calls" "$_g6_dir/args" "$_g6_dir/pending"
	G6_OWNED="enp1s0.100 enp1s0.200" G6_TMR_EN=disabled G6_SVC_EN=disabled G6_TMR_ACT=inactive G6_SVC_ACT=inactive
	G6_APPLY_RC=0 G6_DRAIN_RC=0 G6_LIVE=""
	printf '%s\n' '# Managed by dynavlan' 'network:' '  version: 2' >"$NETPLAN_FILE"
	check_apply_prereqs() { return 0; }
	flock() { return 0; }
	systemctl() {
		if [ "$1:$2" = is-enabled:dynavlan.timer ]; then printf '%s' "$G6_TMR_EN"
		elif [ "$1:$2" = is-enabled:dynavlan.service ]; then printf '%s' "$G6_SVC_EN"
		elif [ "$1:$2" = is-active:dynavlan.timer ]; then printf '%s' "$G6_TMR_ACT"
		elif [ "$1:$2" = is-active:dynavlan.service ]; then printf '%s' "$G6_SVC_ACT"
		fi
		return 0
	}
	drain_pending_deletes() { echo drain >>"$_g6_dir/calls"; return "$G6_DRAIN_RC"; }
	backend_owned_vlans() { printf '%s' "$G6_OWNED"; }
	apply_change() { echo apply >>"$_g6_dir/calls"; printf '[%s]|[%s]|[%s]|[%s]' "$1" "$2" "$3" "$4" >"$_g6_dir/args"; return "$G6_APPLY_RC"; }
	ip() { if [ "$1 $2" = "link show" ]; then [[ " $G6_LIVE " == *" $3 "* ]]; return; fi; echo "ip $*" >>"$_g6_dir/calls"; return 0; }
}
_g6_n() { local c; c=$(grep -c "^$1\$" "$_g6_dir/calls" 2>/dev/null) || c=0; printf '%s' "${c:-0}"; }

# --- check_apply_prereqs: root, ip, netplan version, `netplan try --help`; NO detection tools
_g6_out=$(
	have_cmd() { [ "$1" = netplan ] || [ "$1" = ip ]; } # no tcpdump, no lldpctl
	netplan_version() { echo 1.0; }
	netplan() { return 0; }
	id() { echo 0; }
	DETECT_METHOD=both MIN_NETPLAN=0.106
	check_apply_prereqs 2>&1 && echo OK
)
_g4_is "1at prerequisites do not require tcpdump or lldpctl" "OK" "$_g6_out"
_g6_out=$(
	have_cmd() { [ "$1" = netplan ]; }
	netplan_version() { echo 1.0; }; netplan() { return 0; }; id() { echo 0; }; MIN_NETPLAN=0.106
	check_apply_prereqs 2>&1 || echo REFUSED
)
_g4_has "1at prerequisites refuse when ip is missing" "REFUSED" "$_g6_out"
_g6_out=$(
	have_cmd() { return 0; }; netplan_version() { echo 0.100; }; netplan() { return 0; }; id() { echo 0; }; MIN_NETPLAN=0.106
	check_apply_prereqs 2>&1 || echo REFUSED
)
_g4_has "1at prerequisites refuse an old netplan" "REFUSED" "$_g6_out"
_g6_out=$(
	have_cmd() { return 0; }; netplan_version() { echo 1.0; }; netplan() { return 1; }; id() { echo 0; }; MIN_NETPLAN=0.106
	check_apply_prereqs 2>&1 || echo REFUSED
)
_g4_has "1at prerequisites refuse when netplan try is unavailable" "REFUSED" "$_g6_out"
_g6_out=$(
	have_cmd() { return 0; }; netplan_version() { echo 1.0; }; netplan() { return 0; }; id() { echo 1000; }; MIN_NETPLAN=0.106
	check_apply_prereqs 2>&1 || echo REFUSED
)
_g4_has "1at prerequisites refuse a non-root caller" "REFUSED" "$_g6_out"

# --- clean default reset: a config that partly parses must not leak values into a teardown
printf '%s\n' 'VLAN_MIN=5' 'VLAN_WARN=notanumber' >"$_g6_dir/bad.conf"
_g6_out=$(
	_g6_env
	CONF_FILE="$_g6_dir/bad.conf"
	apply_change() { echo "MIN=$VLAN_MIN WARN=$VLAN_WARN" >"$_g6_dir/args"; return 0; }
	main --teardown 2>&1
	echo "rc=$?"; cat "$_g6_dir/args"
)
_g4_has "1at an invalid config is ignored with a warning" "ignoring" "$_g6_out"
_g4_has "1at teardown runs on a COMPLETE default state, not a partial parse" "MIN=1 WARN=32" "$_g6_out"
_g4_has "1at teardown still proceeds and succeeds after the config fallback" "rc=0" "$_g6_out"
_g6_out=$(
	_g6_env
	CONF_FILE="$_g6_dir/bad.conf"
	main --boot 2>&1
	echo "rc=$?"
)
_g4_has "1at the config fallback is NOT broadened: --boot still refuses an invalid config" "rc=1" "$_g6_out"

# --- lock: bounded wait, refusal before anything is done
_g6_out=$(
	_g6_env
	flock() { return 1; }
	main --teardown 2>&1
	echo "rc=$?"; echo "APPLY:$(_g6_n apply) DRAIN:$(_g6_n drain)"
)
_g4_has "1at a held run lock refuses" "rc=1" "$_g6_out"
_g4_has "1at a held run lock does nothing else" "APPLY:0 DRAIN:0" "$_g6_out"

# --- posture refusals (while holding the lock), each BEFORE any mutation
while IFS='|' read -r _g6_name _g6_te _g6_se _g6_ta _g6_sa; do
	_g6_out=$(
		_g6_env
		G6_TMR_EN=$_g6_te G6_SVC_EN=$_g6_se G6_TMR_ACT=$_g6_ta G6_SVC_ACT=$_g6_sa
		main --teardown 2>&1
		echo "rc=$?"; echo "APPLY:$(_g6_n apply) DRAIN:$(_g6_n drain)"
	)
	_g4_has "1at posture refusal: $_g6_name" "rc=1" "$_g6_out"
	_g4_has "1at posture refusal changes nothing: $_g6_name" "APPLY:0 DRAIN:0" "$_g6_out"
done <<'TABLE'
the timer is enabled|enabled|disabled|inactive|inactive
the boot service is enabled|disabled|enabled|inactive|inactive
the timer is active|disabled|disabled|active|inactive
the timer is activating|disabled|disabled|activating|inactive
the boot service is active|disabled|disabled|inactive|active
is-enabled is indeterminate|unknown-state||inactive|inactive
is-active is indeterminate|disabled|disabled||inactive
TABLE
_g6_out=$(
	_g6_env
	G6_TMR_EN=masked G6_SVC_EN=disabled G6_TMR_ACT=failed G6_SVC_ACT=inactive
	main --teardown 2>&1
	echo "rc=$?"; echo "APPLY:$(_g6_n apply)"
)
_g4_has "1at masked and failed units are an acceptable posture" "APPLY:1" "$_g6_out"
_g6_out=$(
	_g6_env
	G6_SVC_EN=enabled
	main --teardown 2>&1
)
_g4_has "1at an enabled boot service is named and the fix is given" "dynavlan.service is enabled" "$_g6_out"
_g4_has "1at the refusal gives the exact disable command" "systemctl disable dynavlan.service dynavlan.timer" "$_g6_out"

# --- drain, owned-state queries
_g6_out=$(
	_g6_env
	G6_DRAIN_RC=1
	main --teardown 2>&1
	echo "rc=$?"; echo "APPLY:$(_g6_n apply)"
)
_g4_has "1at a failed pending-delete drain aborts before the apply" "rc=1" "$_g6_out"
_g4_has "1at a failed pending-delete drain applies nothing" "APPLY:0" "$_g6_out"
_g6_out=$(
	_g6_env
	G6_OWNED=""
	printf '%s\n' 'network:' '  version: 2' '  vlans:' '    weird-name:' '      id: 5' >"$NETPLAN_FILE"
	main --teardown 2>&1
	echo "rc=$?"; echo "APPLY:$(_g6_n apply)"
)
_g4_has "1at a vlans: section with no canonical owned token is refused" "rc=1" "$_g6_out"
_g4_has "1at an unrecognized owned file applies nothing" "APPLY:0" "$_g6_out"
_g6_out=$(
	_g6_env
	backend_owned_vlans() { return 1; }
	main --teardown 2>&1
	echo "rc=$?"; echo "APPLY:$(_g6_n apply)"
)
_g4_has "1at a failed owned-state query is refused, not read as nothing owned" "rc=1" "$_g6_out"
_g6_out=$(
	_g6_env
	G6_OWNED=""
	main --teardown 2>&1
	echo "rc=$?"; echo "APPLY:$(_g6_n apply) DRAIN:$(_g6_n drain)"
)
_g4_has "1at nothing owned (inert file) is a successful no-op" "rc=0" "$_g6_out"
_g4_has "1at nothing owned still retries pending orphans first, applying nothing" "APPLY:0 DRAIN:1" "$_g6_out"
_g6_out=$(
	_g6_env
	G6_OWNED=""; rm -f "$NETPLAN_FILE"
	main --teardown 2>&1
	echo "rc=$?"
)
_g4_has "1at an absent owned file is also a valid nothing-owned state" "rc=0" "$_g6_out"

# --- the exact empty-target apply, and what happens after it
_g6_out=$(
	_g6_env
	main --teardown 2>&1
	echo "rc=$?"; cat "$_g6_dir/args"
)
_g4_has "1at apply_change gets an empty target, no additions, the owned set as removals, no lease set" "[]|[]|[enp1s0.100 enp1s0.200]|[]" "$_g6_out"
_g4_has "1at a clean accepted teardown succeeds" "rc=0" "$_g6_out"
_g6_out=$(
	_g6_env
	G6_APPLY_RC=1 G6_LIVE="enp1s0.100 enp1s0.200"
	main --teardown 2>&1
	echo "rc=$?"; echo "DRAIN:$(_g6_n drain)"
)
_g4_has "1at a non-accepted apply propagates failure" "rc=1" "$_g6_out"
_g4_lacks "1at a non-accepted apply NEVER offers manual link deletes (the prior YAML was restored)" "ip link delete" "$_g6_out"
_g4_has "1at a non-accepted apply does not run the post-accept drain" "DRAIN:1" "$_g6_out"
_g6_out=$(
	_g6_env
	G6_LIVE="enp1s0.200"
	main --teardown 2>&1
	echo "rc=$?"; echo "DRAIN:$(_g6_n drain)"
)
_g4_has "1at an accepted teardown with a residual link prints the exact delete command" "ip link delete enp1s0.200" "$_g6_out"
_g4_lacks "1at only the residual token is named" "ip link delete enp1s0.100" "$_g6_out"
_g4_has "1at an accepted teardown with a residual link fails" "rc=1" "$_g6_out"
_g4_has "1at an accepted teardown retries pending deletes once more (drain ran twice)" "DRAIN:2" "$_g6_out"
_g6_out=$(
	_g6_env
	drain_pending_deletes() { echo drain >>"$_g6_dir/calls"; [ "$(grep -c '^drain$' "$_g6_dir/calls")" -lt 2 ]; }
	main --teardown 2>&1
	echo "rc=$?"
)
_g4_has "1at a failed post-accept drain fails even with no visible residual" "rc=1" "$_g6_out"

# --- composed: the REAL apply_change / backend_generate_config / backend_remove_vlan
_g6_out=$(
	_g6_env
	unset -f ip
	eval "$_g6_real_apply"; eval "$_g6_real_drain"; eval "$_g6_real_owned"
	POLL_INTERVAL=1 TRY_TIMEOUT=6 APPLY_NOEVIDENCE_SETTLE=0 APPLY_FALLBACK_SETTLE=0 HEALTH_CONSEC=1 STOP_CHILD_MARGIN=1
	BACKUP_DIR="$_g6_dir/backups"; mkdir -p "$BACKUP_DIR"
	RESTART_SNAPS="" RESTART_SERVICES="" VLAN_ROUTES=false RESTART_ON_NEW_SUBNET=false
	printf '%s\n' '# Managed by dynavlan' 'network:' '  version: 2' '  vlans:' '    enp1s0.100:' '      id: 100' '      link: enp1s0' \
		'    enp1s0.200:' '      id: 200' '      link: enp1s0' >"$NETPLAN_FILE"
	G6_LIVE="enp1s0.100 enp1s0.200"
	ip() {
		if [ "$1 $2" = "link show" ]; then [[ " $G6_LIVE " == *" $3 "* ]]; return; fi
		if [ "$1 $2" = "link delete" ]; then echo "deleted $3" >>"$_g6_dir/calls"; G6_LIVE=$(printf '%s' " $G6_LIVE " | sed "s/ $3 / /"); return 0; fi
		return 0
	}
	netplan() { if [ "$1" = try ]; then IFS= read -r _ && return 0; return 1; fi; return 0; }
	mktemp() { printf '%s\n' "$_g6_dir/fifo.$RANDOM"; }
	snapshot_default_route() { printf '%s' enp9s0; }
	post_apply_health() { echo PASS; }
	backend_validate() { return 0; }
	main --teardown 2>&1
	echo "rc=$?"
	echo "FILE:$(tr '\n' '~' <"$NETPLAN_FILE")"
	echo "DELETES:$(grep -c '^deleted ' "$_g6_dir/calls")"
	echo "BACKUPS:$(find "$BACKUP_DIR" -type f | wc -l | tr -d ' ')"
)
_g4_has "1at composed: the real teardown succeeds" "rc=0" "$_g6_out"
_g4_has "1at composed: the owned file becomes an empty, inert config" "FILE:# Managed by dynavlan" "$_g6_out"
_g4_lacks "1at composed: the owned file defines no vlans afterwards" "vlans:" "$(printf '%s\n' "$_g6_out" | grep '^FILE:')"
_g4_has "1at composed: both owned links are deleted after acceptance" "DELETES:2" "$_g6_out"
_g4_has "1at composed: the prior owned file was backed up first" "BACKUPS:1" "$_g6_out"

rm -rf "$_g6_dir"
unset -f _g6_env _g6_n
unset _g6_real_apply _g6_real_drain _g6_real_owned
unset _g6_dir _g6_out _g6_name _g6_te _g6_se _g6_ta _g6_sa

rm -rf "$_g4_dir"
unset -f _g4_is _g4_has _g4_lacks _g4_dry_env _g4_printed_target _g4_removals _g4_status_env
unset _g4_dir _g4_out

# ---------------------------------------------------------------------------
# 1as. Configuration grammar and frozen semantics (Group 5: L2 L11 L12 L14).
#      Canonical decimal integers only; VLAN_IGNORE with no empty elements or leading
#      zeros; quoted values must close and end cleanly; ignore/range narrowing only
#      suppresses NEW candidates; routed metrics follow lexical full-token order.
# ---------------------------------------------------------------------------

_g5_dir=$(mktemp -d)

# Run the REAL load_config against a one-line conffile; echoes "rc=N" then any diagnostics.
_g5_load() { # LINE
	printf '%s\n' "$1" >"$_g5_dir/conf"
	(
		CONF_FILE="$_g5_dir/conf"
		load_config 2>&1
		echo "rc=$?"
	)
}
_g5_acc() { # desc LINE
	local o
	o=$(_g5_load "$2")
	tests=$((tests + 1))
	if printf '%s' "$o" | grep -q '^rc=0$'; then
		printf 'ok   - %s\n' "$1"
	else
		fails=$((fails + 1))
		printf 'FAIL - %s\n       expected accept, got [%s]\n' "$1" "$o"
	fi
}
_g5_rej() { # desc LINE : rejected, with a diagnostic and no arithmetic noise
	local o
	o=$(_g5_load "$2")
	tests=$((tests + 1))
	if printf '%s' "$o" | grep -q '^rc=1$' && printf '%s' "$o" | grep -q 'dynavlan\[err\]' &&
		! printf '%s' "$o" | grep -qiE 'value too great|syntax error|arithmetic|invalid number|integer expression'; then
		printf 'ok   - %s\n' "$1"
	else
		fails=$((fails + 1))
		printf 'FAIL - %s\n       expected clean rejection, got [%s]\n' "$1" "$o"
	fi
}

# Every scalar numeric key: its boundary values load, and 00/01/018 are rejected cleanly.
# key  lowest-valid  invalid-below-min(empty = none)  highest-valid
while read -r _g5_k _g5_lo _g5_below _g5_hi; do
	_g5_acc "1as $_g5_k accepts its lowest valid value $_g5_lo" "$_g5_k=$_g5_lo"
	_g5_acc "1as $_g5_k accepts a canonical multi-digit value" "$_g5_k=$_g5_hi"
	[ "$_g5_below" = - ] || _g5_rej "1as $_g5_k rejects $_g5_below (below its minimum)" "$_g5_k=$_g5_below"
	for _g5_bad in 00 01 018; do
		_g5_rej "1as $_g5_k rejects the non-canonical $_g5_bad" "$_g5_k=$_g5_bad"
	done
done <<'TABLE'
VLAN_MIN 1 0 100
VLAN_MAX 1 0 4094
VLAN_WARN 1 0 32
VLAN_LIMIT 0 - 64
SNIFF_SECONDS 1 0 60
BOOT_SETTLE_SECONDS 0 - 20
CARRIER_WAIT_SECONDS 0 - 30
LEASE_SETTLE_SECONDS 0 - 30
RESCAN_MINUTES 1 0 5
VLAN_ROUTE_METRIC_START 1 0 100
BACKUP_KEEP 1 0 10
TABLE

# VLAN_IGNORE: canonical values load; leading zeros and empty comma elements do not.
for _g5_v in "100" "10-20" "1,5,20-25" "1 5 80" "100, 200" "100 ,200" "100 , 200"; do
	_g5_acc "1as VLAN_IGNORE accepts [$_g5_v]" "VLAN_IGNORE=\"$_g5_v\""
done
for _g5_v in "01" "0100" "010-20" "10-020" ",100" "100," "100,,200" "100, ,200" ", 100"; do
	_g5_rej "1as VLAN_IGNORE rejects [$_g5_v]" "VLAN_IGNORE=\"$_g5_v\""
done

# Quoted values: valid forms parse; unmatched quotes and trailing junk refuse the config.
_g5_acc "1as quotes: a double-quoted value loads" 'VLAN_MIN="5"'
_g5_acc "1as quotes: a single-quoted value loads" "VLAN_MIN='5'"
_g5_acc "1as quotes: a bare value loads" 'VLAN_MIN=5'
_g5_acc "1as quotes: a comment after the closing quote loads" 'VLAN_MIN="5" # floor'
_g5_acc "1as quotes: an immediate comment after the closing quote loads" 'VLAN_MIN="5"# floor'
_g5_acc "1as quotes: an empty quoted list loads" 'VLAN_IGNORE=""'
_g5_acc "1as quotes: a quoted list with inner spaces loads" 'VLAN_IGNORE="1 5 80"   # list'
_g5_rej "1as quotes: an unmatched double quote is refused" 'VLAN_MIN="5'
_g5_rej "1as quotes: an unmatched single quote is refused" "VLAN_MIN='5"
_g5_rej "1as quotes: junk after the closing quote is refused" 'VLAN_MIN="5" junk'
_g5_rej "1as quotes: junk after a single-quoted value is refused" "VLAN_MIN='5' x"
call config_normalize_value '"x" # c';  ok "1as normalize: quoted + comment" "x"
call config_normalize_value '"x'
err "1as normalize: unmatched quote returns non-zero"
_g5_o=$(_g5_load 'VLAN_MIN="5')
tests=$((tests + 1))
if printf '%s' "$_g5_o" | grep -q 'VLAN_MIN'; then
	printf 'ok   - %s\n' "1as a refused quote names the key"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       got [%s]\n' "1as a refused quote names the key" "$_g5_o"
fi

# L12: new routed metrics follow lexical full iface.id token order (2/10/100, two parents);
# persisted metrics never move.
call assign_route_metrics "" "enp1s0.2 enp1s0.10 enp1s0.100 enp2s0.2 enp2s0.10" 100
ok "1as route metrics: a new batch is in lexical full-token order, not numeric id order" \
	"enp1s0.10:100 enp1s0.100:101 enp1s0.2:102 enp2s0.10:103 enp2s0.2:104"
call assign_route_metrics "enp1s0.2:100 enp2s0.10:101" "enp1s0.10 enp1s0.100" 100
ok "1as route metrics: persisted assignments do not move when a batch is added" \
	"enp1s0.10:102 enp1s0.100:103 enp1s0.2:100 enp2s0.10:101"

# L11/L13: owned VLANs outside the current ignore/range policy are shown as such in status
# (static fields: present even when detection is unavailable), and a real mode keeps them.
_g5_status() { # unavailable?  -> do_status output
	(
		RESTART_ON_NEW_SUBNET=false DETECT_METHOD=both VLAN_MIN=2 VLAN_MAX=150 IGNORE_SET="100"
		SEEN_FILE="$_g5_dir/seen"
		DETECTED_TRUNKS="" DETECT_INVALID=""
		backend_owned_vlans() { printf '%s' "enp1s0.100 enp1s0.200 enp1s0.50"; }
		if [ "$1" = unavailable ]; then check_detect_deps() { return 1; }; else check_detect_deps() { return 0; }; fi
		run_detection() { DETECTED_TRUNKS="enp1s0"; return 0; }
		iface_tags() { printf '%s' "50 100 200"; }
		backend_list_managed_vlans() { return 0; }
		has_carrier() { return 0; }
		current_subnets() { printf '%s' ""; }
		do_status 2>&1
	)
}
_g5_o=$(_g5_status ok)
tests=$((tests + 1))
case "$_g5_o" in
*"owned-ignored=[100] owned-out-of-range=[200]"*) printf 'ok   - %s\n' "1as status row shows owned-ignored and owned-out-of-range" ;;
*)
	fails=$((fails + 1))
	printf 'FAIL - %s\n       got [%s]\n' "1as status row shows owned-ignored and owned-out-of-range" "$_g5_o"
	;;
esac
_g5_o=$(_g5_status unavailable)
tests=$((tests + 1))
case "$_g5_o" in
*"detected=[unavailable]"*"owned-ignored=[100] owned-out-of-range=[200]"*) printf 'ok   - %s\n' "1as the owned-policy fields print even when detection is unavailable" ;;
*)
	fails=$((fails + 1))
	printf 'FAIL - %s\n       got [%s]\n' "1as the owned-policy fields print even when detection is unavailable" "$_g5_o"
	;;
esac

# Composed real mode: an owned, still-detected VLAN that is now ignored, and another outside the
# narrowed range, stay in the target and are not proposed for removal (new-candidate suppression only).
_g5_o=$(
	RESET_ON_BOOT=true REMOVE_ON_CARRIER_LOSS=false RESTART_ON_NEW_SUBNET=false RESTART_SNAPS="" RESTART_SERVICES=""
	VLAN_MIN=2 VLAN_MAX=150 IGNORE_SET="100" VLAN_WARN=100 VLAN_LIMIT=0 VLAN_LIMIT_MODE=refuse VLAN_ROUTES=false
	PENDING_DELETE_FILE="$_g5_dir/pending" SEEN_FILE="$_g5_dir/seen"
	DETECTED_TRUNKS="enp1s0"
	run_detection() { return 0; }
	iface_tags() { printf '%s' "50 100 200"; }
	iface_valid() { printf '%s' valid; }
	backend_owned_vlans() { printf '%s' "enp1s0.100 enp1s0.200 enp1s0.50"; }
	have_routing() { return 0; }
	backend_list_managed_vlans() { return 0; }
	has_carrier() { return 0; }
	snapshot_default_route() { printf '%s' enp9s0; }
	backend_netplan_vlan_tokens() { printf '%s' ""; }
	current_subnets() { printf '%s' ""; }
	mktemp() { command mktemp -d "$_g5_dir/tree.XXXXXX"; }
	cp() { return 0; }
	backend_generate_config() { return 0; }
	backend_validate() { return 0; }
	do_dryrun 2>&1
)
tests=$((tests + 1))
if printf '%s\n' "$_g5_o" | grep -q '^  target:    \[enp1s0.100 enp1s0.200 enp1s0.50\]$' &&
	printf '%s\n' "$_g5_o" | grep -q '^  removals:  \[none\]' && printf '%s\n' "$_g5_o" | grep -q '^  additions: \[none\]'; then
	printf 'ok   - %s\n' "1as ignored and out-of-range owned VLANs stay in the target, with no removal or addition"
else
	fails=$((fails + 1))
	printf 'FAIL - %s\n       got [%s]\n' "1as ignored and out-of-range owned VLANs stay in the target" "$_g5_o"
fi

rm -rf "$_g5_dir"
unset -f _g5_load _g5_acc _g5_rej _g5_status
unset _g5_dir _g5_k _g5_lo _g5_below _g5_hi _g5_bad _g5_v _g5_o

# ---------------------------------------------------------------------------
# 1aq. Upgrade/systemd lifecycle (Group 2): the real maintainer scripts and install.sh
#      run as subprocesses; see tests/lifecycle.sh. Its counts are folded in here so
#      `bash tests/unit.sh` stays the single gate.
# ---------------------------------------------------------------------------

_lc_out=$(bash "${here}/lifecycle.sh" 2>&1)
_lc_rc=$?
printf '%s\n' "$_lc_out" | grep -v '^[0-9]* tests, [0-9]* failures$' | grep -v '^$'
_lc_sum=$(printf '%s\n' "$_lc_out" | grep '^[0-9]* tests, [0-9]* failures$' | tail -1)
_lc_t=${_lc_sum%% tests*}
_lc_f=${_lc_sum#*, }
_lc_f=${_lc_f%% failures*}
if [ -z "$_lc_sum" ]; then
	tests=$((tests + 1))
	fails=$((fails + 1))
	printf 'FAIL - %s\n       tests/lifecycle.sh produced no summary (rc=%s)\n' "1aq lifecycle suite ran to completion" "$_lc_rc"
else
	tests=$((tests + _lc_t))
	fails=$((fails + _lc_f))
fi
unset _lc_out _lc_rc _lc_sum _lc_t _lc_f

# ---------------------------------------------------------------------------

printf '\n%s tests, %s failures\n' "$tests" "$fails"
[ "$fails" -eq 0 ]
