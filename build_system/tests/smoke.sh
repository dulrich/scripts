#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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

assert_true() {
	local cond_desc=$1
	local result=$2
	local label=$3

	if [[ "$result" == "true" ]]; then
		ok "$label"
	else
		printf 'condition failed: %s\n' "$cond_desc" >&2
		fail "$label"
	fi
}

# ---------------------------------------------------------------------------
# 1. Generate a project into a temp dir with the current mkproject.sh and
#    characterize the resulting layout: parts/ is the only C source layer
#    carried into the generated project, alongside _build.c.
# ---------------------------------------------------------------------------
proj="$fixture/proj"
bash "$ROOT/mkproject.sh" -x smoke "$proj"

if [[ -f "$proj/_build.c" && -d "$proj/parts" ]]; then
	ok "generated layout carries _build.c and a parts/ directory"
else
	fail "generated layout carries _build.c and a parts/ directory"
fi

# No stray top-level files: the retired concatenation mechanism (and
# anything else unexpected) is absent, not just the files this test names.
# expected: _build.c build-flags.sh build.sh debug.sh profiling.sh valgrind
# valgrind.sh .gitignore, plus the parts/, src/, build/ directories.
top_level_count=$(find "$proj" -mindepth 1 -maxdepth 1 | wc -l)
assert_eq '11' "$top_level_count" "generated project root has no unexpected top-level entries"

for f in build.sh debug.sh profiling.sh valgrind valgrind.sh build-flags.sh; do
	if [[ -f "$proj/$f" ]]; then
		ok "generated project carries entry point $f"
	else
		fail "generated project carries entry point $f"
	fi
done

if [[ -f "$proj/src/smoke.c" ]]; then
	ok "generated project carries source at src/smoke.c"
else
	fail "generated project carries source at src/smoke.c"
fi

if diff -rq "$ROOT/parts" "$proj/parts" >/dev/null 2>&1; then
	ok "generated parts/ is a byte-identical copy of the canonical parts/"
else
	fail "generated parts/ is a byte-identical copy of the canonical parts/"
fi

# Every sed_files target must be fully substituted: no __SED_TOKEN_ left in
# _build.c or the copied entry points, except build.sh's own literal
# template-detection string, which must be preserved unsubstituted.
for f in _build.c debug.sh profiling.sh valgrind valgrind.sh build-flags.sh; do
	if ! grep -q '__SED_TOKEN_' "$proj/$f"; then
		ok "$f has no unsubstituted __SED_TOKEN_ placeholders"
	else
		fail "$f has no unsubstituted __SED_TOKEN_ placeholders"
	fi
done

if grep -q "grep -q '__SED_TOKEN_' _build.c" "$proj/build.sh"; then
	ok "build.sh retains its own template-detection literal unmodified"
else
	fail "build.sh retains its own template-detection literal unmodified"
fi

if ! grep -rq '__SED_TOKEN_' "$proj/parts"; then
	ok "generated parts/ carries no __SED_TOKEN_ placeholders (none expected)"
else
	fail "generated parts/ carries no __SED_TOKEN_ placeholders (none expected)"
fi

# Generated projects are self-contained: nothing in the copies references
# back into this scripts repo checkout at build time.
if ! grep -rl "$ROOT" "$proj" >/dev/null 2>&1; then
	ok "generated project carries no path reference back into the source repo"
else
	fail "generated project carries no path reference back into the source repo"
fi

# ---------------------------------------------------------------------------
# 2. Build and run the freshly generated project.
# ---------------------------------------------------------------------------
(cd "$proj" && bash ./build.sh >/dev/null)
initial_output=$("$proj/smoke")
assert_eq 'Hello, Broken World!' "$initial_output" "fresh build runs and prints the sample greeting"

# ---------------------------------------------------------------------------
# 3. Modify the generated source; rebuild; the executable's output changes.
#    This is check_source()'s mtime-based incremental path (gcc.c); fs.c
#    truncates mtimes to whole seconds (st_mtim.tv_sec), so the edit must
#    land in a later second than the object file it must invalidate.
# ---------------------------------------------------------------------------
sleep 1
cat > "$proj/src/smoke.c" <<'SRC'
#include <stdio.h>

