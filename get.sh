#!/usr/bin/env bash
#
# get.sh - download and install the latest dynavlan release.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh | sudo bash
#
# Or to install a specific version:
#   curl -fsSL https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh | sudo bash -s -- v0.2.1

set -euo pipefail

REPO="pereljon/dynavlan"

say() { printf '[get-dynavlan] %s\n' "$*"; }
die() {
	printf '[get-dynavlan] ERROR: %s\n' "$*" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || die "must run as root (pipe to 'sudo bash')"

for cmd in curl tar; do
	command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not found"
done

TAG="${1:-}"
if [ -z "$TAG" ]; then
	say "fetching latest release tag"
	TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
		grep '"tag_name"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
	[ -n "$TAG" ] || die "could not determine latest release (GitHub API returned no tag_name)"
fi

say "installing dynavlan $TAG"

WORK=$(mktemp -d) || die "cannot create temp directory"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

TARBALL="$WORK/dynavlan.tar.gz"
curl -fsSL "https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz" -o "$TARBALL" ||
	die "failed to download $TAG (does the release exist?)"

tar xzf "$TARBALL" -C "$WORK" ||
	die "failed to extract archive"

EXTRACTED=$(find "$WORK" -maxdepth 1 -type d -name "dynavlan-*" | head -1)
[ -d "$EXTRACTED" ] || die "extracted directory not found"
[ -f "$EXTRACTED/install.sh" ] || die "install.sh not found in release archive"

cd "$EXTRACTED"
bash install.sh
