#!/usr/bin/env bash
# Hermetic regression tests for ../cache-prune.sh.
# Test doubles below replace sourced functions and are invoked indirectly.
# SC2034 is disabled file-wide: MODE/INCLUDE_PURGE/DOCKER_UNTIL/FAILED/
# TOTAL_BYTES/RECLAIMABLE_BYTES are globals consumed by process_runtime()
# and friends in the sourced script, which ShellCheck cannot see past the
# disabled SC1091.
# shellcheck disable=SC1091,SC2317,SC2034

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../cache-prune.sh
source "$HERE/../cache-prune.sh"

# Captured immediately after sourcing, before any test overrides the
# detect predicates, so tests can restore the real docker detect logic
# (command -v docker && docker info) without duplicating it.
ORIGINAL_RT_DOCKER_DETECT="$(declare -f rt_docker_detect)"

PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf '  ok   - %s\n' "$1"
}

bad() {
    FAIL=$((FAIL + 1))
    printf '  FAIL - %s\n' "$1"
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [[ "$actual" == "$expected" ]]; then
        ok "$label"
    else
        bad "$label (expected <$expected>, got <$actual>)"
    fi
}

assert_success() {
    local label="$1"
    shift

    if "$@"; then
        ok "$label"
    else
        bad "$label"
    fi
}

assert_failure() {
    local label="$1"
    shift

    if "$@"; then
        bad "$label"
    else
        ok "$label"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$label"
    else
        bad "$label (expected to find <$needle> in <$haystack>)"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        ok "$label"
    else
        bad "$label (did not expect to find <$needle> in <$haystack>)"
    fi
}

# --- fixture sandbox ---------------------------------------------------

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Fake, writable cache directories for the directory-backed runtimes. These
# are synthetic fixtures created fresh per test run, never real caches.
# uv/npm/pip go through the *real* rt_*_cache_dir resolvers (exercised via
# the stubbed uv/npm/pip commands below), so the tests genuinely cover
# "detection is via the tool, never a hardcoded path". bun and cargo resolve
# purely from BUN_INSTALL/CARGO_HOME env vars with no external command, so
# those are pointed at the sandbox directly.
UV_DIR="$SANDBOX/uv-cache"
NPM_DIR="$SANDBOX/npm-cache"
PIP_DIR="$SANDBOX/pip-cache"
export BUN_INSTALL="$SANDBOX/bun-install"
export CARGO_HOME="$SANDBOX/cargo-home"
BUN_DIR="$BUN_INSTALL/install/cache"
CARGO_DIR="$CARGO_HOME/registry"
mkdir -p "$UV_DIR" "$NPM_DIR" "$PIP_DIR" "$BUN_DIR" "$CARGO_DIR"

# All six detect predicates default to "present"; individual tests flip
# specific ones back to "absent" (return 1) for isolation. docker restores
# the *real* rt_docker_detect (command -v docker && docker info) rather than
# a trivial stub, so scenarios using all_present still genuinely exercise
# the docker preflight against the stubbed `docker` command/$DOCKER_INFO_RESULT.
all_present() {
    rt_uv_detect() { return 0; }
    rt_npm_detect() { return 0; }
    eval "$ORIGINAL_RT_DOCKER_DETECT"
    rt_pip_detect() { return 0; }
    rt_bun_detect() { return 0; }
    rt_cargo_detect() { return 0; }
}

all_absent() {
    rt_uv_detect() { return 1; }
    rt_npm_detect() { return 1; }
    rt_docker_detect() { return 1; }
    rt_pip_detect() { return 1; }
    rt_bun_detect() { return 1; }
    rt_cargo_detect() { return 1; }
}

# --- command-log doubles -------------------------------------------------
#
# ALL_LOG captures every stubbed external call (detection/resolution/size
# probes included). MUTATE_LOG captures only the calls that would actually
# change a cache on disk or in the daemon. A `--report` run must produce an
# empty MUTATE_LOG while still populating ALL_LOG.
#
# ALL_LOG is file-backed rather than an in-memory variable: the production
# code reads several of these commands via `x=$(cmd)` command substitution
# (cache-dir resolvers, `docker system df -v`), and each substitution
# forks a subshell -- a plain shell-variable append made *inside* that
# subshell would vanish the instant the substitution completes. A real file
# survives the subshell boundary. The mutating calls (prune/purge/builder
# prune) are all invoked as bare statements in the production code, never
# captured via `$()`, so MUTATE_LOG/CONFIRM_LOG are safe as plain variables.
ALL_LOG_FILE="$SANDBOX/all.log"
: > "$ALL_LOG_FILE"
all_log() { cat "$ALL_LOG_FILE" 2>/dev/null; }

