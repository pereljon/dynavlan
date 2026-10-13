#!/usr/bin/env bash
#
# Version-gate git hook tests (Gate 4): the REAL githooks/{pre-commit,commit-msg,install.sh}
# run through real `git commit` in disposable repos. Outcomes are asserted by the commit's
# exit status and whether HEAD advanced, never by message text. Run directly
# (`bash tests/hooks.sh`) or via tests/unit.sh, which folds this file's counts into its own.
#
# HOOKS_SRC may point at another checkout holding githooks/. Git runs with no global or
# system config, so the user's git configuration is neither read nor changed.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HOOKS_SRC:-$here/..}"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
tests=0
fails=0
n=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

TO=()
for _t in timeout gtimeout; do
	if command -v "$_t" >/dev/null 2>&1 && "$_t" 5 true >/dev/null 2>&1; then
		TO=("$_t" 30)
		break
	fi
done

ok() { tests=$((tests + 1)); printf 'ok   - %s\n' "$1"; }
bad() { tests=$((tests + 1)); fails=$((fails + 1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }

BODY="echo body1"
irc="" rc="" moved=""

_g() { (cd "$R" && "${TO[@]}" git "$@"); }
_hookdir() { (cd "$R" && git rev-parse --git-path hooks); }
_new() {
	n=$((n + 1))
	R="$root/r$n"
	mkdir -p "$R"
	(cd "$R" && git init -q)
	irc="" rc="" moved=""
}
_inst() {
	(cd "$R" && "${TO[@]}" bash "$SRC/githooks/install.sh") >"$root/inst$n.out" 2>&1
	irc=$?
}
# _script LINE... : write the fixture dynavlan with exactly those header lines plus the body.
_script() { { printf '#!/bin/bash\n'; printf '%s\n' "$@"; printf '%s\n' "$BODY"; } >"$R/dynavlan"; }
# Repo with hooks installed and an initial commit of a valid fixture plus a README.
_repo() {
	_new
	_inst
	_script 'ver="1.0.0"' 'build="source"'
	echo readme >"$R/README"
	_g add dynavlan README
	_g commit -q -m init >"$root/init$n.out" 2>&1
}
_try() { # message text -> sets rc, moved
	local h0 h1
	h0=$(_g rev-parse HEAD 2>/dev/null)
	printf '%s' "$1" >"$root/msg$n"
	_g commit -q -F "$root/msg$n" >"$root/commit$n.out" 2>&1
	rc=$?
	h1=$(_g rev-parse HEAD 2>/dev/null)
	if [ "$h0" != "$h1" ]; then moved=1; else moved=0; fi
}
_hooks_in() {
	local d
	d="$(_hookdir)"
	[ "$irc" = 0 ] && [ -x "$R/$d/pre-commit" ] && [ -x "$R/$d/commit-msg" ]
}
_assert() { # desc ok|block
	local info="irc=$irc rc=$rc head_moved=$moved"
	if ! _hooks_in; then
		bad "$1" "hooks not installed ($info)"
		return
	fi
	case "$2" in
	ok) if [ "$rc" = 0 ] && [ "$moved" = 1 ]; then ok "$1"; else bad "$1" "expected commit to succeed ($info)"; fi ;;
	block) if [ "$rc" != 0 ] && [ "$moved" = 0 ]; then ok "$1"; else bad "$1" "expected commit to be blocked ($info)"; fi ;;
	esac
}
# _chg DESC EXPECT MSG LINE... : stage a changed body with the given header lines, commit with MSG.
_chg() {
	_repo
	BODY="echo body2"
	_script "${@:4}"
	BODY="echo body1"
	_g add dynavlan
	_try "$3"
	_assert "$1" "$2"
}

M0=$'change\n'
MT=$'change\n\nVersion-Bump: none (comment-only change)\n'
V0='ver="1.0.0"'
B0='build="source"'

