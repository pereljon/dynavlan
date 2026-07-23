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

say() { printf '[install] %s\n' "$*"; }
die() {
	printf '[install] ERROR: %s\n' "$*" >&2
	exit 1
}

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

# 2. Script.
say "installing $SBIN"
install -m 0755 -o root -g root "$SRC_DIR/dynavlan" "$SBIN"

# 3. Config template (never clobber an existing operator config).
if [ -f "$CONF" ]; then
	say "keeping existing $CONF (template not overwritten)"
else
	say "installing $CONF"
	install -m 0644 -o root -g root "$SRC_DIR/dynavlan.conf" "$CONF"
fi

# 4. systemd units.
say "installing systemd units"
install -m 0644 -o root -g root "$SRC_DIR/dynavlan.service" "$UNIT_DIR/dynavlan.service"
install -m 0644 -o root -g root "$SRC_DIR/dynavlan-rescan.service" "$UNIT_DIR/dynavlan-rescan.service"
install -m 0644 -o root -g root "$SRC_DIR/dynavlan.timer" "$UNIT_DIR/dynavlan.timer"

# 5. Persistent journald (FR-31): a boot-looping headless box must retain logs across reboot.
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

# 6. Render the timer interval from RESCAN_MINUTES and reload.
say "reloading systemd and rendering timer interval"
systemctl daemon-reload
"$SBIN" --reconfigure

# 7. Enable the boot service and the rescan timer for NEXT boot. Deliberately NOT
#    `--now`: a monotonic timer whose OnBootSec is already past would fire the rescan
#    (detect + netplan try + agent restart) immediately, before the operator's
#    --dry-run preview. Install must never trigger a surprise network change.
say "enabling dynavlan.service (boot) and dynavlan.timer (rescan) for next boot"
systemctl enable dynavlan.service
systemctl enable dynavlan.timer

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

The rescan timer is already active (every RESCAN_MINUTES, add-only).
EOF