MUTATE_LOG=""
CONFIRM_LOG=""
CONFIRM_RESULT=1

DOCKER_SYSTEM_DF_FIXTURE=""
DOCKER_INFO_RESULT=0
DOCKER_PRUNE_RESULT=0
UV_PRUNE_RESULT=0
NPM_PRUNE_RESULT=0
PIP_PRUNE_RESULT=0
BUN_PRUNE_RESULT=0

# NPM_CACHE_DIR_MODE drives `npm config get cache`'s stubbed behaviour, to
# exercise the exit-1 (hard failure) vs exit-2 (unresolvable) distinction in
# rt_npm_cache_dir():
#   ok        -> prints $NPM_DIR (default)
#   undefined -> prints the literal "undefined" (measured real-world npm
#                behaviour), which rt_npm_cache_dir() must turn into a
#                graceful skip (exit 2), not a failure
#   error     -> npm itself exits nonzero, a genuine hard failure (exit 1)
NPM_CACHE_DIR_MODE=ok

reset_logs() {
    : > "$ALL_LOG_FILE"
    MUTATE_LOG=""
    CONFIRM_LOG=""
    CONFIRM_RESULT=1
    UV_PRUNE_RESULT=0
    NPM_PRUNE_RESULT=0
    PIP_PRUNE_RESULT=0
    BUN_PRUNE_RESULT=0
    DOCKER_PRUNE_RESULT=0
    NPM_CACHE_DIR_MODE=ok
}

confirm() {
    CONFIRM_LOG+="$1|"
    return "$CONFIRM_RESULT"
}

uv() {
    printf 'uv %s|' "$*" >> "$ALL_LOG_FILE"
    case "$1 $2" in
        "cache prune")
            MUTATE_LOG+="uv $*|"
            return "$UV_PRUNE_RESULT"
            ;;
        "cache dir")
            printf '%s\n' "$UV_DIR"
            ;;
    esac
    return 0
}

npm() {
    printf 'npm %s|' "$*" >> "$ALL_LOG_FILE"
    case "$1 $2" in
        "cache verify")
            MUTATE_LOG+="npm $*|"
            return "$NPM_PRUNE_RESULT"
            ;;
        "config get")
            case "$NPM_CACHE_DIR_MODE" in
                error)
                    return 1
                    ;;
                undefined)
                    printf 'undefined\n'
                    ;;
                *)
                    printf '%s\n' "$NPM_DIR"
                    ;;
            esac
            ;;
    esac
    return 0
}

pip() {
    printf 'pip %s|' "$*" >> "$ALL_LOG_FILE"
    case "$1 $2" in
        "cache purge")
            MUTATE_LOG+="pip $*|"
            return "$PIP_PRUNE_RESULT"
            ;;
        "cache dir")
            printf '%s\n' "$PIP_DIR"
            ;;
    esac
    return 0
}

bun() {
    printf 'bun %s|' "$*" >> "$ALL_LOG_FILE"
    case "$1 $2" in
        "pm cache")
            MUTATE_LOG+="bun $*|"
            return "$BUN_PRUNE_RESULT"
            ;;
    esac
    return 0
}

docker() {
    printf 'docker %s|' "$*" >> "$ALL_LOG_FILE"
    case "$1" in
        info)
            return "$DOCKER_INFO_RESULT"
            ;;
        system)
            printf '%s\n' "$DOCKER_SYSTEM_DF_FIXTURE"
            return 0
            ;;
        builder)
            MUTATE_LOG+="docker $*|"
            return "$DOCKER_PRUNE_RESULT"
            ;;
    esac
    return 0
}

