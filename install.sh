#!/usr/bin/env bash
#
# install.sh - install dynavlan on an Ubuntu (netplan/systemd-networkd) appliance.
#
# Places the script, config template, and systemd units; installs the sniff/LLDP
# dependencies; guarantees persistent journald (FR-31); renders the timer interval;
# and enables the boot service + rescan timer. It does NOT run --boot itself: apply
# is left to the operator (preview with --dry-run first) or the next reboot, so the
# install never triggers a surprise network change.
#
# Run as root from the repo directory: sudo ./install.sh

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SBIN="/usr/local/sbin/dynavlan"
CONF="/etc/dynavlan.conf"
UNIT_DIR="/etc/systemd/system"
JOURNALD_DROPIN="/etc/systemd/journald.conf.d/00-dynavlan-persistent.conf"
LOCK_FILE="/run/dynavlan.lock"   # FR-30: the same lock dynavlan runs hold
LOCK_WAIT=300                    # a rescan can legitimately run for minutes (sniff + try window + leases)

TIMER_WAS_ACTIVE=0

say() { printf '[install] %s\n' "$*"; }
die() {
	printf '[install] ERROR: %s\n' "$*" >&2
	exit 1
}

# Runs on every exit path, including die: never leave the box with rescans
# silently switched off because the install aborted halfway.
#
# ONE cleanup handler, installed once. bash keeps a single EXIT trap, so a second
# `trap ... EXIT` anywhere below would silently REPLACE this one and take the
# timer restore with it - a stopped rescan timer being precisely the failure this
# exists to prevent. Anything else needing cleanup goes in here, not in a new trap.
STAMPED=""
cleanup() {
	[ -n "$STAMPED" ] && rm -f "$STAMPED"
	if [ "$TIMER_WAS_ACTIVE" -eq 1 ]; then
		say "restarting dynavlan.timer"
		systemctl start dynavlan.timer ||
			printf '[install] ERROR: could not restart dynavlan.timer; start it manually\n' >&2
	fi
	return 0
}
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

for f in dynavlan dynavlan.conf dynavlan.service dynavlan-rescan.service dynavlan.timer; do
	[ -f "$SRC_DIR/$f" ] || die "missing source file: $f (run from the repo directory)"
done

# 1. Dependencies: tcpdump (sniff) and lldpd/lldpctl (LLDP). Default DETECT_METHOD=both
#    needs both, and dynavlan refuses to run if the method's dependency is absent (FR-0).
if command -v apt-get >/dev/null 2>&1; then
	need=()
	command -v tcpdump >/dev/null 2>&1 || need+=(tcpdump)
	command -v lldpctl >/dev/null 2>&1 || need+=(lldpd)
	if [ "${#need[@]}" -gt 0 ]; then
		say "installing dependencies: ${need[*]}"
		DEBIAN_FRONTEND=noninteractive apt-get update -qq
		DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}"
	else
		say "dependencies present (tcpdump, lldpctl)"
	fi
else
	say "WARNING: apt-get not found; ensure tcpdump and lldpd/lldpctl are installed for DETECT_METHOD=both"
fi

# 2. Quiesce before touching the script (upgrade path). On a first install nothing
#    is running and this is a no-op; on an upgrade the rescan timer has been firing
#    since the last install, so two things must be true before the swap:
#      (a) no new run starts mid-install -> stop the timer, restored on exit;
#      (b) no run is in flight -> take the FR-30 lock and wait for it.
#    Without (b) the script file is rewritten under a live `dynavlan --rescan`; bash
#    reads a script lazily by file offset, so the running invocation would execute
#    garbage or stop mid-logic, possibly between `netplan try` and its confirmation.
if systemctl is-active --quiet dynavlan.timer 2>/dev/null; then
	TIMER_WAS_ACTIVE=1
	say "stopping dynavlan.timer for the duration of the install"
	systemctl stop dynavlan.timer
fi

say "waiting for any in-flight dynavlan run to finish (FR-30 lock, up to ${LOCK_WAIT}s)"
exec 9>"$LOCK_FILE"
flock -w "$LOCK_WAIT" 9 ||
	die "a dynavlan run still holds $LOCK_FILE after ${LOCK_WAIT}s; refusing to replace the script under a live run (wait for it to finish, or stop dynavlan-rescan.service, then re-run)"

# 3. Script, stamped with the source checkout's build identity (FR-38).
#    Semver alone cannot say what is on a box: every build of an unreleased
#    version self-reports identically, so after a deploy there is no way to tell
#    which code is running short of diffing files or inferring it from behavior.
#    The `-dirty` marker matters as much as the hash - deploying a working tree
#    mid-edit is how a half-finished change reaches a box, and it should be
#    legible on the box afterwards rather than reconstructed from timestamps.
#    A non-git install (release tarball, no git binary) stamps "unknown": absent
#    provenance, stated plainly, never a fabricated identity.
#
#    build_id is interpolated UNESCAPED into an awk -v value and a grep pattern
#    below, and ends up inside a string in a script that runs as root. That is
#    safe only because its charset is constrained by construction: git emits a
#    hex abbreviated SHA, and the two other possible values are literals this
#    script writes itself. Do NOT reuse this pattern for a branch name, tag, or
#    anything else a human can choose - those can carry quotes and backslashes,
#    and would break out of the build="..." assignment.
#
#    Dirtiness is judged by `git status --porcelain`, not `git diff HEAD`, so an
#    UNTRACKED file counts too. That over-marks (a stray scratch file in the repo
#    yields -dirty) and that is the intended direction: a false "dirty" costs a
#    second look, a false "clean" is a build identity that lies.
if build_id=$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null) && [ -n "$build_id" ]; then
	if [ -n "$(git -C "$SRC_DIR" status --porcelain 2>/dev/null)" ]; then
		build_id="${build_id}-dirty"
	fi
