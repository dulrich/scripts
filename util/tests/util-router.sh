#!/usr/bin/env bash

set -u

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT

pass_count=0
fail_count=0

pass() {
	printf 'ok %d - %s\n' "$((pass_count + fail_count + 1))" "$1"
	pass_count=$((pass_count + 1))
}

fail() {
	printf 'not ok %d - %s\n' "$((pass_count + fail_count + 1))" "$1" >&2
	fail_count=$((fail_count + 1))
}

assert_eq() {
	local expected=$1
	local actual=$2
	local description=$3

	if [[ "$actual" == "$expected" ]]; then
		pass "$description"
	else
		printf '  expected: %q\n  actual:   %q\n' "$expected" "$actual" >&2
		fail "$description"
	fi
}

assert_status() {
	local expected=$1
	local actual=$2
	local description=$3

	if [[ "$actual" -eq "$expected" ]]; then
		pass "$description"
	else
		printf '  expected status: %s\n  actual status:   %s\n' "$expected" "$actual" >&2
		fail "$description"
	fi
}

assert_contains() {
	local haystack=$1
	local needle=$2
	local description=$3

	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$description"
	else
		printf '  missing: %q\n  output:  %q\n' "$needle" "$haystack" >&2
		fail "$description"
	fi
}

assert_not_contains() {
	local haystack=$1
	local needle=$2
	local description=$3

	if [[ "$haystack" != *"$needle"* ]]; then
		pass "$description"
	else
		printf '  unexpected: %q\n  output:     %q\n' "$needle" "$haystack" >&2
		fail "$description"
	fi
}

fixture_repo="$fixture_root/repo"
fixture_util="$fixture_repo/util"
fixture_private="$fixture_repo/private/util"
mkdir -p "$fixture_util" "$fixture_private" "$fixture_root/bin"
cp "$repo_dir/util/dispatch.sh" "$repo_dir/util/lib.sh" "$repo_dir/util/completions.sh" "$fixture_util/"

apply_fixture_script() {
	local path=$1
	# These expansions must remain literal until the generated fixture runs.
	# shellcheck disable=SC2016
	printf '%s\n' '#!/usr/bin/env bash' 'printf '\''command=%s\n'\'' "$0"' 'printf '\''argc=%d\n'\'' "$#"' 'printf '\''arg=<%s>\n'\'' "$@"' > "$path"
	chmod +x "$path"
}

apply_fixture_script "$fixture_util/extensionless"
apply_fixture_script "$fixture_util/scripted.sh"
apply_fixture_script "$fixture_private/private-command.sh"

# Helper modules that a command keeps in its own subdirectory (util/cache-prune/
# holds cache-prune.sh's adapters/measurement/actions/cli modules). The router
# globs "$here"/*.sh, so a helper dropped beside dispatch.sh *would* become a
# command; under a subdirectory it must not, and these fixtures are executable
# so that nothing but the glob's depth is doing the excluding.
fixture_helpers="$fixture_util/cache-prune"
mkdir -p "$fixture_helpers"
for helper in adapters measurement actions cli; do
	apply_fixture_script "$fixture_helpers/$helper.sh"
done

