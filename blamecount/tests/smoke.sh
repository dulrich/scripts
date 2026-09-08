#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/blamecount.js"

command -v node >/dev/null 2>&1 || { printf 'blamecount smoke: node not found on PATH\n' >&2; exit 1; }
command -v git >/dev/null 2>&1 || { printf 'blamecount smoke: git not found on PATH\n' >&2; exit 1; }

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

passed=0
total=0

ok() {
	total=$((total + 1))
	passed=$((passed + 1))
	printf 'ok %d - %s\n' "$total" "$1"
}

fail() {
	total=$((total + 1))
	printf 'not ok %d - %s\n' "$total" "$1" >&2
	return 1
}

assert_eq() {
	local expected=$1
	local actual=$2
	local label=$3

	if [[ "$actual" == "$expected" ]]; then
		ok "$label"
	else
		printf 'expected: <%s>\nactual:   <%s>\n' "$expected" "$actual" >&2
		fail "$label"
	fi
}

assert_contains() {
	local haystack=$1
	local needle=$2
	local label=$3

	if [[ "$haystack" == *"$needle"* ]]; then
		ok "$label"
	else
		printf 'missing <%s> in <%s>\n' "$needle" "$haystack" >&2
		fail "$label"
	fi
}

# --- main fixture repo -------------------------------------------------
# Two authors, three-plus table languages, a non-table extension (dropped),
# a minified exclusion, a top-level stopped dir, a same-named nested dir
# that must NOT be stopped (top-level-only semantics), a filename with a
# space, a filename with a leading dash, and an uncommitted modification.

repo="$fixture/repo"
mkdir -p "$repo"
(
	cd "$repo"
	git init -q

	export GIT_AUTHOR_NAME="Alice Example"
	export GIT_AUTHOR_EMAIL="alice@example.invalid"
	export GIT_COMMITTER_NAME="Alice Example"
	export GIT_COMMITTER_EMAIL="alice@example.invalid"

	printf 'int a;\nint b;\nint c;\n' > a.c
	printf 'x = 1\ny = 2\n' > b.py
	printf '# note one\n# note two\n' > notes.md
	printf 'var a=1;\nvar b=2;\n' > foo.min.js
	mkdir -p node_modules
	printf 'ignored 1\nignored 2\n' > node_modules/x.js
	printf 's1\ns2\n' > "my file.rb"
	git add -A
	git commit -q -m 'alice: table languages, dropped extension, min-js and top-level stop exclusions'

	export GIT_AUTHOR_NAME="Bob Example"
	export GIT_AUTHOR_EMAIL="bob@example.invalid"
	export GIT_COMMITTER_NAME="Bob Example"
	export GIT_COMMITTER_EMAIL="bob@example.invalid"

	mkdir -p src/node_modules
	printf 'n1\nn2\nn3\n' > src/node_modules/y.js
	printf 'echo hi\necho bye\n' > -dash.sh
	git add -A
	git commit -q -m 'bob: nested node_modules (not top-level) and a leading-dash filename'

	# Uncommitted addition, attributed by "git blame" to the literal
	# "Not Committed Yet" author under the all-zero commit hash.
	printf 'int a;\nint b;\nint c;\nint d;\n' > a.c
)

cat > "$repo/config.json" <<CONFIG
{
	"basepath" : "$repo",
	"stopdirs" : ["node_modules"],
	"concurrency" : 2
}
CONFIG

output=$(node "$SCRIPT" --config "$repo/config.json")
status=$?

if [[ "$status" -eq 0 ]]; then
	ok 'main fixture: exit 0'
else
	fail 'main fixture: exit 0'
fi