# A minimal, synthetic (no real machine) docker system df -v fixture. Window
# default is 168h == 604800s.
#   row 1: 10MB,  last used 200 hours ago (720000s, >= window) -> included
#   row 2: 512kB, last used 10 minutes ago (600s, < window)    -> excluded
#   row 3: 1GB,   last used 9 days ago (777600s, >= window)    -> included
#   row 4: 100B,  last used 30 minutes ago (1800s, < window)   -> excluded
DOCKER_DF_FIXTURE=$'Build cache usage: 0B\n\nCACHE ID       CACHE TYPE     SIZE      CREATED       LAST USED       USAGE     SHARED\naaaa1111aaaa   regular        10MB      2 weeks ago   200 hours ago   0         false\nbbbb2222bbbb   regular        512kB     3 days ago    10 minutes ago  1         true\ncccc3333cccc   regular        1GB       5 weeks ago   9 days ago      0         false\ndddd4444dddd   regular        100B      1 hours ago   30 minutes ago  2         true\n'
DOCKER_DF_EXPECTED_BYTES=1010000000

# --- tests ---------------------------------------------------------------

echo "[require_not_root] root refusal"
assert_failure "root EUID is refused" require_not_root 0
assert_success "non-root EUID is accepted" require_not_root 1000

echo "[detect] graceful skip when a runtime is absent"
all_absent
reset_logs
FAILED=0
MODE="report"
process_runtime uv >/dev/null 2>&1 || true
assert_eq "" "$(all_log)" "no external calls made for an absent runtime"
assert_eq "0" "$FAILED" "an absent runtime is a skip, not a failure"

echo "[cache-dir resolver] unresolvable result (exit 2) is a skip, not a failure"
# Regression test for a real bug caught in review: `$?` right after a
# negated `if ! cache_dir=$(...); then` reflects the negation's status, not
# the resolver's -- always 0, never the resolver's real exit code. That made
# the exit-2 "unresolvable, skip" branch unreachable in practice. As with
# the "partial failure" block below, output is captured via a file rather
# than `$(process_runtime ...)`, since wrapping the call itself in a command
# substitution would fork a subshell and lose the FAILED/MUTATE_LOG
# mutations we need to assert on afterward.
RESOLVER_OUTPUT_FILE="$SANDBOX/resolver-output.log"
all_present
reset_logs
FAILED=0
NPM_CACHE_DIR_MODE=undefined
MODE="report"
: > "$RESOLVER_OUTPUT_FILE"
process_runtime npm >"$RESOLVER_OUTPUT_FILE" 2>&1 || true
output="$(cat "$RESOLVER_OUTPUT_FILE")"
assert_contains "$output" "skip: npm cache location unresolved" "an unresolvable npm cache dir prints the skip message"
assert_eq "" "$MUTATE_LOG" "an unresolvable npm cache dir performs no mutation"
assert_eq "0" "$FAILED" "an unresolvable npm cache dir (exit 2) does not set FAILED"
NPM_CACHE_DIR_MODE=ok

echo "[cache-dir resolver] a hard resolver failure (exit 1) is a real failure"
all_present
reset_logs
FAILED=0
NPM_CACHE_DIR_MODE=error
MODE="report"
: > "$RESOLVER_OUTPUT_FILE"
process_runtime npm >"$RESOLVER_OUTPUT_FILE" 2>&1 || true
output="$(cat "$RESOLVER_OUTPUT_FILE")"
assert_contains "$output" "WARNING: npm: failed to resolve cache location" "a hard npm resolver failure warns"
assert_eq "1" "$FAILED" "a hard npm resolver failure (exit 1) sets FAILED"
NPM_CACHE_DIR_MODE=ok

echo "[docker] daemon-down is a skip, not a failure"
all_absent
eval "$ORIGINAL_RT_DOCKER_DETECT"
DOCKER_INFO_RESULT=1
reset_logs
FAILED=0
MODE="report"
process_runtime docker >/dev/null 2>&1 || true
DOCKER_INFO_RESULT=0
assert_not_contains "$(all_log)" "docker system" "daemon-down docker never reaches df -v"
assert_not_contains "$MUTATE_LOG" "docker builder" "daemon-down docker never prunes"
assert_eq "0" "$FAILED" "daemon-down docker is a skip, not a failure"

