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

restore_apt_file() { # final prior_copy existed
	local final=$1 prior=$2 existed=$3

	if [ "$existed" -eq 1 ]; then
		if ! cp -p "$prior" "$final"; then
			say "WARNING: could not restore the previous $final; APT may no longer see the dynavlan repository"
			return 1
		fi
		return 0
	fi

	if ! rm -f "$final"; then
		say "WARNING: could not remove the $final this run created"
		return 1
	fi
	return 0
}

# Non-zero if ANY restore failed, so the caller can keep the staging directory:
# those copies are then the only surviving record of the operator's previous
# repository configuration, and deleting them would turn a recoverable failure
# into an unrecoverable one.
apt_restore_prior() {
	local rc=0

	if [ "$APT_KEYRING_REPLACED" -eq 1 ]; then
		restore_apt_file "$APT_KEYRING" "$APT_STAGE/keyring.prior" "$APT_KEYRING_EXISTED" || rc=1
	fi
	if [ "$APT_SOURCE_REPLACED" -eq 1 ]; then
		restore_apt_file "$APT_SOURCE" "$APT_STAGE/source.prior" "$APT_SOURCE_EXISTED" || rc=1
	fi
	return "$rc"
}

# The APT bootstrap proper. Split out of install_via_apt so that every failure
# path shares one restore-and-clean exit: returning non-zero from here asks for
# the box to be put back exactly as it was found.
#
# Every command below carries its own failure branch. install_via_apt is called
# as an `if !` condition, which disables set -e for the whole call, so an
# unchecked failure would silently read as success.
apt_bootstrap() {
	local keyring_dir
	keyring_dir=$(dirname "$APT_KEYRING")

	if ! mkdir -p "$keyring_dir"; then
		say "could not create $keyring_dir, falling back"
		return 1
	fi

	if [ -e "$APT_KEYRING" ]; then
		if ! cp -p "$APT_KEYRING" "$APT_STAGE/keyring.prior"; then
			say "could not back up the existing $APT_KEYRING, falling back without touching it"
			return 1
		fi
		APT_KEYRING_EXISTED=1
	fi

	if [ -e "$APT_SOURCE" ]; then
		if ! cp -p "$APT_SOURCE" "$APT_STAGE/source.prior"; then
			say "could not back up the existing $APT_SOURCE, falling back without touching it"
			return 1
		fi
		APT_SOURCE_EXISTED=1
	fi

	# Staged beside the final paths so moving one into place is a same-filesystem
	# rename that cannot half-succeed.
	if ! curl -fsSL "$APT_REPO_URL/dynavlan-archive-keyring.gpg" -o "$APT_KEYRING_NEW"; then
		say "could not fetch the APT signing key (repo not live yet?), falling back"
		return 1
	fi

	if ! printf '%s\n' \
		"Types: deb" \
		"URIs: $APT_REPO_URL" \
		"Suites: stable" \
		"Components: main" \
		"Signed-By: $APT_KEYRING" \
		>"$APT_SOURCE_NEW"; then
		say "could not write the APT source file, falling back"
		return 1
	fi

	if ! mv -f "$APT_KEYRING_NEW" "$APT_KEYRING"; then
		say "could not install the APT signing key at $APT_KEYRING, falling back"
		return 1
	fi
	APT_KEYRING_REPLACED=1

	if ! mv -f "$APT_SOURCE_NEW" "$APT_SOURCE"; then
		say "could not install the APT source at $APT_SOURCE, falling back"
		return 1
	fi
	APT_SOURCE_REPLACED=1

	if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
		say "apt-get update failed against the dynavlan repo, falling back"
		return 1
	fi

	if ! DEBIAN_FRONTEND=noninteractive apt-get install -y dynavlan; then
		say "apt-get install dynavlan failed, falling back"
		return 1
	fi

	say "installed via apt; future releases available via 'apt upgrade'"
	return 0
}

install_via_apt() {
	command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1 || return 1
	[ -z "$TAG" ] || {
		say "a specific version was requested ($TAG); apt always installs the latest, using the tarball path instead"
		return 1
	}

	say "apt/dpkg detected, trying the dynavlan APT repository"

	local rc
	APT_KEYRING_EXISTED=0
	APT_SOURCE_EXISTED=0
	APT_KEYRING_REPLACED=0
	APT_SOURCE_REPLACED=0
	APT_KEYRING_NEW="$APT_KEYRING.dynavlan-new"
	APT_SOURCE_NEW="$APT_SOURCE.dynavlan-new"

	APT_STAGE=$(mktemp -d) || {
		say "could not create a staging directory, falling back"
		return 1
	}

	apt_bootstrap
	rc=$?

	if [ "$rc" -ne 0 ] && ! apt_restore_prior; then
		# The staged copies are now the ONLY record of the previous repository
		# configuration, so keep them and say where they are. Deleting them here
		# would turn a recoverable failure into an unrecoverable one.
		say "WARNING: could not fully restore the previous APT configuration; the saved copies are kept in $APT_STAGE (keyring.prior / source.prior) - restore them manually"
		# A leftover *.dynavlan-new is inert to apt either way (it only reads
		# .list/.sources), so its removal failing here does not change the
		# outcome above - just say so rather than discard the failure silently.
		rm -f "$APT_KEYRING_NEW" "$APT_SOURCE_NEW" ||
			say "WARNING: could not remove leftover staging file(s) ($APT_KEYRING_NEW / $APT_SOURCE_NEW)"
		return "$rc"
	fi

	# Cleanup failure here does not need its own transaction or result model:
	# it never changes what install_via_apt reports (still $rc, the real
	# bootstrap/restore outcome) - it is only checked so a leftover staging
	# file is never silently discarded without at least a warning.
	rm -rf "$APT_STAGE" || say "WARNING: could not remove the staging directory $APT_STAGE"
	rm -f "$APT_KEYRING_NEW" "$APT_SOURCE_NEW" ||
		say "WARNING: could not remove leftover staging file(s) ($APT_KEYRING_NEW / $APT_SOURCE_NEW)"
	return "$rc"
}

install_via_tarball() {
	say "installing via the tarball path"

	if [ -z "$TAG" ]; then
		say "fetching latest release tag"
		# Fetching and parsing are split deliberately. The old single
		# `curl | grep | head | sed` pipeline aborted with NO message at all
		# under `set -euo pipefail` if the API was unreachable - so the
		# diagnostic below never printed in either case it exists for.
		# Fetching is now its own explicit, checked step; the sed that
		# follows only ever transforms text already known to be in hand, so
		# a transport failure and a response carrying no tag_name stay
		# distinct.
		RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest") ||
			die "could not reach the GitHub releases API for $REPO (network down, or rate-limited?)"
		TAG=$(printf '%s\n' "$RELEASE_JSON" |
			sed -n '/"tag_name"/{s/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q;}')
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