int main(int argc, char* argv[]) {
	printf("Hello, Fixed World!\n");
	return 0;
}
SRC

(cd "$proj" && bash ./build.sh >/dev/null)
source_edit_output=$("$proj/smoke")
assert_eq 'Hello, Fixed World!' "$source_edit_output" "rebuild after source edit changes executable output"

# ---------------------------------------------------------------------------
# 4. Modify one canonical part (harmless comment only, no behavior change);
#    rebuild. "Recompile" for a part edit is observably different from a
#    source edit: build.sh always fully recompiles the _build.c translation
#    unit unconditionally on every invocation (there is no incremental cache
#    at that level, unlike check_source()'s per-source-file mtime check), so
#    a part edit is picked up automatically. The observable proof is that
#    the builder binary is freshly rebuilt (its mtime advances), not that
#    program output changes, since a comment-only edit is behaviorally inert
#    and gcc's output for identical object code can be byte-for-byte stable.
# ---------------------------------------------------------------------------
pre_mtime=$(stat -c %Y "$proj/._build")
sleep 1
printf '\n// smoke-test: harmless canonical-part comment\n' >> "$proj/parts/gcc.c"
(cd "$proj" && bash ./build.sh >/dev/null)
post_mtime=$(stat -c %Y "$proj/._build")

if [[ "$post_mtime" -gt "$pre_mtime" ]]; then
	ok "editing a canonical part causes the next build.sh to recompile the builder"
else
	fail "editing a canonical part causes the next build.sh to recompile the builder"
fi

part_edit_output=$("$proj/smoke")
assert_eq 'Hello, Fixed World!' "$part_edit_output" \
	"harmless canonical-part edit does not change executable behavior"

# ---------------------------------------------------------------------------
# 5. Exercise the corrected pkg-config failure path (parts/pkgconfig.c).
#
# A fake/missing pkg-config placed first on PATH cannot reach this branch:
# popen() forks and execs "/bin/sh -c <command>" and returns a valid stream
# whether or not the inner command exists or fails - only pipe()/fork()
# failure inside popen() itself yields NULL. The controlled stub here is an
# LD_PRELOAD shim that makes popen() always return NULL, deterministically
# driving pkg_config() into the corrected error path regardless of what is
# on PATH. lib_headers_needed starts empty in a fresh project, so it is
# edited here (in this fixture's generated copy only) to reach popen() at
# all. MALLOC_PERTURB_ poisons freed memory on free(), turning a
# use-after-free of the freed command string into visibly corrupted output
# instead of an accidental pass - this is what the fix in parts/pkgconfig.c
# (free after last use on both paths) is verified against.
# ---------------------------------------------------------------------------
sed -i '/^char\* lib_headers_needed\[\] = {$/,/^};$/ s/^\tNULL$/\t"smoke-test-missing-pkg",\n\tNULL/' \
	"$proj/_build.c"

if [[ $(grep -c 'smoke-test-missing-pkg' "$proj/_build.c") -eq 1 ]]; then
	ok "fixture injects one lib_headers_needed entry to reach pkg_config()'s popen() call"
else
	fail "fixture injects one lib_headers_needed entry to reach pkg_config()'s popen() call"
fi

(cd "$proj" && bash ./build.sh >/dev/null)

cat > "$fixture/popen_fail_shim.c" <<'SHIM'
#include <stdio.h>
FILE* popen(const char* command, const char* type) {
	(void)command;
	(void)type;
	return NULL;
}
SHIM
gcc -shared -fPIC -o "$fixture/popen_fail.so" "$fixture/popen_fail_shim.c"

set +e
failure_output=$(MALLOC_PERTURB_=165 LD_PRELOAD="$fixture/popen_fail.so" "$proj/._build" 2>&1)
failure_status=$?
set -e

assert_eq '1' "$failure_status" "forced popen() failure exits status 1, not a crash signal"
assert_contains "$failure_output" "Could not run command 'pkg-config --cflags smoke-test-missing-pkg'" \
	"error message names the pkg-config command uncorrupted under MALLOC_PERTURB_"

printf 'build-system smoke: %d/%d passed\n' "$passed" "$total"
