#!/usr/bin/env bash
#
# build-deb.sh - build a .deb package for dynavlan.
#
# Run from the repo root. Produces dynavlan_<version>_all.deb in the
# current directory. Requires dpkg-deb (available on Ubuntu/Debian or
# via brew on macOS for cross-building).
#
# Usage:
#   bash build-deb.sh              # version from dynavlan script
#   bash build-deb.sh 0.2.1        # explicit version

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '[build-deb] %s\n' "$*"; }
die() { printf '[build-deb] ERROR: %s\n' "$*" >&2; exit 1; }

command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found (install dpkg or dpkg-dev)"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION=$(grep '^ver=' "$SRC_DIR/dynavlan" | head -1 | sed 's/ver="\(.*\)"/\1/')
    [ -n "$VERSION" ] || die "could not extract version from dynavlan script"
fi

# Build identity (same logic as install.sh)
if build_id=$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null) && [ -n "$build_id" ]; then
    if [ -n "$(git -C "$SRC_DIR" status --porcelain 2>/dev/null)" ]; then
        build_id="${build_id}-dirty"
    fi
else
    build_id="unknown"
fi

say "building dynavlan_${VERSION}_all.deb (build $build_id)"

STAGE=$(mktemp -d) || die "cannot create staging directory"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

PKG="$STAGE/dynavlan_${VERSION}_all"

# Directory structure
mkdir -p "$PKG/DEBIAN"
mkdir -p "$PKG/usr/local/sbin"
mkdir -p "$PKG/etc"
mkdir -p "$PKG/lib/systemd/system"

# Control file with version substituted
sed "s/__VERSION__/$VERSION/" "$SRC_DIR/debian/control" > "$PKG/DEBIAN/control"

# Maintainer scripts
for f in conffiles postinst prerm postrm; do
    if [ -f "$SRC_DIR/debian/$f" ]; then
        cp "$SRC_DIR/debian/$f" "$PKG/DEBIAN/$f"
        chmod 0755 "$PKG/DEBIAN/$f"
    fi
done
# conffiles is data, not a script
[ -f "$PKG/DEBIAN/conffiles" ] && chmod 0644 "$PKG/DEBIAN/conffiles"

# Stamp build identity into the script (same awk as install.sh)
awk -v b="$build_id" '
    !stamped && /^build=/ { printf "build=\"%s\"\n", b; stamped = 1; next }
    { print }
' "$SRC_DIR/dynavlan" > "$PKG/usr/local/sbin/dynavlan"
chmod 0755 "$PKG/usr/local/sbin/dynavlan"

grep -q "^build=\"$build_id\"\$" "$PKG/usr/local/sbin/dynavlan" ||
    die "build stamp did not apply"
bash -n "$PKG/usr/local/sbin/dynavlan" || die "stamped script failed syntax check"

# Config template
install -m 0644 "$SRC_DIR/dynavlan.conf" "$PKG/etc/dynavlan.conf"

# systemd units (lib/systemd/system is the package-managed location)
install -m 0644 "$SRC_DIR/dynavlan.service" "$PKG/lib/systemd/system/dynavlan.service"
install -m 0644 "$SRC_DIR/dynavlan-rescan.service" "$PKG/lib/systemd/system/dynavlan-rescan.service"
install -m 0644 "$SRC_DIR/dynavlan.timer" "$PKG/lib/systemd/system/dynavlan.timer"

# Build
dpkg-deb --build --root-owner-group "$PKG" "$SRC_DIR/dynavlan_${VERSION}_all.deb"

say "done: dynavlan_${VERSION}_all.deb"