else
	build_id="unknown"
fi

say "installing $SBIN (build $build_id)"
# `if`, not `[ ... ] && say ...`: under `set -e` that idiom exits the script
# whenever the test is false, which here is the ordinary case.
if [ "$build_id" = "unknown" ]; then
	say "NOTE: no git checkout detected; the installed script will report 'build unknown'"
fi
case "$build_id" in
*-dirty)
	say "WARNING: source tree has uncommitted changes; installing build $build_id, which corresponds to NO commit"
	;;
esac

# Stamp into a temp copy, never the source tree, and only install once the result
# still parses: a botched substitution must not become the script that runs as
# root on a headless box.
STAMPED=$(mktemp) || die "cannot create temp file for the build stamp"
# awk, not `sed "0,/^build=/s|...|"`: the 0,/re/ address is a GNU extension that
# BSD sed rejects outright, so that form cannot be exercised on a non-Linux dev
# box - and an install step that can only be tested in production is the pattern
# to avoid here. This replaces the FIRST ^build= line and copies the rest byte
# for byte, identically everywhere.
awk -v b="$build_id" '
	!stamped && /^build=/ { printf "build=\"%s\"\n", b; stamped = 1; next }
	{ print }
' "$SRC_DIR/dynavlan" >"$STAMPED" ||
	die "failed to stamp the build identity into the script"
grep -q "^build=\"$build_id\"\$" "$STAMPED" ||
	die "build stamp did not apply (no build= line matched); refusing to install an unstamped script"
bash -n "$STAMPED" || die "the stamped script failed a syntax check; refusing to install it"

install -m 0755 -o root -g root "$STAMPED" "$SBIN"

# 4. Config template (never clobber an existing operator config).
if [ -f "$CONF" ]; then
	say "keeping existing $CONF (template not overwritten)"
else
	say "installing $CONF"
	install -m 0644 -o root -g root "$SRC_DIR/dynavlan.conf" "$CONF"
fi

# 5. systemd units.
say "installing systemd units"
install -m 0644 -o root -g root "$SRC_DIR/dynavlan.service" "$UNIT_DIR/dynavlan.service"
install -m 0644 -o root -g root "$SRC_DIR/dynavlan-rescan.service" "$UNIT_DIR/dynavlan-rescan.service"
install -m 0644 -o root -g root "$SRC_DIR/dynavlan.timer" "$UNIT_DIR/dynavlan.timer"

# 6. Persistent journald (FR-31): a boot-looping headless box must retain logs across reboot.
say "ensuring persistent journald"
mkdir -p "$(dirname "$JOURNALD_DROPIN")"
cat >"$JOURNALD_DROPIN" <<'EOF'
# Installed by dynavlan (FR-31): guarantee the journal survives reboot so a
# headless box's discovery/apply/restart trail is durable.
[Journal]
Storage=persistent
EOF
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 || true
systemctl restart systemd-journald

# 7. Render the timer interval from RESCAN_MINUTES and reload.
say "reloading systemd and rendering timer interval"
systemctl daemon-reload
"$SBIN" --reconfigure

# 8. Enable the boot service and the rescan timer for NEXT boot. Deliberately NOT
#    `--now`: on a first install, a monotonic timer whose OnBootSec is already past
#    would fire the rescan (detect + netplan try + agent restart) immediately, before
#    the operator's --dry-run preview. Install must never trigger a surprise network
#    change. On an upgrade the timer was already running, so cleanup puts it
#    back exactly as it was found; that is the operator's existing posture, not a new
#    change, but it does mean the new code rescans within RESCAN_MINUTES.
say "enabling dynavlan.service (boot) and dynavlan.timer (rescan) for next boot"
systemctl enable dynavlan.service
systemctl enable dynavlan.timer

# The swap is complete; a queued run may proceed. The timer is restored by the trap.
exec 9>&-

say "done."
cat <<EOF

Next steps:
  1. Preview what dynavlan would do on this trunk (no changes):
       sudo dynavlan --dry-run
  2. Apply now (discovers VLANs, applies, restarts monitoring):
       sudo dynavlan --boot
     ...or just reboot; dynavlan.service runs --boot at boot.
  3. Watch it:
       journalctl -t dynavlan -f
  4. Status any time:
       sudo dynavlan --status

EOF

if [ "$TIMER_WAS_ACTIVE" -eq 1 ]; then
	cat <<EOF
This was an upgrade: the rescan timer was running before and is restarted as this
installer exits, so the NEW code will rescan (add-only) within RESCAN_MINUTES. Run the --dry-run
above now if you want to see what it will do before it does it. To hold it off:
     sudo systemctl stop dynavlan.timer
EOF
else
	cat <<EOF
The rescan timer is enabled but NOT yet running: it arms at the next boot, or
start it now with 'sudo systemctl start dynavlan.timer' once you are happy with
the --dry-run preview.
EOF
fi