# A local command with the same name must retain precedence over the overlay.
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''local-wins\n'\''' > "$fixture_util/shadowed.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''private-loses\n'\''' > "$fixture_private/shadowed.sh"
chmod +x "$fixture_util/shadowed.sh" "$fixture_private/shadowed.sh"

output=$(
	"$fixture_util/dispatch.sh" extensionless 'one two' '*' ''
)
assert_contains "$output" 'argc=3' 'extensionless command receives every argument'
assert_contains "$output" 'arg=<one two>' 'router preserves embedded spaces'
assert_contains "$output" 'arg=<*>' 'router preserves glob characters'
assert_contains "$output" 'arg=<>' 'router preserves empty arguments'

output=$(
	"$fixture_util/dispatch.sh" scripted 'three four'
)
assert_contains "$output" 'argc=1' '.sh command receives its argument count'
assert_contains "$output" 'arg=<three four>' '.sh command preserves argument boundaries'

output=$("$fixture_util/dispatch.sh" private-command overlay)
assert_contains "$output" 'arg=<overlay>' 'private overlay .sh command is routable'

output=$("$fixture_util/dispatch.sh" shadowed)
assert_eq 'local-wins' "$output" 'local util command takes precedence over private overlay'

set +e
output=$("$fixture_util/dispatch.sh" unknown 2>&1)
status=$?
set -e
assert_status 1 "$status" 'unknown command returns nonzero'
assert_contains "$output" 'Unknown util <unknown>' 'unknown command identifies the requested name'

set +e
output=$("$fixture_util/dispatch.sh" 2>&1)
status=$?
set -e
assert_status 1 "$status" 'empty invocation returns nonzero after listing commands'
assert_contains "$output" 'scripted' 'command listing discovers public .sh commands'
assert_contains "$output" 'private-command' 'command listing discovers private overlay .sh commands'
assert_not_contains "$output" 'extensionless' 'command listing retains its .sh discovery surface'
assert_not_contains "$output" 'dispatch' 'command listing excludes dispatch infrastructure'
assert_not_contains "$output" 'lib' 'command listing excludes library infrastructure'
assert_not_contains "$output" 'completions' 'command listing excludes completion infrastructure'

ln -s "$fixture_util/dispatch.sh" "$fixture_root/bin/util"
output=$("$fixture_root/bin/util" scripted symlink)
assert_contains "$output" 'arg=<symlink>' 'symlinked router resolves commands beside its real target'

completion_output=$(
	FIXTURE_COMPLETIONS="$fixture_util/completions.sh" bash -c '
		source "$FIXTURE_COMPLETIONS"
		COMP_WORDS=(util "")
		COMP_CWORD=1
		_util_complete
		printf "%s\n" "${COMPREPLY[@]}"
	'
)
assert_contains "$completion_output" 'scripted' 'completion discovers public .sh commands'
assert_contains "$completion_output" 'private-command' 'completion discovers private overlay commands'
assert_not_contains "$completion_output" 'extensionless' 'completion retains its .sh discovery surface'
assert_not_contains "$completion_output" 'dispatch' 'completion excludes dispatch infrastructure'
assert_not_contains "$completion_output" 'lib' 'completion excludes library infrastructure'
assert_not_contains "$completion_output" 'completions' 'completion excludes completion infrastructure'

# A command's helper modules must never become commands themselves. This is
# the structural guarantee that lets cache-prune keep adapters/measurement/
# actions/cli as separate files: they live one directory down, where neither
# the router's glob nor the completion's glob can see them.
set +e
listing_output=$("$fixture_util/dispatch.sh" 2>&1)
set -e
for helper in adapters measurement actions cli; do
	assert_not_contains "$listing_output" "$helper" "command listing excludes the $helper helper module in a command's subdirectory"
	assert_not_contains "$completion_output" "$helper" "completion excludes the $helper helper module in a command's subdirectory"

	set +e
	helper_output=$("$fixture_util/dispatch.sh" "$helper" 2>&1)
	helper_status=$?
	set -e
	assert_status 1 "$helper_status" "routing to the $helper helper module fails -- it is not a command"
	assert_contains "$helper_output" "Unknown util <$helper>" "the router reports the $helper helper module as an unknown command, not as a routable one"
done

# The same guarantee, asserted against the real tree rather than a fixture:
# util/cache-prune/ exists, and none of what it holds is listed as a command.
set +e
real_listing=$("$repo_dir/util/dispatch.sh" 2>&1)
set -e
assert_contains "$real_listing" 'cache-prune' 'the real router still lists cache-prune itself'
for helper in "$repo_dir"/util/cache-prune/*.sh; do
	[ -e "$helper" ] || continue
	assert_not_contains "$real_listing" "$(basename "$helper" .sh)" "the real router does not list util/cache-prune/$(basename "$helper")"
done

completion_output=$(
	cd "$fixture_root"
	touch alpha.txt alphabet.txt beta.txt
	FIXTURE_COMPLETIONS="$fixture_util/completions.sh" bash -c '
		cd "$1"
		source "$FIXTURE_COMPLETIONS"
		COMP_WORDS=(util scripted alph)
		COMP_CWORD=2
		_util_complete
		printf "%s\n" "${COMPREPLY[@]}"
	' bash "$fixture_root"
)
assert_contains "$completion_output" 'alpha.txt' 'deeper completion discovers matching filenames'
assert_contains "$completion_output" 'alphabet.txt' 'deeper completion keeps all filename matches'
assert_not_contains "$completion_output" 'beta.txt' 'deeper completion respects the current prefix'

# The router's listing and its completion must offer the exact same command
# set, not merely overlapping sets -- both now call the one shared discovery
# function in lib.sh, so a divergence here would mean one of them stopped
# sharing it.
# shellcheck disable=SC1091
source "$fixture_util/lib.sh"
listing_set=$(_util_commands "$fixture_util" | sort)
level1_completion=$(
	FIXTURE_COMPLETIONS="$fixture_util/completions.sh" bash -c '
		source "$FIXTURE_COMPLETIONS"
		COMP_WORDS=(util "")
		COMP_CWORD=1
		_util_complete
		printf "%s\n" "${COMPREPLY[@]}"
	'
)
completion_set=$(printf '%s\n' "$level1_completion" | sort)
assert_eq "$listing_set" "$completion_set" 'router listing and completion enumerate the identical command set'

# Every real subcommand in util/ must be executable: dispatch.sh routes with
# `exec`, so a non-executable subcommand fails at runtime with exit 126 even
# though it sources and passes its own tests fine. Infrastructure files
# (dispatch/lib/completions) are sourced or invoked directly and are exempt.
for candidate in "$repo_dir"/util/*.sh; do
	[ -e "$candidate" ] || continue
	candidate_name=$(basename "$candidate" .sh)
	case "$candidate_name" in
		dispatch|lib|completions) continue ;;
	esac
	if [ -x "$candidate" ]; then
		pass_count=$((pass_count + 1))
		printf 'ok - subcommand %s is executable\n' "$candidate_name"
	else
		fail_count=$((fail_count + 1))
		printf 'not ok - subcommand %s is not executable (dispatch.sh execs it)\n' "$candidate_name"
	fi
done

printf '1..%d\n' "$((pass_count + fail_count))"
printf '%d passed, %d failed\n' "$pass_count" "$fail_count"

if (( fail_count > 0 )); then
	exit 1
fi
