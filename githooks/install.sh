#!/usr/bin/env bash
#
# Install the version-gate hooks into this repository's hooks directory.
# Changes no git config. Refuses rather than overwrite any other hook.

set -o pipefail

say() { printf '[githooks] %s\n' "$*"; }
die() {
	printf '[githooks] ERROR: %s\n' "$*" >&2
	exit 1
}

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
names="pre-commit commit-msg"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "run this inside a git work tree"
# Presence, not value: an empty core.hooksPath makes git resolve the hooks directory to the worktree root.
hp=$(git config --get core.hooksPath)
case $? in
0) die "core.hooksPath is set ([$hp]); install the hooks there by hand or unset it" ;;
1) ;;
*) die "cannot read core.hooksPath" ;;
esac
dest=$(git rev-parse --git-path hooks) || die "cannot resolve the hooks directory"

todo=""
for name in $names; do
	[ -f "$src/$name" ] || die "missing source file $src/$name"
	if [ ! -e "$dest/$name" ]; then
		todo="$todo $name"
	elif ! cmp -s "$src/$name" "$dest/$name"; then
		die "$dest/$name exists and differs; refusing to overwrite it"
	fi
done

mkdir -p "$dest" || die "cannot create $dest"
for name in $todo; do
	cp "$src/$name" "$dest/$name" || die "cannot write $dest/$name"
	chmod 755 "$dest/$name" || die "cannot chmod $dest/$name"
	say "installed $dest/$name"
done
# A kept identical copy may have lost its execute bit, and git silently skips a non-executable hook.
for name in $names; do
	chmod 755 "$dest/$name" || die "cannot chmod $dest/$name"
done
[ -n "$todo" ] || say "hooks already installed in $dest"
exit 0
