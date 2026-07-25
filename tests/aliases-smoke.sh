#!/usr/bin/env bash

# Git test doubles are invoked indirectly by sourced alias functions.
# shellcheck disable=SC2317

set -u

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$test_dir/.." && pwd)
fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT

pass_count=0
fail_count=0
skip_count=0

pass() {
	printf 'ok %d - %s\n' "$((pass_count + fail_count + skip_count + 1))" "$1"
	pass_count=$((pass_count + 1))
}

fail() {
	printf 'not ok %d - %s\n' "$((pass_count + fail_count + skip_count + 1))" "$1" >&2
	fail_count=$((fail_count + 1))
}

skip() {
	printf 'ok %d - %s # SKIP\n' "$((pass_count + fail_count + skip_count + 1))" "$1"
	skip_count=$((skip_count + 1))
}

assert_eq() {
	local expected=$1 actual=$2 description=$3
	if [[ "$actual" == "$expected" ]]; then
		pass "$description"
	else
		printf '  expected: %q\n  actual:   %q\n' "$expected" "$actual" >&2
		fail "$description"
	fi
}

assert_contains() {
	local haystack=$1 needle=$2 description=$3
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$description"
	else
		printf '  missing: %q\n  output:  %q\n' "$needle" "$haystack" >&2
		fail "$description"
	fi
}

assert_not_contains() {
	local haystack=$1 needle=$2 description=$3
	if [[ "$haystack" != *"$needle"* ]]; then
		pass "$description"
	else
		printf '  unexpected: %q\n  output:     %q\n' "$needle" "$haystack" >&2
		fail "$description"
	fi
}

fixture_repo="$fixture_root/scripts fixture"
fixture_home="$fixture_root/home fixture"
mkdir -p "$fixture_repo/util" "$fixture_repo/private" \
	"$fixture_home/custom code/project" "$fixture_home/custom downloads"
cp "$repo_dir/aliases.sh" "$repo_dir/git-aliases.sh" \
	"$repo_dir/debian-aliases.sh" "$repo_dir/gentoo-aliases.sh" "$fixture_repo/"
cp "$repo_dir/util/dispatch.sh" "$repo_dir/util/lib.sh" \
	"$repo_dir/util/completions.sh" "$fixture_repo/util/"

# Keep machine-local fixture data literal until aliases.sh sources it.
# shellcheck disable=SC2016
printf '%s\n' 'code_path="$HOME/custom code"' \
	'down_path="$HOME/custom downloads"' > "$fixture_repo/config.sh"
# This fixture expansion must remain literal until the private overlay is sourced.
# shellcheck disable=SC2016
printf '%s\n' 'private_loaded=$((${private_loaded:-0} + 1))' > "$fixture_repo/private/aliases.sh"

export HOME="$fixture_home"
shopt -s expand_aliases

# Runtime-resolved fixture sources cannot be followed statically.
# shellcheck source=/dev/null
source "$fixture_repo/aliases.sh"

# These values are assigned by the sourced alias chain and its fixture overlays.
declare here code_path private_loaded

assert_eq "$fixture_repo" "$here" 'source resolves its real sibling directory'
assert_eq "$fixture_home/custom code" "$code_path" 'optional config overrides defaults'
assert_eq '1' "$private_loaded" 'private overlay is sourced once'
assert_contains "$(alias util)" "$fixture_repo/util/dispatch.sh" 'util alias captures the resolved sibling path'

completion=$(complete -p code 2>/dev/null || true)
assert_contains "$completion" '_code' 'generated directory helper registers completion'

starting_dir=$PWD
code project
assert_eq "$fixture_home/custom code/project" "$PWD" 'generated directory helper handles a spaced base path'
cd "$starting_dir" || exit 1

reload
assert_eq '2' "$private_loaded" 'reload sources the alias chain and private overlay again'
assert_eq "$fixture_repo" "$here" 'reload preserves symlink-relative repository resolution'

assert_eq './' "$(defarg '' 0 './')" 'defarg supplies its default'
assert_eq 'two' "$(defarg 'one two three' 1 default)" 'defarg selects a split word'
assert_eq 'one two three' "$(defarg 'one two three' @ default)" 'defarg returns all split words'

alias_p=$(alias p)
alias_s=$(alias s)
assert_contains "$alias_p" 'git push' 'p remains the Git push alias'
assert_contains "$alias_s" 'git status -bs' 's remains the short status alias'

git_calls=()
record_git_call() {
	local rendered
	printf -v rendered '%q ' "$@"
	git_calls+=("${rendered% }")
}

git() {
	case "$1 ${2:-}" in
		'branch ')
			printf '* master\n'
			return 0
			;;
	esac
	record_git_call "$@"
}

a
assert_eq 'add .' "${git_calls[-1]}" 'a defaults to the current directory'
a 'file with spaces' second
assert_eq 'add file\ with\ spaces second' "${git_calls[-1]}" 'a preserves caller argument boundaries'
b
assert_eq 'checkout master' "${git_calls[-1]}" 'b defaults to the primary branch'
m topic
assert_eq 'merge --no-edit topic' "${git_calls[-1]}" 'm forwards an explicit branch'

clear() { :; }
ls() {
	printf 'LS'
	printf ' %q' "$@"
	printf '\n'
}
git_mode=outside
git() {
	case "$1 ${2:-}" in
		'rev-parse --is-inside-work-tree')
			[[ "$git_mode" != outside ]]
			;;
		'rev-list --count')
			case "$git_mode" in
				nothing) printf '0\n' ;;
				unpushed) printf '2\n' ;;
				no-upstream) return 1 ;;
			 esac
			;;
		'push ')
			printf 'PUSHED\n'
			;;
		'status -bs')
			printf 'STATUS\n'
			;;
		*) return 1 ;;
	esac
}

output=$(cl 2>&1)
assert_eq $'(not a git repository)\nLS -alF --color=auto' "$output" \
	'cl reports the missing repository and falls back to the ll listing'

git_mode=nothing
output=$(cl 2>&1)
assert_contains "$output" '(nothing to push)' 'cl reports a clean upstream range'
assert_contains "$output" 'STATUS' 'cl still prints short status when nothing is unpushed'
assert_not_contains "$output" 'PUSHED' 'cl does not push without unpushed commits'

git_mode=unpushed
output=$(cl 2>&1)
assert_contains "$output" 'PUSHED' 'cl pushes when the upstream range has commits'
assert_contains "$output" 'STATUS' 'cl prints short status after pushing'

git_mode=no-upstream
output=$(cl 2>&1)
assert_contains "$output" '(nothing to push)' 'cl does not push when no upstream range can be proven'
assert_not_contains "$output" 'PUSHED' 'cl gates push on a successful positive count'

if declare -F __git_complete >/dev/null; then
	git_completion=$(complete -p a 2>/dev/null || true)
	assert_contains "$git_completion" '_git_add' 'Git completion is registered when system support exists'
else
	skip 'Git completion registration (system support unavailable)'
fi

printf '1..%d\n' "$((pass_count + fail_count + skip_count))"
printf '%d passed, %d failed, %d skipped\n' "$pass_count" "$fail_count" "$skip_count"

if ((fail_count > 0)); then
	exit 1
fi