echo "[--report] mutates nothing but does probe"
all_present
reset_logs
FAILED=0
TOTAL_BYTES=0
RECLAIMABLE_BYTES=0
DOCKER_INFO_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_DF_FIXTURE"
MODE="report"
INCLUDE_PURGE=false
DOCKER_UNTIL="168h"
REPORT_OUTPUT_FILE="$SANDBOX/report-output.log"
: > "$REPORT_OUTPUT_FILE"
for rt in "${RUNTIME_ORDER[@]}"; do
    process_runtime "$rt" >>"$REPORT_OUTPUT_FILE" 2>&1 || true
done
report_output="$(cat "$REPORT_OUTPUT_FILE")"
assert_eq "" "$MUTATE_LOG" "--report performs no mutating calls"
assert_contains "$(all_log)" "npm config get cache" "npm cache location is resolved during report"
assert_contains "$(all_log)" "pip cache dir" "pip cache location is resolved during report"
assert_contains "$report_output" "reclaimable (" "size probe runs during report and prints both total and reclaimable figures"
assert_contains "$(all_log)" "docker info" "docker preflight runs during report"
assert_contains "$(all_log)" "docker system df" "docker size parse runs during report"

echo "[--yes] safe prunes fire; opt-in purges do not, and are never prompted"
all_present
reset_logs
FAILED=0
DOCKER_INFO_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_DF_FIXTURE"
MODE="yes"
INCLUDE_PURGE=false
DOCKER_UNTIL="168h"
for rt in "${RUNTIME_ORDER[@]}"; do
    process_runtime "$rt" >/dev/null 2>&1 || true
done
assert_contains "$MUTATE_LOG" "uv cache prune" "uv is pruned under --yes"
assert_contains "$MUTATE_LOG" "npm cache verify" "npm is pruned under --yes"
assert_contains "$MUTATE_LOG" "docker builder prune" "docker is pruned under --yes"
assert_not_contains "$MUTATE_LOG" "pip cache purge" "--yes alone never purges pip (load-bearing)"
assert_not_contains "$MUTATE_LOG" "bun pm cache" "--yes alone never purges bun (load-bearing)"
assert_not_contains "$CONFIRM_LOG" "pip" "pip is never prompted under --yes alone"
assert_not_contains "$CONFIRM_LOG" "bun" "bun is never prompted under --yes alone"

echo "[--yes --include-purge] opt-in purges fire too"
all_present
reset_logs
FAILED=0
DOCKER_INFO_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_DF_FIXTURE"
MODE="yes"
INCLUDE_PURGE=true
DOCKER_UNTIL="168h"
for rt in "${RUNTIME_ORDER[@]}"; do
    process_runtime "$rt" >/dev/null 2>&1 || true
done
assert_contains "$MUTATE_LOG" "pip cache purge" "pip is purged under --yes --include-purge"
assert_contains "$MUTATE_LOG" "bun pm cache" "bun is purged under --yes --include-purge"

echo "[interactive] purge prompts default to No; a declined prompt executes nothing"
all_present
reset_logs
FAILED=0
CONFIRM_RESULT=1
MODE="interactive"
INCLUDE_PURGE=false
process_runtime pip >/dev/null 2>&1 || true
process_runtime bun >/dev/null 2>&1 || true
assert_contains "$CONFIRM_LOG" "pip" "interactive mode prompts for pip"
assert_contains "$CONFIRM_LOG" "bun" "interactive mode prompts for bun"
assert_eq "" "$MUTATE_LOG" "a declined interactive purge prompt executes nothing"

echo "[interactive] a declined safe-prune confirm executes nothing"
all_present
reset_logs
FAILED=0
CONFIRM_RESULT=1
MODE="interactive"
process_runtime uv >/dev/null 2>&1 || true
assert_contains "$CONFIRM_LOG" "uv" "interactive mode prompts for uv"
assert_eq "" "$MUTATE_LOG" "a declined interactive safe-prune executes nothing"

echo "[interactive] an accepted safe-prune confirm executes"
all_present
reset_logs
FAILED=0
CONFIRM_RESULT=0
MODE="interactive"
process_runtime uv >/dev/null 2>&1 || true
assert_contains "$MUTATE_LOG" "uv cache prune" "an accepted interactive confirm prunes uv"

