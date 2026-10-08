#!/usr/bin/env bash
#
# Upgrade/systemd-lifecycle tests (Group 2): the REAL debian/{preinst,prerm,postinst,
# postrm} and install.sh run as subprocesses against a throwaway root, with command
# stubs for systemctl/flock/id/install. Run directly (`bash tests/lifecycle.sh`) or via
# tests/unit.sh, which folds this file's counts into its own.
#
# The scripts hardcode their /run, /etc, /lib paths. They are never given an environment
# override (they run as root); instead each test runs a copy with ONLY those literal
# path lines substituted, and every substitution is verified to have fired.
# LC_SRC may point at another checkout (used to show the tests fail against old scripts).

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${LC_SRC:-$here/..}"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
tests=0
fails=0
n=0
: >"$root/apt_all"

ok() { tests=$((tests + 1)); printf 'ok   - %s\n' "$1"; }
bad() { tests=$((tests + 1)); fails=$((fails + 1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
check() { # desc cmd...
	local desc="$1"
	shift
	if "$@"; then ok "$desc"; else bad "$desc" "rc=$rc out=[...$(printf '%s' "$out" | tr '\n' '|' | tail -c 700)] calls=[$(tr '\n' ',' <"$R/sc/calls" 2>/dev/null)]"; fi
}

mkdir -p "$root/bin"
cat >"$root/bin/systemctl" <<'STUB'
#!/bin/sh
sc=$LC_SC
echo "$*" >>"$sc/calls"
quiet=""
if [ "$2" = --quiet ]; then
	quiet=1
	cmd=$1
	shift 2
	set -- "$cmd" "$@"
fi
if [ -n "$quiet" ]; then exec >/dev/null; fi
case "$1" in
is-enabled)
	[ -n "$STUB_ENABLED_FAIL" ] && exit 1
	if [ "$(cat "$sc/en.$2" 2>/dev/null)" = 1 ]; then echo enabled; exit 0; fi
	echo disabled; exit 1 ;;
is-active)
	[ -n "$STUB_ACTIVE_FAIL" ] && exit 4
	if [ "$(cat "$sc/act" 2>/dev/null)" = 1 ]; then echo active; exit 0; fi
	echo inactive; exit 3 ;;
stop)
	[ -n "$STUB_STOP_FAIL" ] && exit 1
	[ -n "$STUB_STOP_NOOP" ] && exit 0
	echo 0 >"$sc/act" ;;
start)
	[ -n "$STUB_START_FAIL" ] && exit "${STUB_START_RC:-1}"
	echo 1 >"$sc/act" ;;
enable)
	[ -n "$STUB_ENABLE_FAIL" ] && exit 1
	echo 1 >"$sc/en.$2" ;;
disable)
	[ -n "$STUB_DISABLE_FAIL" ] && exit 1
	# Unit-specific failure AFTER partial work: the unit ends up disabled but the command reports failure.
	if [ -n "$STUB_DISABLE_FAIL_UNIT" ] && [ "$STUB_DISABLE_FAIL_UNIT" = "$2" ]; then echo 0 >"$sc/en.$2"; exit 1; fi
	[ -n "$STUB_DISABLE_NOOP" ] && exit 0
	echo 0 >"$sc/en.$2" ;;
daemon-reload) exit "${STUB_RELOAD_RC:-0}" ;;
esac
exit 0
STUB
cat >"$root/bin/flock" <<'STUB'
#!/bin/sh
echo "flock $*" >>"$LC_SC/calls"
[ -n "$STUB_FLOCK_FAIL" ] && exit 1
exit 0
STUB
printf '#!/bin/sh\necho 0\n' >"$root/bin/id"
# Dependency fixtures: install.sh only runs apt-get when tcpdump/lldpctl are missing. These
# make them present, and the apt-get stub is a tripwire so a host's real apt-get can never run.
printf '#!/bin/sh\nexit 0\n' >"$root/bin/tcpdump"
printf '#!/bin/sh\nexit 0\n' >"$root/bin/lldpctl"
cat >"$root/bin/apt-get" <<'STUB'
#!/bin/sh
echo "apt-get $*" >>"$LC_SC/apt_calls"
exit 99
STUB
cat >"$root/bin/dpkg" <<'STUB'
#!/bin/sh
# only `dpkg --compare-versions A lt B` is used by the scripts under test
[ "$1" = --compare-versions ] && [ "$3" = lt ] || exit 2
[ "$2" = "$4" ] && exit 1
[ "$(printf '%s\n%s\n' "$2" "$4" | sort -V | head -1)" = "$2" ]
STUB
cat >"$root/bin/rm" <<'STUB'
#!/bin/sh
# STUB_RM_FAIL makes removal of install.sh's mktemp'd build-stamp file (tmp.*) fail
if [ -n "$STUB_RM_FAIL" ]; then
	for a in "$@"; do
		case "$(basename "$a")" in tmp.*) [ -f "$a" ] && exit 1 ;; esac
	done
fi
exec /bin/rm "$@"
STUB
printf '#!/bin/sh\nexit 0\n' >"$root/bin/systemd-tmpfiles"
# Tripwires: the maintainer scripts must NEVER change the network. Any call is recorded and asserted empty at the end.
for _t in netplan ip; do
	printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 0\n' "$_t" "$root/forbidden_all" >"$root/bin/$_t"
done
: >"$root/forbidden_all"
cat >"$root/bin/install" <<'STUB'
#!/bin/sh
# install.sh passes -o root -g root; a non-root test run cannot chown, so drop them.
c=$#
i=0
while [ "$i" -lt "$c" ]; do
	a=$1
	shift
	i=$((i + 1))
	case "$a" in
	-o | -g) shift; i=$((i + 1)) ;;
	*) set -- "$@" "$a" ;;
	esac