expected=$(node -e '
const table = {
	c: 0, cc: 0, cpp: 0, cs: 0, css: 0, h: 0, htm: 0, html: 0, js: 0,
	less: 0, lua: 0, php: 0, pl: 0, py: 0, rb: 0, sh: 0, sql: 0,
};
function row(overrides) { return Object.assign({}, table, overrides); }
const totals = {
	"Alice Example": row({ c: 3, py: 2, rb: 2 }),
	"Bob Example": row({ js: 3, sh: 2 }),
	"Not Committed Yet": row({ c: 1 }),
};
process.stdout.write(JSON.stringify(totals));
')

assert_eq "$expected" "$output" \
	'main fixture: exact per-author/per-language totals (table languages counted, .md dropped, .min.js and top-level node_modules excluded, nested node_modules NOT excluded, spaced/dash filenames counted, uncommitted line under "Not Committed Yet")'

# --- forced Git failure: a "git" shim that fails "blame" for one path --

realgit=$(command -v git)
shimdir="$fixture/shimbin"
mkdir -p "$shimdir"
cat > "$shimdir/git" <<SHIM
#!/bin/bash
set -euo pipefail
is_blame=0
is_target=0
for arg in "\$@"; do
	[[ "\$arg" == "blame" ]] && is_blame=1
	[[ "\$arg" == *"a.c"* ]] && is_target=1
done
if [[ "\$is_blame" -eq 1 && "\$is_target" -eq 1 ]]; then
	printf 'fatal: shim forced blame failure for a.c\n' >&2
	exit 17
fi
exec "$realgit" "\$@"
SHIM
chmod +x "$shimdir/git"

set +e
failure_output=$(PATH="$shimdir:$PATH" node "$SCRIPT" --config "$repo/config.json" 2>&1)
failure_status=$?
set -e

if [[ "$failure_status" -ne 0 ]]; then
	ok 'forced git blame failure: nonzero exit'
else
	fail 'forced git blame failure: nonzero exit'
fi
assert_contains "$failure_output" 'a.c' 'forced git blame failure: stderr names the offending path'

# --- missing config file -----------------------------------------------

set +e
missing_config_output=$(node "$SCRIPT" --config "$fixture/does-not-exist/config.json" 2>&1)
missing_config_status=$?
set -e

if [[ "$missing_config_status" -ne 0 ]]; then
	ok 'missing config: nonzero exit'
else
	fail 'missing config: nonzero exit'
fi
assert_contains "$missing_config_output" 'does-not-exist/config.json' 'missing config: stderr names the config path'

# --- non-repo basepath ---------------------------------------------------

nonrepo="$fixture/nonrepo"
mkdir -p "$nonrepo"
printf '{ "basepath" : "%s" }' "$nonrepo" > "$nonrepo/config.json"

set +e
nonrepo_output=$(node "$SCRIPT" --config "$nonrepo/config.json" 2>&1)
nonrepo_status=$?
set -e

if [[ "$nonrepo_status" -ne 0 ]]; then
	ok 'non-repo basepath: nonzero exit'
else
	fail 'non-repo basepath: nonzero exit'
fi
assert_contains "$nonrepo_output" 'not a Git work tree' 'non-repo basepath: stderr names the failure'

# --- empty repository (no commits) --------------------------------------

emptyrepo="$fixture/emptyrepo"
mkdir -p "$emptyrepo"
git init -q "$emptyrepo"
printf '{ "basepath" : "%s" }' "$emptyrepo" > "$emptyrepo/config.json"

empty_output=$(node "$SCRIPT" --config "$emptyrepo/config.json")
empty_status=$?

if [[ "$empty_status" -eq 0 ]]; then
	ok 'empty repository: exit 0'
else
	fail 'empty repository: exit 0'
fi
assert_eq '{}' "$empty_output" 'empty repository: prints {}'

# --- nothing written under blamecount/ ----------------------------------

if [[ -e "$ROOT/config.json" ]]; then
	fail 'smoke run did not write config.json under blamecount/'
else
	ok 'smoke run did not write config.json under blamecount/'
fi

printf 'blamecount-smoke: %d/%d passed\n' "$passed" "$total"