echo "[docker] --docker-until is honoured by the prune filter"
all_present
reset_logs
FAILED=0
DOCKER_INFO_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_DF_FIXTURE"
MODE="yes"
DOCKER_UNTIL="24h"
process_runtime docker >/dev/null 2>&1 || true
assert_contains "$MUTATE_LOG" "until=24h" "docker prune filter reflects --docker-until"

DOCKER_UNTIL="168h"

echo "[docker parse] age-filtered byte sum, with unit normalization"
window_seconds="$(docker_window_seconds "168h")"
assert_eq "604800" "$window_seconds" "168h converts to 604800 seconds"
bytes="$(docker_build_cache_bytes "$DOCKER_DF_FIXTURE" "$window_seconds")"
assert_eq "$DOCKER_DF_EXPECTED_BYTES" "$bytes" "kB/MB/GB rows normalize and sum correctly, excluding rows younger than the window"

echo "[docker parse] unparseable table reports unavailable, never a guess"
all_present
reset_logs
FAILED=0
DOCKER_INFO_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE=$'Images space usage:\n\nno build-cache table here at all\n'
MODE="report"
process_runtime docker >/dev/null 2>&1 || true
size_out="$(rt_docker_size "")"
assert_eq "unavailable" "$size_out" "an unparseable docker df table reports unavailable"

echo "[rt_generic_size] inode-complete link census"
# A real fixture tree under the sandbox (itself `mktemp -d`), with actual
# `ln` hardlinks -- trap-cleaned by the sandbox's own EXIT trap. Byte counts
# are synthetic and small (no real machine cache sizes), chosen distinct
# enough to catch a total/reclaimable mixup.

CENSUS_PLAIN="$SANDBOX/census-plain"
mkdir -p "$CENSUS_PLAIN"
head -c 111 /dev/zero > "$CENSUS_PLAIN/plain.bin"
assert_eq "111 111" "$(rt_generic_size "$CENSUS_PLAIN")" \
    "a plain unlinked file counts toward both total and reclaimable"

CENSUS_SHARED="$SANDBOX/census-shared"
mkdir -p "$CENSUS_SHARED"
head -c 222 /dev/zero > "$CENSUS_SHARED/a.bin"
ln "$CENSUS_SHARED/a.bin" "$CENSUS_SHARED/b.bin"
assert_eq "222 222" "$(rt_generic_size "$CENSUS_SHARED")" \
    "a file hardlinked twice inside the tree counts once toward total and is fully reclaimable"

CENSUS_EXTERNAL="$SANDBOX/census-external"
CENSUS_EXTERNAL_OUTSIDE="$SANDBOX/census-external-outside"
mkdir -p "$CENSUS_EXTERNAL" "$CENSUS_EXTERNAL_OUTSIDE"
head -c 333 /dev/zero > "$CENSUS_EXTERNAL/inside.bin"
ln "$CENSUS_EXTERNAL/inside.bin" "$CENSUS_EXTERNAL_OUTSIDE/outside.bin"
assert_eq "333 0" "$(rt_generic_size "$CENSUS_EXTERNAL")" \
    "a file with an additional link outside the tree counts toward total but contributes zero to reclaimable"

CENSUS_EMPTY="$SANDBOX/census-empty"
mkdir -p "$CENSUS_EMPTY"
assert_eq "0 0" "$(rt_generic_size "$CENSUS_EMPTY")" "an empty directory returns 0 0"
assert_eq "0 0" "$(rt_generic_size "$SANDBOX/census-does-not-exist")" "a nonexistent path returns 0 0"

echo "[process_runtime] prints both figures; footprint and reclaimable totals accumulate independently"
all_present
reset_logs
FAILED=0
TOTAL_BYTES=0
RECLAIMABLE_BYTES=0
MODE="report"
PROCESS_RUNTIME_OUTPUT_FILE="$SANDBOX/process-runtime-output.log"

# A fully-shared cache double: 500 bytes present, 0 reclaimable -- as if
# every byte were hardlinked into something outside the cache dir (e.g. a
# live venv). Proves the footprint total moves without the reclaimable
# total moving.
rt_size_all_shared() { printf '500 0\n'; }
RT_SIZE["uv"]=rt_size_all_shared