done
exec /usr/bin/install "$@"
STUB
cat >"$root/bin/sed" <<'STUB'
#!/bin/sh
# GNU `sed -i` (the scripts' form) -> BSD `sed -i ''` on a macOS dev box.
if [ "$1" = -i ]; then
	shift
	/usr/bin/sed --version >/dev/null 2>&1 && exec /usr/bin/sed -i "$@"
	exec /usr/bin/sed -i '' "$@"
fi
exec /usr/bin/sed "$@"
STUB
chmod 755 "$root"/bin/*

# Fresh case tree + substituted script copies. Usage: _new
_new() {
	n=$((n + 1))
	R="$root/case.$n"
	mkdir -p "$R"/{run/dynavlan,run/systemd/system,etc/systemd/system,lib/systemd/system,etc/systemd/journald.conf.d,var/log/journal,usr/local/sbin,sc,src}
	export LC_SC="$R/sc"
	: >"$R/sc/calls"
	: >"$R/sc/apt_calls"
	unset STUB_ENABLED_FAIL STUB_ACTIVE_FAIL STUB_STOP_FAIL STUB_STOP_NOOP STUB_START_FAIL STUB_START_RC \
		STUB_ENABLE_FAIL STUB_RELOAD_RC STUB_FLOCK_FAIL STUB_RECONFIGURE_RC STUB_RM_FAIL STUB_DISABLE_FAIL STUB_DISABLE_NOOP STUB_DISABLE_FAIL_UNIT
	rc="" out=""
}

# _sub SCRIPT NAME=VALUE... : write $R/scripts/<base> with only those assignment lines changed.
_sub() {
	local script="$1" name val dst
	shift
	mkdir -p "$R/scripts"
	dst="$R/scripts/$(basename "$script")"
	cp "$SRC/$script" "$dst"
	for kv in "$@"; do
		name=${kv%%=*}
		val=${kv#*=}
		/usr/bin/sed -E -i.bak "s#^$name=(\"[^\"]*\"|[0-9]+)#$name=\"$val\"#" "$dst"
		if ! grep -qF "$name=\"$val\"" "$dst"; then
			echo "FATAL - $script: line $name= did not match; the test would exercise the real path" >&2
			exit 1
		fi
	done
	rm -f "$dst.bak"
	printf '%s\n' "$dst"
}

_maint() { # preinst|prerm|postinst|postrm -> substituted path
	local common=("STATE_FILE=$R/run/dynavlan/upgrade-state" "SYSTEMD_RUN=$R/run/systemd/system")
	case "$1" in
	preinst | prerm)
		_sub "debian/$1" "LOCK_FILE=$R/run/dynavlan.lock" "LOCK_WAIT=1" "STATE_DIR=$R/run/dynavlan" "${common[@]}" \
			"UNIT_ETC=$R/etc/systemd/system" "UNIT_LIB=$R/lib/systemd/system" ;;
	postinst)
		_sub "debian/postinst" "SBIN=$R/usr/local/sbin/dynavlan" "CONF=$R/etc/dynavlan.conf" \
			"JOURNALD_DIR=$R/etc/systemd/journald.conf.d" "JOURNAL_DIR=$R/var/log/journal" \
			"UNIT_ETC=$R/etc/systemd/system" "UNIT_LIB=$R/lib/systemd/system" "${common[@]}" ;;
	postrm)
		_sub "debian/postrm" "CONF=$R/etc/dynavlan.conf" "JOURNALD_DROPIN=$R/etc/systemd/journald.conf.d/00-dynavlan-persistent.conf" \
			"JOURNALD_DIR=$R/etc/systemd/journald.conf.d" "TIMER_DROPIN_DIR=$R/etc/systemd/system/dynavlan.timer.d" "${common[@]}" ;;
	esac
}

_run() { # script args... ; sets rc/out
	out=$(PATH="$root/bin:$PATH" bash "$@" 2>&1)
	rc=$?
	cat "$R/sc/apt_calls" >>"$root/apt_all" 2>/dev/null
}

# Run a hook as a child of a driver whose pid is appended to the existing record as its
# owner: the record is then a genuine handoff for this dpkg-run stand-in.
_run_owned() { # script args...
	out=$(PATH="$root/bin:$PATH" bash -c 'printf "owner=%s\n" "$$" >>"$1"; shift; bash "$@"' _ "$R/run/dynavlan/upgrade-state" "$@" 2>&1)
	rc=$?
}
# Run several hooks as siblings under ONE driver (one dpkg-run stand-in); stops at the first failure.
_run_seq() { # "script args" "script args" ...
	out=$(PATH="$root/bin:$PATH" bash -c 'for c in "$@"; do eval "bash $c" || exit $?; done' _ "$@" 2>&1)
	rc=$?
}
_apt_untouched() { [ ! -s "$root/apt_all" ]; }

_postinst_env() { # sets up a package-managed tree + a stub new binary
	_units lib
	printf '#!/bin/sh\nexit "${STUB_RECONFIGURE_RC:-0}"\n' >"$R/usr/local/sbin/dynavlan"
	chmod 755 "$R/usr/local/sbin/dynavlan"
}

# State helpers (the stub systemctl reads these files).
_state() { # SVC_ENABLED TMR_ENABLED TIMER_ACTIVE
	echo "$1" >"$R/sc/en.dynavlan.service"
	echo "$2" >"$R/sc/en.dynavlan.timer"
	echo "$3" >"$R/sc/act"
}
_units() { # etc|lib : create the three unit files there (etc = a manual install.sh deployment)
	local d="$R/$1/systemd/system" u
	for u in dynavlan.service dynavlan-rescan.service dynavlan.timer; do : >"$d/$u"; done
}
_record() { printf 'svc_enabled=%s\ntmr_enabled=%s\ntmr_active=%s\n' "$1" "$2" "$3" >"$R/run/dynavlan/upgrade-state"; }
_rec() { grep -v '^owner=' "$R/run/dynavlan/upgrade-state" 2>/dev/null | tr '\n' ' '; }
_called() { grep -q -- "$1" "$R/sc/calls"; }
_not_called() { ! grep -q -- "$1" "$R/sc/calls"; }
_has_record() { [ -f "$R/run/dynavlan/upgrade-state" ]; }
_no_record() { [ ! -f "$R/run/dynavlan/upgrade-state" ]; }
_rc0() { [ "$rc" -eq 0 ]; }
_rcnz() { [ "$rc" -ne 0 ]; }
_out_has() { printf '%s' "$out" | grep -qF -- "$1"; }
_timer_is() { [ "$(cat "$R/sc/act" 2>/dev/null)" = "$1" ]; }
_en_is() { [ "$(cat "$R/sc/en.$1" 2>/dev/null)" = "$2" ]; }

# ======================= preinst =======================
_new # fresh install: nothing to capture or stop, but the run lock is still waited for
p=$(_maint preinst)
_run "$p" install
check "preinst fresh install succeeds" _rc0
check "preinst fresh install records nothing" _no_record
check "preinst fresh install stops nothing" _not_called "stop"
check "preinst fresh install still waits for the run lock" _called "flock -w"

_new # manual (install.sh) deployment, enabled + active -> record 1/1/1, timer quiesced
_units etc
_state 1 1 1
p=$(_maint preinst)
_run "$p" install
check "preinst migration over install.sh succeeds" _rc0
check "preinst migration records the manual posture" test "$(_rec)" = "svc_enabled=1 tmr_enabled=1 tmr_active=1 "
check "preinst migration stops the timer and verifies it" _timer_is 0

_new # enablement preserved independently; enabled-but-inactive stays inactive
_units etc
_state 0 1 0
p=$(_maint preinst)
_run "$p" install
check "preinst records service disabled / timer enabled independently" test "$(_rec)" = "svc_enabled=0 tmr_enabled=1 tmr_active=0 "
check "preinst never starts or stops an inactive timer" _not_called "^start"
check "preinst does not stop an already-inactive timer" _not_called "stop"

_new # valid record from the outgoing prerm is reused, not recaptured as inactive
_units lib
_state 1 1 0 # the outgoing prerm already stopped the timer
_record 1 1 1
p=$(_maint preinst)
_run "$p" upgrade 0.4.15
check "preinst upgrade reuses a valid record" test "$(_rec)" = "svc_enabled=1 tmr_enabled=1 tmr_active=1 "
check "preinst upgrade verified the (already stopped) timer, not recaptured" _rc0

_new # enabled-but-inactive record from the outgoing prerm must stay inactive, not be re-inferred as running
_units lib
_state 1 1 0
_record 1 1 0
p=$(_maint preinst)
_run "$p" upgrade 0.4.15
check "preinst keeps an enabled-but-inactive record inactive (no re-inference)" test "$(_rec)" = "svc_enabled=1 tmr_enabled=1 tmr_active=0 "
check "preinst does not stop a timer the record says was inactive" _not_called "^stop"

_new # a record-producing outgoing package (0.4.15) left no record: never estimate, say it is unknown
_units lib
_state 1 1 0
p=$(_maint preinst)
_run "$p" upgrade 0.4.15
check "preinst upgrade from a record-producing version records only what is observed" test "$(_rec)" = "svc_enabled=1 tmr_enabled=1 tmr_active=0 "
check "preinst upgrade from a record-producing version says the run state is unknown" _out_has "UNKNOWN"
check "preinst upgrade from a record-producing version does not estimate" bash -c "! printf '%s' \"\$1\" | grep -q ESTIMATING" _ "$out"

_new # a genuinely legacy outgoing package never wrote a record: the accepted estimate, labelled as one
_units lib
_state 1 1 0
p=$(_maint preinst)
_run "$p" upgrade 0.4.0
check "preinst legacy (0.4.0) upgrade estimates the run state from enablement" test "$(_rec)" = "svc_enabled=1 tmr_enabled=1 tmr_active=1 "
check "preinst legacy (0.4.0) upgrade labels the estimate as an estimate" _out_has "ESTIMATING"

_new # 0.4.1 is the first record-producing package: never estimated
_units lib
_state 1 1 0
p=$(_maint preinst)
_run "$p" upgrade 0.4.1
check "preinst treats 0.4.1 as record-producing (observed, unknown, no estimate)" test "$(_rec)" = "svc_enabled=1 tmr_enabled=1 tmr_active=0 "
check "preinst 0.4.1 upgrade does not estimate" bash -c "! printf '%s' \"\$1\" | grep -q ESTIMATING" _ "$out"

_new # a partial record from a record-producing version is replaced by observation, not an estimate
_units lib
_state 1 1 0
printf 'svc_enabled=1\ntmr_enabled=1\n' >"$R/run/dynavlan/upgrade-state"
p=$(_maint preinst)
_run "$p" upgrade 0.4.15
check "preinst replaces a partial record by an observed one (no estimate)" test "$(_rec)" = "svc_enabled=1 tmr_enabled=1 tmr_active=0 "

# ---- HIGH: quiescence comes from the live state, never from the saved posture
_new # ownerless record says inactive but the timer is ACTIVE: current posture wins, timer is stopped
_units lib
_state 1 1 1
_record 1 1 0
p=$(_maint preinst)
_run "$p" upgrade 0.4.15
check "preinst stops a live-active timer even though a stale record says inactive" _timer_is 0
check "preinst succeeds after quiescing it" _rc0
check "preinst replaces the contradicted record by the current posture" test "$(_rec)" = "svc_enabled=1 tmr_enabled=1 tmr_active=1 "

_new # a genuine handoff (owner = this run) saying inactive, with a live-active timer: still quiesced
_units lib
_state 1 1 1
_record 1 1 0
p=$(_maint preinst)
_run_owned "$p" upgrade 0.4.15
check "preinst quiesces a live-active timer even for a genuine handoff record" _timer_is 0

_new # an unrelated stale record (different owner) must not override the current posture
_units lib
_state 1 1 0 # the operator deliberately stopped the timer
_record 1 1 1
printf 'owner=999999\n' >>"$R/run/dynavlan/upgrade-state"
p=$(_maint preinst)
_run "$p" upgrade 0.4.15
check "preinst discards a stale record from another run" test "$(_rec)" = "svc_enabled=1 tmr_enabled=1 tmr_active=0 "
check "preinst never restarts a timer the operator had stopped (stale record ignored)" _not_called "^start"

_new # Codex repro 1a: an ownerless STALE record must not be reused when units are disabled and the timer inactive
_postinst_env
_state 0 0 0
_record 1 1 1
p1=$(_maint preinst)
p2=$(_maint postinst)
_run_seq "$p1 upgrade 0.4.15" "$p2 configure 0.4.15"
check "stale ownerless record: the current posture is captured instead (disabled/inactive)" test "$(_rec)" = ""
check "stale ownerless record: an upgrade does not enable the disabled units" _en_is dynavlan.service 0
check "stale ownerless record: an upgrade does not start the inactive timer" _not_called "^start"

_new # Codex repro 1b: the same stale record during a manual -> package registration (no outgoing hook exists)
_units etc
_state 0 0 0
_record 1 1 1
p1=$(_maint preinst)
_run "$p1" install
check "stale ownerless record is discarded on a manual registration" test "$(_rec)" = "svc_enabled=0 tmr_enabled=0 tmr_active=0 "
_postinst_env
_state 0 0 0
p2=$(_maint postinst)
_run "$p2" configure
check "manual registration with a stale record leaves disabled units disabled and the timer stopped" bash -c "[ \"$(cat "$R/sc/en.dynavlan.timer")\" = 0 ] && ! grep -q '^start' '$R/sc/calls'"

_new # Codex repro 2: the REAL 0.4.15 prerm wrote a fresh ownerless record; a stale owner from an unrelated run must not matter
_units lib
_state 1 1 1
_record 1 1 0
printf 'owner=999999\n' >>"$R/run/dynavlan/upgrade-state"
old=$(_sub tests/fixtures/prerm-0.4.15 "LOCK_FILE=$R/run/dynavlan.lock" "LOCK_WAIT=1" "STATE_DIR=$R/run/dynavlan" "STATE_FILE=$R/run/dynavlan/upgrade-state")
_run "$old" upgrade 0.4.16
check "the real 0.4.15 prerm ran, recorded the active timer and stopped it" test "$(_rec)" = "svc_enabled=1 tmr_enabled=1 tmr_active=1 "
check "(0.4.15 prerm left the timer stopped)" _timer_is 0
p=$(_maint preinst)
_run "$p" upgrade 0.4.15
check "preinst accepts the genuine 0.4.15 record (prior-active is kept)" test "$(_rec)" = "svc_enabled=1 tmr_enabled=1 tmr_active=1 "
_postinst_env
p2=$(_maint postinst)
_run "$p2" configure 0.4.15
check "the prior-active timer is restored after the real 0.4.15 prerm" _timer_is 1

_new # an ownerless record from a version newer than the owner-less era is never trusted
_units lib
_state 1 1 0
_record 1 1 1
p=$(_maint preinst)
_run "$p" upgrade 0.4.16
check "preinst ignores an ownerless record when the outgoing package already writes owners" test "$(_rec)" = "svc_enabled=1 tmr_enabled=1 tmr_active=0 "

_new # prerm -> preinst in ONE run: the handoff survives the timer having been stopped in between
_units lib
_state 1 1 1
p1=$(_maint prerm)
p2=$(_maint preinst)
_run_seq "$p1 upgrade 0.4.16" "$p2 upgrade 0.4.15"
check "prerm then preinst in one run succeed" _rc0
check "preinst reuses the prerm's record (does not recapture the stopped timer as inactive)" test "$(_rec)" = "svc_enabled=1 tmr_enabled=1 tmr_active=1 "
check "the timer stays stopped through the swap" _timer_is 0

_new # successful stop command but the timer is still active -> abort before replacement
_units etc
_state 1 1 1
export STUB_STOP_NOOP=1
p=$(_maint preinst)
_run "$p" install
check "preinst aborts when the timer is still active after a successful stop" _rcnz
check "preinst abort leaves no record behind" _no_record

_new # stop failure
_units etc
_state 1 1 1
export STUB_STOP_FAIL=1
p=$(_maint preinst)
_run "$p" install
check "preinst aborts when the timer cannot be stopped" _rcnz

_new # unavailable timer state is not "inactive"
_units etc
_state 1 1 1
export STUB_ACTIVE_FAIL=1
p=$(_maint preinst)
_run "$p" install
check "preinst aborts when the timer state cannot be determined" _rcnz
check "preinst stops nothing when it cannot capture" _not_called "stop"

_new # absent timer + held lock: the lock wait is not skipped
export STUB_FLOCK_FAIL=1
p=$(_maint preinst)
_run "$p" install
check "preinst with no timer still aborts on a held run lock" _rcnz
check "preinst held-lock abort names the lock" _out_has "holds"

_new # abort after stopping the timer, and the restart fails: the record must be kept
_units etc
_state 1 1 1
export STUB_FLOCK_FAIL=1 STUB_START_FAIL=1
p=$(_maint preinst)
_run "$p" install
check "preinst abort with a failed timer restore keeps the record" _has_record
check "preinst abort with a failed timer restore fails" _rcnz
check "preinst abort with a failed timer restore tells the operator" _out_has "start it manually"

_new # abort with a successful restore discards the record
_units etc
_state 1 1 1
export STUB_FLOCK_FAIL=1
p=$(_maint preinst)
_run "$p" install
check "preinst abort with a successful restore discards the record" _no_record
check "preinst abort restores the timer it stopped" _timer_is 1

_new # chroot/container: systemd absent skips systemd work only
rmdir "$R/run/systemd/system"
_units etc
p=$(_maint preinst)
_run "$p" install
check "preinst without systemd succeeds" _rc0
check "preinst without systemd makes no systemctl calls" _not_called "is-"
check "preinst without systemd still waits for the run lock" _called "flock -w"

# ======================= prerm =======================
_new # remove: unchanged behaviour (stop, wait, restore on a held lock)
_units lib
_state 1 1 1
export STUB_FLOCK_FAIL=1
p=$(_maint prerm)
_run "$p" remove
check "prerm remove with a held lock aborts" _rcnz
check "prerm remove restores a previously active timer on abort" _timer_is 1

_new # upgrade: captures, stops, verifies
_units lib
_state 1 1 1
p=$(_maint prerm)
_run "$p" upgrade 0.4.16
check "prerm upgrade succeeds" _rc0
check "prerm upgrade records the prior posture" test "$(_rec)" = "svc_enabled=1 tmr_enabled=1 tmr_active=1 "
check "prerm upgrade stops the timer" _timer_is 0

_new # failed-upgrade must not silently bypass quiescence (held lock)
_units lib
_state 1 1 1
export STUB_FLOCK_FAIL=1
p=$(_maint prerm)
_run "$p" failed-upgrade 0.4.15
check "prerm failed-upgrade aborts on a held run lock" _rcnz
check "prerm failed-upgrade abort restores the active timer" _timer_is 1

_new # failed-upgrade with a stop failure
_units lib
_state 1 1 1
export STUB_STOP_FAIL=1
p=$(_maint prerm)
_run "$p" failed-upgrade 0.4.15
check "prerm failed-upgrade aborts when the timer cannot be stopped" _rcnz

_new # failed-upgrade quiesces like upgrade
_units lib
_state 1 1 1
p=$(_maint prerm)
_run "$p" failed-upgrade 0.4.15
check "prerm failed-upgrade quiesces the timer" _timer_is 0

_new # stop 'succeeds' but timer stays active
_units lib
_state 1 1 1
export STUB_STOP_NOOP=1
p=$(_maint prerm)
_run "$p" upgrade 0.4.16
check "prerm upgrade aborts when the timer is still active after stop" _rcnz

_new # HIGH: a record saying inactive must not let prerm skip stopping a live-active timer
_units lib
_state 1 1 1
_record 1 1 0
p=$(_maint prerm)
_run "$p" upgrade 0.4.16
check "prerm upgrade stops a live-active timer despite a stale inactive record" _timer_is 0
check "prerm upgrade succeeds after quiescing it" _rc0

_new # a genuine handoff saying inactive, live-active timer: still stopped
_units lib
_state 1 1 1
_record 1 1 0
p=$(_maint prerm)
_run_owned "$p" failed-upgrade 0.4.15
check "prerm failed-upgrade quiesces a live-active timer even for a handoff record" _timer_is 0

# ---- MEDIUM: a failed restoration keeps the record and is reported
_new
_units lib
_state 1 1 1
export STUB_FLOCK_FAIL=1 STUB_START_FAIL=1
p=$(_maint prerm)
_run "$p" upgrade 0.4.16
check "prerm abort with a failed timer restore keeps the record" _has_record
check "prerm abort with a failed timer restore reports the failure" _rcnz
check "prerm abort with a failed timer restore tells the operator" _out_has "start it manually"


# ---- Group 6 (D7): remove / purge
_new # remove, enabled + active: quiesce, then disable both enableable units; the static rescan service is never "disabled"
_units lib
_state 1 1 1
p=$(_maint prerm)
_run "$p" remove
check "prerm remove (enabled+active) succeeds" _rc0
check "prerm remove leaves the timer inactive" _timer_is 0
check "prerm remove leaves dynavlan.timer disabled" _en_is dynavlan.timer 0
check "prerm remove leaves dynavlan.service disabled" _en_is dynavlan.service 0
check "prerm remove never uses disable --now" _not_called "disable --now"
check "prerm remove never touches the static rescan service" _not_called "dynavlan-rescan"
check "prerm remove stops the timer BEFORE disabling it" bash -c "s=\$(grep -n '^stop' '$R/sc/calls' | head -1 | cut -d: -f1); d=\$(grep -n '^disable' '$R/sc/calls' | head -1 | cut -d: -f1); [ -n \"\$s\" ] && [ -n \"\$d\" ] && [ \"\$s\" -lt \"\$d\" ]"

_new # remove, already disabled + inactive
_units lib
_state 0 0 0
p=$(_maint prerm)
_run "$p" remove
check "prerm remove (already disabled+inactive) succeeds" _rc0
check "prerm remove (already disabled+inactive) stays disabled" _en_is dynavlan.timer 0
check "prerm remove (already disabled+inactive) never starts anything" _not_called "^start"

_new # timer stop fails: abort before any disable
_units lib
_state 1 1 1
export STUB_STOP_FAIL=1
p=$(_maint prerm)
_run "$p" remove
check "prerm remove aborts when the timer cannot be stopped" _rcnz
check "prerm remove does not disable anything after a failed stop" _not_called "^disable"

_new # stop reports success but the timer stays active: abort, restore
_units lib
_state 1 1 1
export STUB_STOP_NOOP=1
p=$(_maint prerm)
_run "$p" remove
check "prerm remove aborts when the timer is still active after stop" _rcnz
check "prerm remove does not disable after a failed verification" _not_called "^disable"

_new # is-active indeterminate: refuse before touching anything
_units lib
_state 1 1 1
export STUB_ACTIVE_FAIL=1
p=$(_maint prerm)
_run "$p" remove
check "prerm remove aborts when the timer state cannot be determined" _rcnz
check "prerm remove stops/disables nothing when the state is unknown" bash -c "! grep -q '^stop\\|^disable' '$R/sc/calls'"

_new # disable fails after quiescence: fail loudly, put the timer back, re-enable what was disabled
_units lib
_state 1 1 1
export STUB_DISABLE_FAIL=1
p=$(_maint prerm)
_run "$p" remove
check "prerm remove fails when disable fails" _rcnz
check "prerm remove restarts the previously active timer after a failed disable" _timer_is 1

_new # disable silently does nothing: the verification must catch the stale enablement
_units lib
_state 1 1 1
export STUB_DISABLE_NOOP=1
p=$(_maint prerm)
_run "$p" remove
check "prerm remove does not report success with a stale enabled unit" _rcnz
check "prerm remove restores the timer when the post-disable verification fails" _timer_is 1

_new # indeterminate initial enablement refuses before anything is stopped or disabled
_units lib
_state 1 1 1
export STUB_ENABLED_FAIL=1
p=$(_maint prerm)
_run "$p" remove
check "prerm remove refuses when a unit's enablement cannot be determined" _rcnz
check "prerm remove stops and disables nothing when enablement is unknown" bash -c "! grep -q '^stop\\|^disable' '$R/sc/calls'"

_new # timer was disabled, service enabled; the SERVICE disable fails: rollback must restore the captured posture, not the command results
_units lib
_state 1 0 0
export STUB_DISABLE_FAIL_UNIT=dynavlan.service
p=$(_maint prerm)
_run "$p" remove
check "prerm remove fails when the service disable fails" _rcnz
check "prerm remove rollback never enables the timer that was disabled before" _en_is dynavlan.timer 0
check "prerm remove rollback re-enables the service whose disable failed" _en_is dynavlan.service 1

_new # both enabled and active; the second disable fails after partial work: both end enabled and the timer is restarted
_units lib
_state 1 1 1
export STUB_DISABLE_FAIL_UNIT=dynavlan.service
p=$(_maint prerm)
_run "$p" remove
check "prerm remove rollback leaves the timer enabled" _en_is dynavlan.timer 1
check "prerm remove rollback leaves the service enabled" _en_is dynavlan.service 1
check "prerm remove rollback restarts the previously active timer" _timer_is 1

_new # held lock plus failing restart: exact original status (1), reported
_units lib
_state 1 1 1
export STUB_FLOCK_FAIL=1 STUB_START_FAIL=1
p=$(_maint prerm)
_run "$p" remove
check "prerm remove with a held lock and a failed restart still fails with status 1" test "$rc" -eq 1
check "prerm remove tells the operator the timer could not be restarted" _out_has "start it manually"

_new # no systemd (chroot/container): nothing systemd-specific is attempted, the lock is still waited for
rmdir "$R/run/systemd/system"
_units lib
p=$(_maint prerm)
_run "$p" remove
check "prerm remove without systemd succeeds" _rc0
check "prerm remove without systemd makes no systemctl calls" _not_called "is-"
check "prerm remove without systemd still waits for the run lock" _called "flock -w"

_new # postrm remove keeps the configuration-like state; purge removes it, rmdir only when empty
mkdir -p "$R/etc/systemd/system/dynavlan.timer.d"
: >"$R/etc/dynavlan.conf"; : >"$R/etc/systemd/journald.conf.d/00-dynavlan-persistent.conf"
: >"$R/etc/systemd/system/dynavlan.timer.d/interval.conf"
p=$(_maint postrm)
_run "$p" remove
check "postrm remove keeps /etc/dynavlan.conf" test -e "$R/etc/dynavlan.conf"
check "postrm remove keeps the generated timer drop-in" test -e "$R/etc/systemd/system/dynavlan.timer.d/interval.conf"
_run "$p" purge
check "postrm purge removes the conffile" test ! -e "$R/etc/dynavlan.conf"
check "postrm purge removes the journald drop-in" test ! -e "$R/etc/systemd/journald.conf.d/00-dynavlan-persistent.conf"
check "postrm purge removes the generated timer drop-in" test ! -e "$R/etc/systemd/system/dynavlan.timer.d/interval.conf"
check "postrm purge removes the now-empty timer.d directory" test ! -d "$R/etc/systemd/system/dynavlan.timer.d"

_new # purge must not recursively delete a directory that holds something else
mkdir -p "$R/etc/systemd/system/dynavlan.timer.d"
: >"$R/etc/systemd/system/dynavlan.timer.d/interval.conf"; echo keep >"$R/etc/systemd/system/dynavlan.timer.d/operator.conf"
p=$(_maint postrm)
_run "$p" purge
check "postrm purge succeeds with a foreign file in timer.d" _rc0
check "postrm purge preserves a foreign file in timer.d" test -e "$R/etc/systemd/system/dynavlan.timer.d/operator.conf"
check "postrm purge still removes interval.conf" test ! -e "$R/etc/systemd/system/dynavlan.timer.d/interval.conf"

# Tripwire: no maintainer script above (or in this file) ever invoked netplan or ip.
check "no maintainer script called netplan or ip (never changes the network)" bash -c "[ ! -s '$root/forbidden_all' ]"

# ======================= postinst =======================

_new # first install: enable both, never start, no record
_postinst_env
rm -f "$R/lib/systemd/system/"* ; _units lib
_state 0 0 0
p=$(_maint postinst)
_run "$p" configure
check "postinst first install succeeds" _rc0
check "postinst first install enables both units" bash -c "[ \"$(cat "$R/sc/en.dynavlan.service")\" = 1 ] && [ \"$(cat "$R/sc/en.dynavlan.timer")\" = 1 ]"
check "postinst first install never starts the timer" _not_called "^start"

_new # upgrade, enabled + active
_postinst_env
_state 0 0 0
_record 1 1 1
p=$(_maint postinst)
_run "$p" configure 0.4.15
check "postinst upgrade restores enablement and the active timer" bash -c "[ \"$(cat "$R/sc/act")\" = 1 ]"
check "postinst upgrade removes the record on success" _no_record

_new # enabled-but-inactive stays inactive; units independent
_postinst_env
_state 0 0 0
_record 0 1 0
p=$(_maint postinst)
_run "$p" configure 0.4.15
check "postinst keeps a disabled service disabled" _en_is dynavlan.service 0
check "postinst enables the timer that was enabled" _en_is dynavlan.timer 1
check "postinst never starts a timer that was inactive" _not_called "^start"

_new # failure then retry, enabled-but-inactive: record retained, still inactive after the retry
_postinst_env
_state 1 1 0
_record 1 1 0
export STUB_RECONFIGURE_RC=7
p=$(_maint postinst)
_run "$p" configure 0.4.15
check "postinst reports the original reconfigure failure status" test "$rc" -eq 7
check "postinst failure retains the prior-state record" _has_record
check "postinst failure says it is not a rollback" _out_has "NOT a rollback"
check "postinst failure does not start a previously inactive timer" _not_called "^start"
unset STUB_RECONFIGURE_RC
_run "$p" configure 0.4.15
check "postinst retry succeeds from the retained record" _rc0
check "postinst retry keeps the enabled-but-inactive timer inactive" _not_called "^start"
check "postinst retry removes the record once configured" _no_record

_new # reload failure after a stop: previously active timer is put back, status preserved
_postinst_env
_state 1 1 0
_record 1 1 1
export STUB_RELOAD_RC=5
p=$(_maint postinst)
_run "$p" configure 0.4.15
check "postinst keeps the daemon-reload failure status" test "$rc" -eq 5
check "postinst attempts to restore a previously active timer after failure" _timer_is 1
check "postinst retains the record across a failed configuration" _has_record

_new # restart failure of a previously active timer: still the original failure is reported
_postinst_env
_state 1 1 0
_record 1 1 1
export STUB_START_FAIL=1 STUB_START_RC=9
p=$(_maint postinst)
_run "$p" configure 0.4.15
check "postinst timer-start failure fails the configure" _rcnz
check "postinst timer-start failure keeps the record" _has_record

_new # a record with extra content is never sourced
_postinst_env
_state 1 1 0
printf 'svc_enabled=1\ntmr_enabled=1\ntmr_active=1\ntouch %s/pwned\n' "$R" >"$R/run/dynavlan/upgrade-state"
p=$(_maint postinst)
_run "$p" configure 0.4.15
check "postinst never executes content in an invalid record" test ! -e "$R/pwned"

_new # upgrade with no record: nothing is invented
_postinst_env
_state 0 0 0
p=$(_maint postinst)
_run "$p" configure 0.4.15
check "postinst upgrade without a record changes no enablement" _not_called "enable"
check "postinst upgrade without a record starts nothing" _not_called "^start"
check "postinst upgrade without a record says so" _out_has "no prior-state record"

_new # L15: PER_VLAN_MAC neutralized; stock config untouched
_postinst_env
_state 0 0 0
printf 'RESCAN_MINUTES=5\nPER_VLAN_MAC=false\n' >"$R/etc/dynavlan.conf"
p=$(_maint postinst)
_run "$p" configure
check "postinst neutralizes an uncommented PER_VLAN_MAC" bash -c "! grep -q '^PER_VLAN_MAC' '$R/etc/dynavlan.conf'"
printf '# PER_VLAN_MAC=false\nRESCAN_MINUTES=5\n' >"$R/etc/dynavlan.conf"
cp "$R/etc/dynavlan.conf" "$R/conf.before"
_run "$p" configure
check "postinst leaves a stock (commented) config unchanged" cmp -s "$R/etc/dynavlan.conf" "$R/conf.before"

# ======================= postrm =======================
_new
_postinst_env
_state 1 1 0
_record 1 1 1
p=$(_maint postrm)
_run "$p" abort-upgrade 0.4.15
check "postrm abort-upgrade restores a previously active timer" _timer_is 1
check "postrm abort-upgrade discards the record" _no_record

_new
_postinst_env
_state 1 1 0
_record 1 1 0
p=$(_maint postrm)
_run "$p" abort-install
check "postrm abort-install never starts a previously inactive timer" _not_called "^start"

check "postrm abort-install discards the record" _no_record

_new # restoration failure: reported, record kept, NOT a success
_postinst_env
_state 1 1 0
_record 1 1 1
export STUB_START_FAIL=1
p=$(_maint postrm)
_run "$p" abort-install
check "postrm abort-install fails when the timer cannot be restarted" _rcnz
check "postrm abort-install keeps the record when the restore fails" _has_record
check "postrm abort-install tells the operator" _out_has "start it manually"

_new
_postinst_env
p=$(_maint postrm)
_run "$p" remove
check "postrm remove only reloads systemd (unchanged)" test "$(tr '\n' ',' <"$R/sc/calls")" = "daemon-reload,"

# ======================= install.sh =======================
_inst_env() { # a source dir with the files install.sh requires, and a stub new binary
	local f
	for f in dynavlan.conf dynavlan.service dynavlan-rescan.service dynavlan.timer; do cp "$SRC/$f" "$R/src/$f"; done
	cp "$SRC/install.sh" "$R/src/install.sh.orig"
	cat >"$R/src/dynavlan" <<'EOS'
#!/bin/bash
build="source"
if [ "$1" = --reconfigure ]; then
	# a not-yet-neutralized PER_VLAN_MAC would refuse the config load here
	if [ -f "$LC_CONF" ] && grep -q '^PER_VLAN_MAC' "$LC_CONF"; then exit 9; fi
	exit "${STUB_RECONFIGURE_RC:-0}"
fi
exit 0
EOS
	export LC_CONF="$R/etc/dynavlan.conf"
}
_inst() { # sets i to the substituted copy placed inside the fake source dir
	local base
	base=$(_sub install.sh "SBIN=$R/usr/local/sbin/dynavlan" "CONF=$R/etc/dynavlan.conf" "UNIT_DIR=$R/etc/systemd/system" \
		"JOURNALD_DROPIN=$R/etc/systemd/journald.conf.d/00-dynavlan-persistent.conf" "LOCK_FILE=$R/run/dynavlan.lock" \
		"LOCK_WAIT=1" "SYSTEMD_RUN=$R/run/systemd/system" "UNIT_LIB=$R/lib/systemd/system" "JOURNAL_DIR=$R/var/log/journal")
	cp "$base" "$R/src/install.sh"
	i="$R/src/install.sh"
}

_new # first install: enable by default, never start
_inst_env
_inst
_state 0 0 0
_run "$i"
check "install.sh first install succeeds" _rc0
check "install.sh first install enables both units" bash -c "[ \"$(cat "$R/sc/en.dynavlan.service")\" = 1 ] && [ \"$(cat "$R/sc/en.dynavlan.timer")\" = 1 ]"
check "install.sh first install never starts the timer" _not_called "^start"

_new # upgrade: enabled + active -> stopped, replaced, enabled, restarted
_inst_env
_inst
_units etc
_state 1 1 1
_run "$i"
check "install.sh upgrade succeeds" _rc0
check "install.sh upgrade leaves the timer running again" _timer_is 1
check "install.sh upgrade stopped it first" bash -c "grep -n '^stop' '$R/sc/calls' | head -1 | cut -d: -f1 | grep -q ."

_new # deliberately disabled units are not re-armed
_inst_env
_inst
_units etc
_state 0 0 0
_run "$i"
check "install.sh upgrade keeps a disabled service disabled" _en_is dynavlan.service 0
check "install.sh upgrade keeps a disabled timer disabled" _en_is dynavlan.timer 0
check "install.sh upgrade never starts an inactive timer" _not_called "^start"

_new # enabled-but-inactive stays inactive; units independent
_inst_env
_inst
_units etc
_state 0 1 0
_run "$i"
check "install.sh keeps the service disabled and enables only the timer" bash -c "[ \"$(cat "$R/sc/en.dynavlan.service")\" = 0 ] && [ \"$(cat "$R/sc/en.dynavlan.timer")\" = 1 ]"
check "install.sh enabled-but-inactive timer stays inactive" _not_called "^start"

_new # a successful stop command with the timer still active aborts BEFORE replacement
_inst_env
_inst
_units etc
_state 1 1 1
export STUB_STOP_NOOP=1
_run "$i"
check "install.sh aborts when the timer is still active after stop" _rcnz
check "install.sh abort happened before the script was replaced" test ! -e "$R/usr/local/sbin/dynavlan"

_new # state capture failure aborts before anything is touched
_inst_env
_inst
_units etc
_state 1 1 1
export STUB_ENABLED_FAIL=1
_run "$i"
check "install.sh aborts when the unit state cannot be captured" _rcnz
check "install.sh capture failure stops nothing" _not_called "stop"

_new # body failure and restore failure together: the EXACT original status wins
_inst_env
_inst
_units etc
_state 1 1 1
export STUB_RECONFIGURE_RC=7 STUB_START_FAIL=1
_run "$i"
check "install.sh keeps the exact body failure status when restoration also fails" test "$rc" -eq 7

_new # MEDIUM: a failed temp-file removal in the exit handler must not skip the restore or change the status
_inst_env
_inst
_units etc
_state 1 1 1
export STUB_RECONFIGURE_RC=7 STUB_RM_FAIL=1
_run "$i"
check "install.sh keeps the exact body status when temp-file removal fails" test "$rc" -eq 7
check "install.sh still restores the timer when temp-file removal fails" _timer_is 1
check "install.sh warns that the temp file could not be removed" _out_has "could not remove the temporary file"

_new # body failure alone: exact status, timer restored
_inst_env
_inst
_units etc
_state 1 1 1
export STUB_RECONFIGURE_RC=7
_run "$i"
check "install.sh body failure keeps its exact status" test "$rc" -eq 7
check "install.sh body failure restores the previously active timer" _timer_is 1

_new # body success but the timer cannot be restarted: a failed upgrade, not success
_inst_env
_inst
_units etc
_state 1 1 1
export STUB_START_FAIL=1
_run "$i"
check "install.sh fails when a previously active timer cannot be restarted" _rcnz
check "install.sh does not announce success then" bash -c "! printf '%s' \"\$1\" | grep -q '\\[install\\] done'" _ "$out"

_new # L15: the old PER_VLAN_MAC line is neutralized before the new binary loads the config
_inst_env
_inst
_state 0 0 0
printf 'RESCAN_MINUTES=5\nPER_VLAN_MAC=false\n' >"$R/etc/dynavlan.conf"
_run "$i"
check "install.sh neutralizes an old PER_VLAN_MAC before --reconfigure" _rc0

_new # D10: a failed daemon-reload fails the install and still restores the timer
_inst_env
_inst
_units etc
_state 1 1 1
export STUB_RELOAD_RC=5
_run "$i"
check "install.sh fails when daemon-reload fails" _rcnz
check "install.sh restores the timer after a reload failure" _timer_is 1

# Isolation tripwire: the dependency fixtures keep install.sh off apt-get for every case above.
check "no install.sh run in this file reached apt-get (dependency fixtures hold)" _apt_untouched

printf '\n%s tests, %s failures\n' "$tests" "$fails"
[ "$fails" -eq 0 ]