# a. version increased
_chg "a. body change with ver 1.0.0 -> 1.0.1 commits" ok "$M0" 'ver="1.0.1"' "$B0"
# b. unchanged ver, no trailer
_chg "b. body change, ver unchanged, no trailer is blocked" block "$M0" "$V0" "$B0"
# c. trailer rescues an equal ver
_chg "c. body change, ver unchanged, Version-Bump: none (reason) commits" ok "$MT" "$V0" "$B0"
_chg "c2. trailer duplicated only in a # comment line still commits" ok $'change\n\nVersion-Bump: none (comment-only change)\n# Version-Bump: none (comment-only change)\n' "$V0" "$B0"
_chg "c3. trailer only inside a # comment line is blocked" block $'change\n\n# Version-Bump: none (comment-only change)\n' "$V0" "$B0"
# d. empty or missing reason
_chg "d1. Version-Bump: none () is blocked" block $'change\n\nVersion-Bump: none ()\n' "$V0" "$B0"
_chg "d2. Version-Bump: none (no parens) is blocked" block $'change\n\nVersion-Bump: none\n' "$V0" "$B0"
_chg "d3. Version-Bump: none (   ) whitespace-only reason is blocked" block $'change\n\nVersion-Bump: none (   )\n' "$V0" "$B0"
# e. two trailers
_chg "e. two Version-Bump trailers is blocked" block $'change\n\nVersion-Bump: none (first)\nVersion-Bump: none (second)\n' "$V0" "$B0"
# f. decreased ver
_chg "f1. ver 1.0.0 -> 0.9.9 with a valid trailer is blocked" block "$MT" 'ver="0.9.9"' "$B0"
_chg "f2. ver 1.0.0 -> 0.9.9 without a trailer is blocked" block "$M0" 'ver="0.9.9"' "$B0"
_chg "f3. version ordering is numeric: 1.0.0 -> 1.0.10 commits" ok "$M0" 'ver="1.0.10"' "$B0"
_chg "f4. version ordering is numeric: 1.0.0 -> 0.10.0 is a decrease and is blocked even with a trailer" block "$MT" 'ver="0.10.0"' "$B0"
# g. build= variants, valid trailer present
_chg "g1. build line removed is blocked" block "$MT" "$V0"
_chg "g2. indented build=\"source\" is blocked" block "$MT" "$V0" '  build="source"'
_chg "g3. stamped build=\"abc1234\" is blocked" block "$MT" "$V0" 'build="abc1234"'
_chg "g4. second build=\"source\" line is blocked" block "$MT" "$V0" "$B0" "$B0"
_chg "g5. valid build plus an extra indented build= line is blocked" block "$MT" "$V0" "$B0" '  build="abc1234"'
_chg "g6. stamped build with a bumped ver is blocked" block "$M0" 'ver="1.0.1"' 'build="abc1234"'
# h. malformed ver, valid trailer present
_chg "h1. ver=\"1.0\" is blocked" block "$MT" 'ver="1.0"' "$B0"
_chg "h2. two ver= lines is blocked" block "$MT" "$V0" 'ver="1.0.1"' "$B0"
_chg "h3. missing ver is blocked" block "$MT" "$B0"
_chg "h4. extra indented ver= line is blocked" block "$MT" "$V0" '  ver="1.0.1"' "$B0"
_chg "h5. malformed ver with a bumped-looking value is blocked" block "$M0" 'ver="1.0.1-rc1"' "$B0"

# i. the index is authoritative, the working tree is not
_repo
BODY="echo body2"
_script "$V0" "$B0"
_g add dynavlan
_script 'ver="1.0.1"' "$B0"
BODY="echo body1"
_try "$M0"
_assert "i1. index has unchanged ver + body change, working tree has bumped ver: blocked" block

_repo
BODY="echo body2"
_script 'ver="1.0.1"' "$B0"
_g add dynavlan
_script "$V0" "$B0"
BODY="echo body1"
_try "$M0"
_assert "i2. index has bumped ver, working tree edited back to old ver unstaged: commits" ok

# j. a commit that does not change dynavlan needs no trailer
_repo
echo more >>"$R/README"
_g add README
_try $'docs only\n'
_assert "j. README-only commit commits without a trailer" ok

# k. installer
_new
_inst
d="$(_hookdir)"
_k_ident() { cmp -s "$SRC/githooks/pre-commit" "$R/$d/pre-commit" && cmp -s "$SRC/githooks/commit-msg" "$R/$d/commit-msg"; }
if [ "$irc" = 0 ] && [ -x "$R/$d/pre-commit" ] && [ -x "$R/$d/commit-msg" ] && _k_ident; then
	ok "k1. fresh repo: installer exits 0 and installs executable copies identical to githooks/"
else
	bad "k1. fresh repo: installer exits 0 and installs executable copies identical to githooks/" "irc=$irc"
fi
before=$(cd "$R" && git config --local --list)
_inst
after=$(cd "$R" && git config --local --list)
if [ "$irc" = 0 ] && [ -x "$R/$d/pre-commit" ] && [ -x "$R/$d/commit-msg" ] && _k_ident; then
	ok "k2. second run exits 0 and leaves both hooks identical"
else
	bad "k2. second run exits 0 and leaves both hooks identical" "irc=$irc"
fi
if [ "$irc" = 0 ] && [ -n "$before" ] && [ "$before" = "$after" ]; then
	ok "k2b. installer changes no git config"
else
	bad "k2b. installer changes no git config" "before=[$before] after=[$after]"
fi

_new
d="$(_hookdir)"
mkdir -p "$R/$d"
printf '#!/bin/sh\necho foreign\n' >"$R/$d/pre-commit"
cp "$R/$d/pre-commit" "$root/foreign.$n"
_inst
if [ -f "$SRC/githooks/install.sh" ] && [ "$irc" != 0 ] && cmp -s "$root/foreign.$n" "$R/$d/pre-commit" && [ ! -e "$R/$d/commit-msg" ]; then
	ok "k3. foreign pre-commit: installer refuses, foreign file unchanged, commit-msg not written"
else
	bad "k3. foreign pre-commit: installer refuses, foreign file unchanged, commit-msg not written" "irc=$irc commit-msg-exists=$([ -e "$R/$d/commit-msg" ] && echo yes || echo no)"
fi