: > "$PROCESS_RUNTIME_OUTPUT_FILE"
process_runtime uv >"$PROCESS_RUNTIME_OUTPUT_FILE" 2>&1 || true
process_runtime_output="$(cat "$PROCESS_RUNTIME_OUTPUT_FILE")"
assert_contains "$process_runtime_output" "500.0B total (500 bytes)" "process_runtime prints the total figure"
assert_contains "$process_runtime_output" "0.0B reclaimable (0 bytes)" "process_runtime prints the reclaimable figure"
assert_eq "500" "$TOTAL_BYTES" "a fully-shared runtime still advances the footprint total"
assert_eq "0" "$RECLAIMABLE_BYTES" "a fully-shared runtime does not advance the reclaimable total"

RT_SIZE["uv"]=rt_generic_size

echo "[process_runtime] the unavailable path still bypasses both accumulators"
all_present
reset_logs
FAILED=0
TOTAL_BYTES=12345
RECLAIMABLE_BYTES=6789
MODE="report"
rt_size_unavailable() { printf 'unavailable\n'; }
RT_SIZE["uv"]=rt_size_unavailable
process_runtime uv >/dev/null 2>&1 || true
assert_eq "12345" "$TOTAL_BYTES" "an unavailable size probe leaves the footprint total untouched"
assert_eq "6789" "$RECLAIMABLE_BYTES" "an unavailable size probe leaves the reclaimable total untouched"
RT_SIZE["uv"]=rt_generic_size
TOTAL_BYTES=0
RECLAIMABLE_BYTES=0

echo "[cargo] report-only, never mutates"
all_present
reset_logs
FAILED=0
MODE="yes"
INCLUDE_PURGE=true
process_runtime cargo >/dev/null 2>&1 || true
assert_eq "" "$MUTATE_LOG" "cargo never has a mutating call, even under --yes --include-purge"
assert_eq "" "${RT_PRUNE[cargo]+set}" "cargo intentionally has no prune-registry entry"

echo "[partial failure] one failing runtime warns and is skipped; others still run; exit is nonzero"
all_present
reset_logs
FAILED=0
TOTAL_BYTES=0
RECLAIMABLE_BYTES=0
DOCKER_INFO_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_DF_FIXTURE"
UV_PRUNE_RESULT=1
MODE="yes"
INCLUDE_PURGE=false
DOCKER_UNTIL="168h"
# stderr goes to a file, not a command substitution, so that FAILED/
# MUTATE_LOG mutations made by process_runtime in this same shell are not
# lost to a subshell the way an outer $( ... ) around the loop would lose
# them (see the ALL_LOG comment above for the same subshell pitfall).
WARN_FILE="$SANDBOX/warnings.log"
: > "$WARN_FILE"
for rt in "${RUNTIME_ORDER[@]}"; do
    process_runtime "$rt" 1>/dev/null 2>>"$WARN_FILE" || true
done
warnings="$(cat "$WARN_FILE")"
assert_contains "$warnings" "uv: prune failed" "a failing prune emits a named warning"
assert_contains "$MUTATE_LOG" "npm cache verify" "other runtimes still process after one fails"
assert_contains "$MUTATE_LOG" "docker builder prune" "docker still processes after uv fails"
assert_eq "1" "$FAILED" "aggregate failure flag is set"

reset_logs
FAILED=0
TOTAL_BYTES=0
RECLAIMABLE_BYTES=0
UV_PRUNE_RESULT=1
DOCKER_INFO_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_DF_FIXTURE"
total_line="$( {
    for rt in "${RUNTIME_ORDER[@]}"; do
        process_runtime "$rt" || true
    done
    section "Total"
    printf 'Total cache footprint seen: %s (%d bytes)\n' "$(human_bytes "$TOTAL_BYTES")" "$TOTAL_BYTES"
} 2>/dev/null | grep 'Total cache footprint' )"
assert_contains "$total_line" "Total cache footprint seen:" "grand total is still printed after a partial failure"
UV_PRUNE_RESULT=0

echo "[argument parsing] unknown flags exit 2 via usage"
set +e
( main --bogus-flag >/dev/null 2>&1 )
status=$?
set -e
assert_eq "2" "$status" "an unknown flag exits 2"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
