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

# The repository root is resolved dynamically so the smoke test works anywhere.
# shellcheck disable=SC1091
source "$repo_dir/util/lib.sh"
assert_eq './' "$(defarg '' 0 './')" 'defarg returns its default for an empty argument string'
assert_eq 'two' "$(defarg 'one two three' 1 default)" 'defarg selects a split positional word'
assert_eq 'one two three' "$(defarg 'one two three' @ default)" 'defarg @ returns every split word'
assert_eq 'default value' "$(defarg '' 0 'default value')" 'defarg preserves a multiword default'
touch "$fixture_root/glob-match"
assert_eq 'glob-*' "$(cd "$fixture_root" && defarg 'glob-* next' 0 default)" 'defarg splits without pathname expansion'

printf '1..%d\n' "$((pass_count + fail_count))"
printf '%d passed, %d failed\n' "$pass_count" "$fail_count"

if (( fail_count > 0 )); then
	exit 1
fi
