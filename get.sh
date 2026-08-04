#!/usr/bin/env bash
#
# get.sh - install or upgrade dynavlan.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh | sudo bash
#
# On an apt/dpkg system, adds the dynavlan APT repository and installs via
# apt (apt-upgradeable from then on). On any other system, or if the apt
# repository isn't reachable yet, falls back to the tarball + install.sh path.
#
# Or to install a specific version via the tarball path:
#   curl -fsSL https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh | sudo bash -s -- v0.2.1

set -euo pipefail

REPO="pereljon/dynavlan"
APT_REPO_URL="https://pereljon.github.io/dynavlan"
APT_KEYRING="/etc/apt/keyrings/dynavlan.gpg"
APT_SOURCE="/etc/apt/sources.list.d/dynavlan.sources"

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

install_via_apt() {
	command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1 || return 1
	[ -z "$TAG" ] || {
		say "a specific version was requested ($TAG); apt always installs the latest, using the tarball path instead"
		return 1
	}

	say "apt/dpkg detected, trying the dynavlan APT repository"

	mkdir -p /etc/apt/keyrings
	if ! curl -fsSL "$APT_REPO_URL/dynavlan-archive-keyring.gpg" -o "$APT_KEYRING"; then
		say "could not fetch the APT signing key (repo not live yet?), falling back"
		rm -f "$APT_KEYRING"
		return 1
	fi

	cat >"$APT_SOURCE" <<EOF
Types: deb
URIs: $APT_REPO_URL
Suites: stable
Components: main
Signed-By: $APT_KEYRING
EOF

	if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
		say "apt-get update failed against the dynavlan repo, falling back"
		rm -f "$APT_SOURCE" "$APT_KEYRING"
		return 1
	fi

	if ! DEBIAN_FRONTEND=noninteractive apt-get install -y dynavlan; then
		say "apt-get install dynavlan failed, falling back"
		rm -f "$APT_SOURCE" "$APT_KEYRING"
		return 1
	fi

	say "installed via apt; future releases available via 'apt upgrade'"
	return 0
}

install_via_tarball() {
	say "installing via the tarball path"

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
}

if ! install_via_apt; then
	if [ -z "$TAG" ] && command -v dpkg >/dev/null 2>&1 && dpkg -s dynavlan >/dev/null 2>&1; then
		die "dynavlan is already installed via apt/dpkg but the apt install path just failed for an unrelated reason (not simply 'repo not live yet'); fix apt manually (e.g. 'sudo apt-get install -f') rather than falling back to a non-apt-managed tarball install, which would leave dpkg's records out of sync with what's on disk"
	fi
	install_via_tarball
fi