_new
d="$(_hookdir)"
mkdir -p "$R/$d"
printf '#!/bin/sh\necho foreign\n' >"$R/$d/commit-msg"
cp "$R/$d/commit-msg" "$root/foreign.$n"
_inst
if [ -f "$SRC/githooks/install.sh" ] && [ "$irc" != 0 ] && cmp -s "$root/foreign.$n" "$R/$d/commit-msg" && [ ! -e "$R/$d/pre-commit" ]; then
	ok "k4. foreign commit-msg: installer refuses, foreign file unchanged, pre-commit not written"
else
	bad "k4. foreign commit-msg: installer refuses, foreign file unchanged, pre-commit not written" "irc=$irc pre-commit-exists=$([ -e "$R/$d/pre-commit" ] && echo yes || echo no)"
fi

_new
d="$(_hookdir)"
mkdir -p "$R/$d"
cp "$SRC/githooks/pre-commit" "$R/$d/pre-commit" 2>/dev/null
chmod 755 "$R/$d/pre-commit" 2>/dev/null
printf '#!/bin/sh\necho foreign\n' >"$R/$d/commit-msg"
cp "$R/$d/commit-msg" "$root/foreign.$n"
_inst
if [ -f "$SRC/githooks/pre-commit" ] && [ "$irc" != 0 ] && cmp -s "$root/foreign.$n" "$R/$d/commit-msg" && cmp -s "$SRC/githooks/pre-commit" "$R/$d/pre-commit"; then
	ok "k5. identical pre-commit but foreign commit-msg: installer refuses, both unchanged"
else
	bad "k5. identical pre-commit but foreign commit-msg: installer refuses, both unchanged" "irc=$irc"
fi

_new
d="$(_hookdir)"
(cd "$R" && git config core.hooksPath "$R/customhooks")
mkdir -p "$R/customhooks"
_inst
if [ -f "$SRC/githooks/install.sh" ] && [ "$irc" != 0 ] && [ ! -e "$R/$d/pre-commit" ] && [ ! -e "$R/$d/commit-msg" ] \
	&& [ ! -e "$R/customhooks/pre-commit" ] && [ ! -e "$R/customhooks/commit-msg" ] \
	&& [ "$(cd "$R" && git config --get core.hooksPath)" = "$R/customhooks" ]; then
	ok "k6. core.hooksPath set: installer refuses and writes nothing"
else
	bad "k6. core.hooksPath set: installer refuses and writes nothing" "irc=$irc"
fi

_new
_inst
d="$(_hookdir)"
chmod 644 "$R/$d/pre-commit" "$R/$d/commit-msg"
_inst
_k7_x="pre-commit-x=$([ -x "$R/$d/pre-commit" ] && echo yes || echo no) commit-msg-x=$([ -x "$R/$d/commit-msg" ] && echo yes || echo no)"
if [ "$irc" = 0 ] && [ -x "$R/$d/pre-commit" ] && [ -x "$R/$d/commit-msg" ] && _k_ident; then
	ok "k7. identical non-executable project hooks: installer exits 0, makes both executable, content unchanged"
else
	bad "k7. identical non-executable project hooks: installer exits 0, makes both executable, content unchanged" "irc=$irc $_k7_x"
fi
_script 'ver="1.0.0"' 'build="source"'
echo readme >"$R/README"
_g add dynavlan README
_g commit -q -m init >"$root/init$n.out" 2>&1
BODY="echo body2"
_script 'ver="1.0.0"' 'build="source"'
BODY="echo body1"
_g add dynavlan
_try "$M0"
if [ "$rc" != 0 ] && [ "$moved" = 0 ]; then
	ok "k7b. after reinstall over non-executable hooks, an unchanged-ver body change is blocked"
else
	bad "k7b. after reinstall over non-executable hooks, an unchanged-ver body change is blocked" "irc=$irc rc=$rc head_moved=$moved $_k7_x"
fi

_new
d="$(_hookdir)"
(cd "$R" && git config core.hooksPath "")
before=$(cd "$R" && git config --local --list)
_inst
after=$(cd "$R" && git config --local --list)
hp_out=$(cd "$R" && git config --get core.hooksPath)
hp_rc=$?
if [ -f "$SRC/githooks/install.sh" ] && [ "$irc" != 0 ] && [ ! -e "$R/$d/pre-commit" ] && [ ! -e "$R/$d/commit-msg" ] \
	&& [ ! -e "$R/pre-commit" ] && [ ! -e "$R/commit-msg" ] \
	&& [ "$hp_rc" = 0 ] && [ -z "$hp_out" ] && [ "$before" = "$after" ]; then
	ok "k8. core.hooksPath set to an empty value: installer refuses, writes nothing, config unchanged"
else
	bad "k8. core.hooksPath set to an empty value: installer refuses, writes nothing, config unchanged" "irc=$irc hooksPath-rc=$hp_rc hooksPath=[$hp_out] config-same=$([ "$before" = "$after" ] && echo yes || echo no) hooks-in-default=$([ -e "$R/$d/pre-commit" ] || [ -e "$R/$d/commit-msg" ] && echo yes || echo no)"
fi

printf '\n%s tests, %s failures\n' "$tests" "$fails"
[ "$fails" -eq 0 ]
