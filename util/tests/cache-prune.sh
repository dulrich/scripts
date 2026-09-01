#!/usr/bin/env bash
# Hermetic regression tests for ../cache-prune.sh.
# Test doubles below replace sourced functions and are invoked indirectly.
# SC2034 is disabled file-wide: MODE/INCLUDE_PURGE/DOCKER_UNTIL/FAILED/
# TOTAL_BYTES/SAFE_RECLAIMABLE_BYTES/PURGE_RECLAIMABLE_BYTES/DELTA_BYTES are
# globals consumed by process_runtime() and friends in the sourced script,
# which ShellCheck cannot see past the disabled SC1091.
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

DOCKER_BUILDX_DU_FIXTURE=""
DOCKER_BUILDX_DU_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE=""
DOCKER_SYSTEM_DF_RESULT=0
DOCKER_INFO_RESULT=0
DOCKER_PRUNE_RESULT=0
UV_PRUNE_RESULT=0
UV_PURGE_RESULT=0
NPM_PRUNE_RESULT=0
NPM_PURGE_RESULT=0
PIP_PURGE_RESULT=0
BUN_PURGE_RESULT=0

# NPM_CACHE_DIR_MODE drives `npm config get cache`'s stubbed behaviour, to
# exercise the exit-1 (hard failure) vs exit-2 (unresolvable) distinction in
# rt_npm_cache_dir():
#   ok        -> prints $NPM_DIR (default)
#   undefined -> prints the literal "undefined" (measured real-world npm
#                behaviour), which rt_npm_cache_dir() must turn into a
#                graceful skip (exit 2), not a failure
#   error     -> npm itself exits nonzero, a genuine hard failure (exit 1)
NPM_CACHE_DIR_MODE=ok

# --- sequenced-probe infrastructure (WP-3) --------------------------------
#
# A before/after delta test needs a probe that returns a DIFFERENT value on
# its second call than its first. A plain shell counter/index cannot do
# this: process_runtime invokes a probe via `size_out=$("$size_fn" ...)`,
# which forks a subshell to capture stdout, and any mutation the probe makes
# to its own call-position state is lost the instant that subshell exits --
# the identical hazard ALL_LOG_FILE above exists to work around. So, like
# ALL_LOG_FILE, the queue itself is file-backed: each call pops the file's
# first line, a mutation any subshell can make and have survive it, since
# it lands on the real filesystem rather than in shell memory.
SEQ_FILE="$SANDBOX/probe-sequence.log"
: > "$SEQ_FILE"

# queue_probe_sequence: load one "<total> <reclaimable>" (or "unavailable")
# string per probe call, in call order. Pair with `RT_SIZE[<name>]=rt_size_from_queue`.
queue_probe_sequence() {
    printf '%s\n' "$@" > "$SEQ_FILE"
}

rt_size_from_queue() {
    local line
    line=$(head -n1 "$SEQ_FILE" 2>/dev/null)
    sed -i '1d' "$SEQ_FILE" 2>/dev/null || true
    printf '%s\n' "$line"
}

# DOCKER_SYSTEM_DF_CALL_FILE / DOCKER_SYSTEM_DF_FAIL_AFTER: the same
# file-backed-counter idea, specialised for the docker source-match tests --
# lets a test force `docker system df` to succeed on the before-probe (call
# 0) and fail on the after-probe (call 1+), so rt_docker_size's primary
# source genuinely changes between the two real calls process_runtime makes
# inside a single process_runtime invocation, with no way for the test to
# "step in" between them (both happen inside process_runtime's own call).
# Empty/unset FAIL_AFTER means "never fail" (today's behaviour, unchanged).
DOCKER_SYSTEM_DF_CALL_FILE="$SANDBOX/docker-system-df-calls.log"
: > "$DOCKER_SYSTEM_DF_CALL_FILE"
DOCKER_SYSTEM_DF_FAIL_AFTER=""

reset_logs() {
    : > "$ALL_LOG_FILE"
    MUTATE_LOG=""
    CONFIRM_LOG=""
    CONFIRM_RESULT=1
    UV_PRUNE_RESULT=0
    UV_PURGE_RESULT=0
    NPM_PRUNE_RESULT=0
    NPM_PURGE_RESULT=0
    PIP_PURGE_RESULT=0
    BUN_PURGE_RESULT=0
    DOCKER_PRUNE_RESULT=0
    DOCKER_BUILDX_DU_RESULT=0
    DOCKER_SYSTEM_DF_RESULT=0
    NPM_CACHE_DIR_MODE=ok
    : > "$SEQ_FILE"
    : > "$DOCKER_SYSTEM_DF_CALL_FILE"
    DOCKER_SYSTEM_DF_FAIL_AFTER=""
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
        "cache clean")
            MUTATE_LOG+="uv $*|"
            return "$UV_PURGE_RESULT"
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
        "cache clean")
            MUTATE_LOG+="npm $*|"
            return "$NPM_PURGE_RESULT"
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
            return "$PIP_PURGE_RESULT"
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
            return "$BUN_PURGE_RESULT"
            ;;
    esac
    return 0
}

# Matched on the full argument string ($*), not just $1: plain `docker
# system df` (the fallback) and `docker system df -v` (the retiring
# verbose table) must be told apart, or a bug that regresses rt_docker_size
# back to -v would silently read the still-present system-df fixture
# instead of failing loudly.
docker() {
    printf 'docker %s|' "$*" >> "$ALL_LOG_FILE"
    case "$*" in
        info)
            return "$DOCKER_INFO_RESULT"
            ;;
        "buildx du")
            printf '%s\n' "$DOCKER_BUILDX_DU_FIXTURE"
            return "$DOCKER_BUILDX_DU_RESULT"
            ;;
        "system df")
            # DOCKER_SYSTEM_DF_FAIL_AFTER lets a test force this call to
            # fail from a given 0-based call index onward -- see the
            # sequenced-probe infrastructure above. Unset/empty (the
            # default): never fails here, today's behaviour.
            if [[ -n "$DOCKER_SYSTEM_DF_FAIL_AFTER" ]]; then
                local df_call_n
                df_call_n=$(wc -l < "$DOCKER_SYSTEM_DF_CALL_FILE")
                printf '.\n' >> "$DOCKER_SYSTEM_DF_CALL_FILE"
                if ((df_call_n >= DOCKER_SYSTEM_DF_FAIL_AFTER)); then
                    return 1
                fi
            fi
            printf '%s\n' "$DOCKER_SYSTEM_DF_FIXTURE"
            return "$DOCKER_SYSTEM_DF_RESULT"
            ;;
        "system df -v")
            # Production code no longer requests -v; deliberately not
            # wired to either fixture so an accidental regression fails
            # loudly instead of silently misreading data.
            return 1
            ;;
        builder*)
            MUTATE_LOG+="docker $*|"
            return "$DOCKER_PRUNE_RESULT"
            ;;
    esac
    return 0
}

# Synthetic (no real machine) `docker buildx du` fixture: a per-record
# table -- one row carrying the `*` shared-marker suffix on its own SIZE
# field -- followed by the trailing "Label:<whitespace>value" summary
# lines rt_docker_size actually parses. The varying tab-stop padding
# ("Shared:" gets two tabs, "Private:" one, to align differing label
# lengths) is deliberate: it is exactly what a label-anchored, field-split
# parse must tolerate.
DOCKER_BUILDX_DU_FIXTURE_OK=$'ID             RECLAIMABLE  SIZE       LAST ACCESSED\naaaa1111aaaa   true         2.5GB*     3 days ago\nbbbb2222bbbb   true         500MB      10 days ago\nShared:\t\t2.5GB\nPrivate:\t8GB\nReclaimable:\t4GB\nTotal:\t\t10GB\n'
DOCKER_BUILDX_DU_EXPECTED_BYTES="10000000000 4000000000"

# Synthetic fallback `docker system df` (plain, non -v) fixture: "Build
# Cache" is a two-word label, exercising the $3..$6 field-offset trap, and
# every RECLAIMABLE cell (including Build Cache's own) carries a trailing
# "(NN%)" to exercise the defensive percentage strip.
DOCKER_SYSTEM_DF_FIXTURE_OK=$'TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE\nImages          12        4         3.2GB     1.1GB (34%)\nContainers      5         2         50MB      10MB (20%)\nLocal Volumes   8         3         500MB     50MB (10%)\nBuild Cache     42        0         10GB      6GB (60%)\n'
DOCKER_SYSTEM_DF_EXPECTED_BYTES="10000000000 6000000000"

DOCKER_BUILDX_DU_FIXTURE="$DOCKER_BUILDX_DU_FIXTURE_OK"
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_SYSTEM_DF_FIXTURE_OK"

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
SAFE_RECLAIMABLE_BYTES=0
PURGE_RECLAIMABLE_BYTES=0
DOCKER_INFO_RESULT=0
DOCKER_BUILDX_DU_FIXTURE="$DOCKER_BUILDX_DU_FIXTURE_OK"
MODE="report"
INCLUDE_PURGE=false
DOCKER_UNTIL=""
REPORT_OUTPUT_FILE="$SANDBOX/report-output.log"
: > "$REPORT_OUTPUT_FILE"
for rt in "${RUNTIME_ORDER[@]}"; do
    process_runtime "$rt" >>"$REPORT_OUTPUT_FILE" 2>&1 || true
done
report_output="$(cat "$REPORT_OUTPUT_FILE")"
assert_eq "" "$MUTATE_LOG" "--report performs no mutating calls"
assert_contains "$(all_log)" "npm config get cache" "npm cache location is resolved during report"
assert_contains "$(all_log)" "pip cache dir" "pip cache location is resolved during report"
assert_contains "$report_output" "total (" "size probe runs during report and prints the total figure"
assert_contains "$report_output" "reclaimable via the purge verb" "the purge-tier estimate is printed and labelled with its verb during report"
assert_contains "$report_output" "reclaimable via the safe verb" "the safe-tier estimate is printed and labelled with its verb during report"
assert_not_contains "$report_output" "observed footprint change" "--report never prints a delta line -- there is no action to measure"
assert_contains "$(all_log)" "docker info" "docker preflight runs during report"
assert_contains "$(all_log)" "docker system df" "docker size parse runs during report"

echo "[--report] mutates nothing even with --include-purge set (purge verbs included)"
all_present
reset_logs
FAILED=0
DOCKER_INFO_RESULT=0
DOCKER_BUILDX_DU_FIXTURE="$DOCKER_BUILDX_DU_FIXTURE_OK"
MODE="report"
INCLUDE_PURGE=true
DOCKER_UNTIL=""
for rt in "${RUNTIME_ORDER[@]}"; do
    process_runtime "$rt" >/dev/null 2>&1 || true
done
assert_eq "" "$MUTATE_LOG" "--report performs no mutating calls, including the new uv/npm purge verbs, even with --include-purge"
INCLUDE_PURGE=false

echo "[--yes] safe prunes fire; opt-in purges do not, and are never prompted"
all_present
reset_logs
FAILED=0
DOCKER_INFO_RESULT=0
DOCKER_BUILDX_DU_FIXTURE="$DOCKER_BUILDX_DU_FIXTURE_OK"
MODE="yes"
INCLUDE_PURGE=false
DOCKER_UNTIL=""
for rt in "${RUNTIME_ORDER[@]}"; do
    process_runtime "$rt" >/dev/null 2>&1 || true
done
assert_contains "$MUTATE_LOG" "uv cache prune" "uv is pruned under --yes"
assert_not_contains "$MUTATE_LOG" "uv cache clean" "--yes alone never purges uv (no --include-purge)"
assert_contains "$MUTATE_LOG" "npm cache verify" "npm is pruned under --yes"
assert_not_contains "$MUTATE_LOG" "npm cache clean" "--yes alone never purges npm (no --include-purge)"
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
DOCKER_BUILDX_DU_FIXTURE="$DOCKER_BUILDX_DU_FIXTURE_OK"
MODE="yes"
INCLUDE_PURGE=true
DOCKER_UNTIL=""
for rt in "${RUNTIME_ORDER[@]}"; do
    process_runtime "$rt" >/dev/null 2>&1 || true
done
assert_contains "$MUTATE_LOG" "pip cache purge" "pip is purged under --yes --include-purge"
assert_contains "$MUTATE_LOG" "bun pm cache" "bun is purged under --yes --include-purge"
assert_contains "$MUTATE_LOG" "uv cache clean" "uv is purged under --yes --include-purge"
assert_not_contains "$MUTATE_LOG" "uv cache prune" "uv's purge supersedes its safe verb -- the safe verb never runs too"
assert_contains "$MUTATE_LOG" "npm cache clean" "npm is purged under --yes --include-purge"
assert_not_contains "$MUTATE_LOG" "npm cache verify" "npm's purge supersedes its safe verb -- the safe verb never runs too"

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
INCLUDE_PURGE=false
process_runtime uv >/dev/null 2>&1 || true
assert_contains "$CONFIRM_LOG" "uv" "interactive mode prompts for uv"
assert_eq "" "$MUTATE_LOG" "a declined interactive safe-prune executes nothing"

echo "[interactive] an accepted safe-prune confirm executes"
all_present
reset_logs
FAILED=0
CONFIRM_RESULT=0
MODE="interactive"
INCLUDE_PURGE=false
process_runtime uv >/dev/null 2>&1 || true
assert_contains "$MUTATE_LOG" "uv cache prune" "an accepted interactive confirm prunes uv"

echo "[interactive] uv without --include-purge gets exactly one confirm (the safe one)"
all_present
reset_logs
FAILED=0
CONFIRM_RESULT=0
MODE="interactive"
INCLUDE_PURGE=false
process_runtime uv >/dev/null 2>&1 || true
assert_eq "Prune uv cache?|" "$CONFIRM_LOG" "exactly one confirm fires for uv, and it is the safe prune, not a purge confirm"
assert_not_contains "$CONFIRM_LOG" "Purge uv cache?" "no purge confirm is offered for uv without --include-purge"
assert_not_contains "$MUTATE_LOG" "uv cache clean" "uv is never purged interactively without --include-purge"

echo "[interactive] uv with --include-purge, both confirms accepted: both verbs run, safe first"
all_present
reset_logs
FAILED=0
CONFIRM_RESULT=0
MODE="interactive"
INCLUDE_PURGE=true
process_runtime uv >/dev/null 2>&1 || true
assert_eq "Prune uv cache?|Purge uv cache? (opt-in, destructive)|" "$CONFIRM_LOG" "both the safe and purge confirms are offered, safe first"
assert_eq "uv cache prune|uv cache clean|" "$MUTATE_LOG" "both verbs run in order (safe verb before purge verb) when both interactive confirms are accepted"

echo "[interactive] uv with --include-purge, both confirms declined: nothing runs"
all_present
reset_logs
FAILED=0
CONFIRM_RESULT=1
MODE="interactive"
INCLUDE_PURGE=true
process_runtime uv >/dev/null 2>&1 || true
assert_eq "Prune uv cache?|Purge uv cache? (opt-in, destructive)|" "$CONFIRM_LOG" "both confirms are still offered even though both are declined"
assert_eq "" "$MUTATE_LOG" "declining both interactive confirms executes neither verb"

echo "[interactive] pip without --include-purge is still prompted and still purges when accepted (the asymmetry)"
all_present
reset_logs
FAILED=0
CONFIRM_RESULT=0
MODE="interactive"
INCLUDE_PURGE=false
process_runtime pip >/dev/null 2>&1 || true
assert_contains "$CONFIRM_LOG" "Purge pip cache? (opt-in, destructive)" "pip is prompted interactively even without --include-purge -- it has no safe verb"
assert_contains "$MUTATE_LOG" "pip cache purge" "pip purges on an accepted interactive confirm even without --include-purge"

echo "[docker] the default safe prune is unfiltered -- no --filter argument at all"
all_present
reset_logs
FAILED=0
DOCKER_INFO_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_SYSTEM_DF_FIXTURE_OK"
MODE="yes"
DOCKER_UNTIL=""
process_runtime docker >/dev/null 2>&1 || true
assert_contains "$MUTATE_LOG" "docker builder prune" "the default safe prune still runs docker builder prune"
assert_not_contains "$MUTATE_LOG" "--filter" "the default prune passes no --filter argument at all"
assert_not_contains "$MUTATE_LOG" "until=" "the default prune carries no until= age window"

echo "[docker] --docker-until is honoured by the prune filter"
all_present
reset_logs
FAILED=0
DOCKER_INFO_RESULT=0
DOCKER_BUILDX_DU_FIXTURE="$DOCKER_BUILDX_DU_FIXTURE_OK"
MODE="yes"
DOCKER_UNTIL="24h"
process_runtime docker >/dev/null 2>&1 || true
assert_contains "$MUTATE_LOG" "until=24h" "docker prune filter reflects --docker-until"

DOCKER_UNTIL=""

echo "[docker parse] docker_window_seconds still validates the --docker-until format"
window_seconds="$(docker_window_seconds "168h")"
assert_eq "604800" "$window_seconds" "168h converts to 604800 seconds"
assert_failure "an unrecognised window unit is rejected" docker_window_seconds "168x"

echo "[docker parse] unit normalization: kB/MB/GB/TB and bare bytes"
assert_eq "500" "$(docker_size_to_bytes "500B")" "bare bytes pass through unchanged"
assert_eq "512000" "$(docker_size_to_bytes "512kB")" "kB converts at 1000x (decimal, not 1024)"
assert_eq "2500000" "$(docker_size_to_bytes "2.5MB")" "MB converts and honours a fractional value"
assert_eq "4000000000" "$(docker_size_to_bytes "4GB")" "GB converts at 1000^3"
assert_eq "3000000000000" "$(docker_size_to_bytes "3TB")" "TB converts at 1000^4"

echo "[docker parse] buildx du: trailing labelled lines parse correctly"
pair="$(docker_buildx_du_bytes "$DOCKER_BUILDX_DU_FIXTURE_OK")"
assert_eq "$DOCKER_BUILDX_DU_EXPECTED_BYTES" "$pair" "Total:/Reclaimable: labels parse despite a preceding '*' shared-marker row"

echo "[docker parse] system df: SIZE/RECLAIMABLE parses from the Build Cache row"
pair="$(docker_system_df_bytes "$DOCKER_SYSTEM_DF_FIXTURE_OK")"
assert_eq "$DOCKER_SYSTEM_DF_EXPECTED_BYTES" "$pair" "SIZE/RECLAIMABLE parse correctly from the two-word Build Cache row, percentage stripped"

echo "[docker] rt_docker_size: system df is the primary source and is used when it succeeds"
all_present
reset_logs
FAILED=0
DOCKER_INFO_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_SYSTEM_DF_FIXTURE_OK"
size_out="$(rt_docker_size "")"
assert_eq "$DOCKER_SYSTEM_DF_EXPECTED_BYTES" "$size_out" "rt_docker_size reports the system df pair end to end"
assert_contains "$(all_log)" "docker system df" "system df is the source actually queried when it succeeds"
assert_not_contains "$(all_log)" "docker buildx du" "buildx du is never queried when system df already succeeded"

echo "[docker] rt_docker_size: system df failing falls back to buildx du"
all_present
reset_logs
FAILED=0
DOCKER_INFO_RESULT=0
DOCKER_SYSTEM_DF_RESULT=1
DOCKER_SYSTEM_DF_FIXTURE=""
DOCKER_BUILDX_DU_FIXTURE="$DOCKER_BUILDX_DU_FIXTURE_OK"
size_out="$(rt_docker_size "")"
assert_eq "$DOCKER_BUILDX_DU_EXPECTED_BYTES" "$size_out" "rt_docker_size falls back to buildx du end to end when system df fails"
assert_contains "$(all_log)" "docker system df" "system df is attempted first even though it fails"
assert_contains "$(all_log)" "docker buildx du" "the fallback is reached after system df fails"
DOCKER_SYSTEM_DF_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_SYSTEM_DF_FIXTURE_OK"

echo "[docker parse] both sources fail -> unavailable, action skipped for safety"
all_present
reset_logs
FAILED=0
DOCKER_INFO_RESULT=0
DOCKER_BUILDX_DU_RESULT=1
DOCKER_BUILDX_DU_FIXTURE=""
DOCKER_SYSTEM_DF_FIXTURE=$'Images space usage:\n\nno build-cache row here at all\n'
size_out="$(rt_docker_size "")"
assert_eq "unavailable" "$size_out" "neither source parses, so rt_docker_size reports unavailable rather than a guess"
MODE="yes"
process_runtime docker >/dev/null 2>&1 || true
assert_not_contains "$MUTATE_LOG" "docker builder prune" "an unavailable docker size skips the prune action for safety"
DOCKER_BUILDX_DU_RESULT=0
DOCKER_BUILDX_DU_FIXTURE="$DOCKER_BUILDX_DU_FIXTURE_OK"
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_SYSTEM_DF_FIXTURE_OK"

echo "[contract guard] a malformed (non-pair) probe result is a failure, not a silent 0"
all_present
reset_logs
FAILED=0
TOTAL_BYTES=0
SAFE_RECLAIMABLE_BYTES=0
PURGE_RECLAIMABLE_BYTES=0
ORIGINAL_RT_SIZE_UV="${RT_SIZE[uv]}"
rt_malformed_size_single() { printf '12345\n'; }
RT_SIZE[uv]=rt_malformed_size_single
GUARD_WARN_FILE="$SANDBOX/guard-warnings.log"
: > "$GUARD_WARN_FILE"
process_runtime uv >/dev/null 2>"$GUARD_WARN_FILE" || true
guard_warning="$(cat "$GUARD_WARN_FILE")"
assert_contains "$guard_warning" "WARNING: uv:" "a single-value probe result warns"
assert_eq "1" "$FAILED" "a single-value probe result sets FAILED, the same path a hard probe failure takes"
assert_eq "0" "$PURGE_RECLAIMABLE_BYTES" "a malformed probe never silently contributes to the purge-tier reclaimable total (uv is dual-verb)"
assert_eq "0" "$SAFE_RECLAIMABLE_BYTES" "a malformed probe never silently contributes to the safe-tier reclaimable total"
assert_eq "0" "$TOTAL_BYTES" "a malformed probe never silently contributes to the footprint total"
RT_SIZE[uv]="$ORIGINAL_RT_SIZE_UV"

reset_logs
FAILED=0
TOTAL_BYTES=0
SAFE_RECLAIMABLE_BYTES=0
PURGE_RECLAIMABLE_BYTES=0
rt_malformed_size_junk() { printf 'abc def\n'; }
RT_SIZE[uv]=rt_malformed_size_junk
process_runtime uv >/dev/null 2>&1 || true
assert_eq "1" "$FAILED" "a non-numeric probe pair is also treated as a probe failure"
assert_eq "0" "$PURGE_RECLAIMABLE_BYTES" "non-numeric junk never silently contributes to the purge-tier reclaimable total"
RT_SIZE[uv]="$ORIGINAL_RT_SIZE_UV"

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

echo "[process_runtime] prints both figures; footprint and purge-tier reclaimable totals accumulate independently"
all_present
reset_logs
FAILED=0
TOTAL_BYTES=0
SAFE_RECLAIMABLE_BYTES=0
PURGE_RECLAIMABLE_BYTES=0
MODE="report"
PROCESS_RUNTIME_OUTPUT_FILE="$SANDBOX/process-runtime-output.log"

# A fully-shared cache double: 500 bytes present, 0 reclaimable -- as if
# every byte were hardlinked into something outside the cache dir (e.g. a
# live venv). Proves the footprint total moves without the reclaimable
# total moving. uv is dual-verb, so its reclaimable bytes are a purge-tier
# estimate, never a safe-tier one (decision 4).
rt_size_all_shared() { printf '500 0\n'; }
RT_SIZE["uv"]=rt_size_all_shared

: > "$PROCESS_RUNTIME_OUTPUT_FILE"
process_runtime uv >"$PROCESS_RUNTIME_OUTPUT_FILE" 2>&1 || true
process_runtime_output="$(cat "$PROCESS_RUNTIME_OUTPUT_FILE")"
assert_contains "$process_runtime_output" "500.0B total (500 bytes)" "process_runtime prints the total figure"
assert_contains "$process_runtime_output" "reclaimable via the purge verb (0.0B, 0 bytes)" "process_runtime prints the purge-tier reclaimable figure, labelled with its verb"
assert_eq "500" "$TOTAL_BYTES" "a fully-shared runtime still advances the footprint total"
assert_eq "0" "$PURGE_RECLAIMABLE_BYTES" "a fully-shared runtime does not advance the purge-tier reclaimable total"
assert_eq "0" "$SAFE_RECLAIMABLE_BYTES" "uv's reclaimable bytes never touch the safe-tier total (its safe verb is unpredictable, decision 4)"

RT_SIZE["uv"]=rt_generic_size

echo "[process_runtime] the unavailable path still bypasses both accumulators"
all_present
reset_logs
FAILED=0
TOTAL_BYTES=12345
SAFE_RECLAIMABLE_BYTES=2222
PURGE_RECLAIMABLE_BYTES=6789
MODE="report"
rt_size_unavailable() { printf 'unavailable\n'; }
RT_SIZE["uv"]=rt_size_unavailable
process_runtime uv >/dev/null 2>&1 || true
assert_eq "12345" "$TOTAL_BYTES" "an unavailable size probe leaves the footprint total untouched"
assert_eq "2222" "$SAFE_RECLAIMABLE_BYTES" "an unavailable size probe leaves the safe-tier reclaimable total untouched"
assert_eq "6789" "$PURGE_RECLAIMABLE_BYTES" "an unavailable size probe leaves the purge-tier reclaimable total untouched"
RT_SIZE["uv"]=rt_generic_size
TOTAL_BYTES=0
SAFE_RECLAIMABLE_BYTES=0
PURGE_RECLAIMABLE_BYTES=0

echo "[cargo] report-only, never mutates"
all_present
reset_logs
FAILED=0
MODE="yes"
INCLUDE_PURGE=true
process_runtime cargo >/dev/null 2>&1 || true
assert_eq "" "$MUTATE_LOG" "cargo never has a mutating call, even under --yes --include-purge"
assert_eq "" "${RT_PRUNE[cargo]+set}" "cargo intentionally has no prune-registry entry"

echo "[cargo] reclaimable bytes count toward footprint only, never either reclaimable tier"
all_present
reset_logs
FAILED=0
TOTAL_BYTES=0
SAFE_RECLAIMABLE_BYTES=0
PURGE_RECLAIMABLE_BYTES=0
MODE="report"
rt_size_cargo_fixed() { printf '4000 4000\n'; }
ORIGINAL_RT_SIZE_CARGO="${RT_SIZE[cargo]}"
RT_SIZE[cargo]=rt_size_cargo_fixed
CARGO_OUTPUT_FILE="$SANDBOX/cargo-output.log"
: > "$CARGO_OUTPUT_FILE"
process_runtime cargo >"$CARGO_OUTPUT_FILE" 2>&1 || true
cargo_output="$(cat "$CARGO_OUTPUT_FILE")"
# Regression guard for the exact defect named in the WP-3 brief: measured on
# pre-WP-3 master, a cargo probe of "4000 4000" put 4000 bytes into the
# headline estimate even though cargo has no prune verb in either registry.
assert_eq "4000" "$TOTAL_BYTES" "cargo's bytes still count toward total footprint"
assert_eq "0" "$SAFE_RECLAIMABLE_BYTES" "cargo's bytes never reach the safe-tier reclaimable total (it has no safe verb)"
assert_eq "0" "$PURGE_RECLAIMABLE_BYTES" "cargo's bytes never reach the purge-tier reclaimable total (it has no purge verb)"
assert_not_contains "$cargo_output" "reclaimable via" "cargo prints no per-verb reclaimable line at all -- no verb exists to report one against"
assert_contains "$cargo_output" "no prune verb exists for cargo" "cargo's report-only note explains why it has no reclaimable figure"
RT_SIZE[cargo]="$ORIGINAL_RT_SIZE_CARGO"
TOTAL_BYTES=0

echo "[registry] RT_PRUNE/RT_PURGE membership matches the safe/purge split"
assert_eq "" "${RT_PRUNE[pip]+set}" "pip has no RT_PRUNE entry -- it migrated to RT_PURGE entirely"
assert_eq "" "${RT_PRUNE[bun]+set}" "bun has no RT_PRUNE entry -- it migrated to RT_PURGE entirely"
assert_eq "" "${RT_PURGE[cargo]+set}" "cargo has no RT_PURGE entry (report-only, no verbs at all)"
assert_eq "" "${RT_PURGE[docker]+set}" "docker has no RT_PURGE entry (safe-only, no destructive verb)"
assert_eq "set" "${RT_PRUNE[uv]+set}" "uv keeps its RT_PRUNE (safe) entry"
assert_eq "set" "${RT_PURGE[uv]+set}" "uv also gained an RT_PURGE entry"
assert_eq "set" "${RT_PRUNE[npm]+set}" "npm keeps its RT_PRUNE (safe) entry"
assert_eq "set" "${RT_PURGE[npm]+set}" "npm also gained an RT_PURGE entry"
assert_eq "set" "${RT_PRUNE[docker]+set}" "docker keeps its RT_PRUNE (safe) entry"
assert_eq "set" "${RT_PURGE[pip]+set}" "pip has an RT_PURGE entry (its only verb)"
assert_eq "set" "${RT_PURGE[bun]+set}" "bun has an RT_PURGE entry (its only verb)"

# =========================================================================
# WP-3: the observed footprint delta (plans/cache-prune-reclaim-
# effectiveness.md). Every block below sets its own MODE/INCLUDE_PURGE and
# resets any probe-sequence state explicitly (reset_logs() clears SEQ_FILE,
# DOCKER_SYSTEM_DF_CALL_FILE and DOCKER_SYSTEM_DF_FAIL_AFTER) -- the
# ambient-state hazard both prior WPs in this plan hit.
# =========================================================================

echo "[delta] computed from real before/after probe values against a changing fixture"
all_present
reset_logs
FAILED=0
DELTA_BYTES=0
MODE="yes"
INCLUDE_PURGE=false
queue_probe_sequence "500000 100000" "300000 100000"
RT_SIZE[uv]=rt_size_from_queue
DELTA_OUTPUT_FILE="$SANDBOX/delta-output.log"
: > "$DELTA_OUTPUT_FILE"
process_runtime uv >"$DELTA_OUTPUT_FILE" 2>&1 || true
delta_output="$(cat "$DELTA_OUTPUT_FILE")"
delta_line="$(grep 'observed footprint change' <<< "$delta_output")"
assert_contains "$delta_line" "200000 bytes" "the delta line reports the real before/after difference (500000 - 300000), not a guess"
assert_eq "200000" "$DELTA_BYTES" "the grand-total delta accumulator reflects the real computed value"
RT_SIZE[uv]=rt_generic_size

echo "[delta] edge case 1: an action that frees nothing reports 0B explicitly, never the estimate"
all_present
reset_logs
FAILED=0
DELTA_BYTES=0
MODE="yes"
INCLUDE_PURGE=false
queue_probe_sequence "500000 424242" "500000 424242"
RT_SIZE[uv]=rt_size_from_queue
ZERO_OUTPUT_FILE="$SANDBOX/zero-delta-output.log"
: > "$ZERO_OUTPUT_FILE"
process_runtime uv >"$ZERO_OUTPUT_FILE" 2>&1 || true
zero_output="$(cat "$ZERO_OUTPUT_FILE")"
zero_delta_line="$(grep 'observed footprint change' <<< "$zero_output")"
assert_contains "$zero_delta_line" "0.0B" "an action that frees nothing reports 0B explicitly"
assert_contains "$zero_delta_line" "(0 bytes)" "the zero delta is the literal computed byte count, not omitted"
assert_not_contains "$zero_delta_line" "424242" "the zero delta line never substitutes the (nonzero) reclaimable estimate"
assert_eq "0" "$DELTA_BYTES" "the grand-total delta reflects the real zero, not the estimate"
RT_SIZE[uv]=rt_generic_size

echo "[delta] edge case 5: before-probe unavailable -- no delta at all, action still skipped (unchanged from today)"
all_present
reset_logs
FAILED=0
DELTA_BYTES=0
MODE="yes"
INCLUDE_PURGE=false
queue_probe_sequence "unavailable"
RT_SIZE[uv]=rt_size_from_queue
UNAVAIL_BEFORE_FILE="$SANDBOX/unavail-before-output.log"
: > "$UNAVAIL_BEFORE_FILE"
process_runtime uv >"$UNAVAIL_BEFORE_FILE" 2>&1 || true
unavail_before_output="$(cat "$UNAVAIL_BEFORE_FILE")"
assert_not_contains "$unavail_before_output" "observed footprint change" "an unavailable before-probe never prints a delta line at all -- there is no action to measure"
assert_not_contains "$MUTATE_LOG" "uv cache" "an unavailable before-probe still skips the action for safety"
assert_eq "0" "$DELTA_BYTES" "an unavailable before-probe never contributes to the grand-total delta"
RT_SIZE[uv]=rt_generic_size

echo "[delta] edge case 3: post-action probe failure -- delta unavailable, FAILED not set, excluded from the grand total"
all_present
reset_logs
FAILED=0
DELTA_BYTES=0
MODE="yes"
INCLUDE_PURGE=false
queue_probe_sequence "500000 100000" "unavailable"
RT_SIZE[uv]=rt_size_from_queue
POSTFAIL_FILE="$SANDBOX/post-probe-fail-output.log"
: > "$POSTFAIL_FILE"
process_runtime uv >"$POSTFAIL_FILE" 2>&1 || true
postfail_output="$(cat "$POSTFAIL_FILE")"
postfail_delta_line="$(grep 'observed footprint change' <<< "$postfail_output")"
assert_contains "$postfail_delta_line" "unavailable" "a failed post-action probe reports the delta as unavailable"
assert_contains "$postfail_delta_line" "post-action size probe failed" "the unavailable delta names the post-action probe as the reason"
assert_eq "0" "$FAILED" "a post-action probe failure alone does not set FAILED -- the destructive action itself already succeeded"
assert_eq "0" "$DELTA_BYTES" "a runtime with an unavailable post-action probe is excluded from the grand-total delta"
RT_SIZE[uv]=rt_generic_size

echo "[delta] edge case 4: a failed action with a changed probe still reports the delta, labelled partial, and still fails"
all_present
reset_logs
FAILED=0
DELTA_BYTES=0
MODE="yes"
INCLUDE_PURGE=false
UV_PRUNE_RESULT=1
queue_probe_sequence "1000000 500000" "700000 500000"
RT_SIZE[uv]=rt_size_from_queue
PARTIAL_FILE="$SANDBOX/partial-failed-output.log"
: > "$PARTIAL_FILE"
set +e
process_runtime uv >"$PARTIAL_FILE" 2>&1
partial_status=$?
set -e
partial_output="$(cat "$PARTIAL_FILE")"
partial_delta_line="$(grep 'observed footprint change' <<< "$partial_output")"
assert_contains "$partial_delta_line" "300000 bytes" "a failed action's partial delta is still the real measured difference (1000000 - 700000)"
assert_contains "$partial_delta_line" "partial result" "a failed action's delta is labelled as a partial result"
assert_eq "1" "$FAILED" "a failed verb still sets FAILED, unchanged, even though its delta was measured"
assert_eq "1" "$partial_status" "process_runtime still returns nonzero when the verb it ran failed"
assert_eq "300000" "$DELTA_BYTES" "a partial-but-genuinely-measured delta from a failed action is still summed into the grand total"
RT_SIZE[uv]=rt_generic_size
UV_PRUNE_RESULT=0

echo "[delta] edge case 2: negative delta (cache grew between probes) is reported signed, not clamped, not a failure"
all_present
reset_logs
FAILED=0
DELTA_BYTES=0
MODE="yes"
INCLUDE_PURGE=false
queue_probe_sequence "500000 100000" "700000 100000"
RT_SIZE[uv]=rt_size_from_queue
NEG_FILE="$SANDBOX/negative-delta-output.log"
: > "$NEG_FILE"
process_runtime uv >"$NEG_FILE" 2>&1 || true
neg_output="$(cat "$NEG_FILE")"
neg_delta_line="$(grep 'observed footprint change' <<< "$neg_output")"
assert_contains "$neg_delta_line" "-200000 bytes" "a negative delta is reported signed, as observed, not clamped to zero"
assert_contains "$neg_delta_line" "negative" "a negative delta carries a note that a concurrent write can grow the cache between probes"
assert_eq "0" "$FAILED" "a negative delta is not treated as a failure"
assert_eq "-200000" "$DELTA_BYTES" "the grand-total delta reflects the signed negative value"
RT_SIZE[uv]=rt_generic_size

echo "[delta] docker source-match: before/after from the same source computes a real delta"
all_present
reset_logs
FAILED=0
DELTA_BYTES=0
MODE="yes"
INCLUDE_PURGE=false
DOCKER_INFO_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_SYSTEM_DF_FIXTURE_OK"
DOCKER_SYSTEM_DF_FAIL_AFTER=""
DOCKER_UNTIL=""
SAME_SOURCE_FILE="$SANDBOX/docker-same-source-output.log"
: > "$SAME_SOURCE_FILE"
process_runtime docker >"$SAME_SOURCE_FILE" 2>&1 || true
same_source_output="$(cat "$SAME_SOURCE_FILE")"
same_source_delta_line="$(grep 'observed footprint change' <<< "$same_source_output")"
assert_not_contains "$same_source_delta_line" "unavailable" "docker before/after from the same source (system df both times) computes a real delta, not unavailable"
assert_contains "$same_source_delta_line" "0.0B (0 bytes)" "the fixture is unchanged between the two calls, so the same-source delta is a real, computed zero"

echo "[delta] docker source-match: a source change between probes yields an unavailable delta, never a cross-source number"
all_present
reset_logs
FAILED=0
DELTA_BYTES=0
MODE="yes"
INCLUDE_PURGE=false
DOCKER_INFO_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_SYSTEM_DF_FIXTURE_OK"
DOCKER_BUILDX_DU_FIXTURE="$DOCKER_BUILDX_DU_FIXTURE_OK"
DOCKER_SYSTEM_DF_FAIL_AFTER=1
DOCKER_UNTIL=""
SRC_CHANGE_FILE="$SANDBOX/docker-source-change-output.log"
: > "$SRC_CHANGE_FILE"
process_runtime docker >"$SRC_CHANGE_FILE" 2>&1 || true
src_change_output="$(cat "$SRC_CHANGE_FILE")"
src_change_delta_line="$(grep 'observed footprint change' <<< "$src_change_output")"
assert_contains "$src_change_delta_line" "unavailable" "a docker source change between probes yields an unavailable delta"
assert_contains "$src_change_delta_line" "source changed" "the unavailable delta names the source change as the reason"
assert_contains "$src_change_delta_line" "system-df -> buildx-du" "the delta line names both the before and after sources"
assert_eq "0" "$DELTA_BYTES" "a docker source-change delta is excluded from the grand-total delta, never computed across sources"
DOCKER_SYSTEM_DF_FAIL_AFTER=""

echo "[totals] safe-tier and purge-tier reclaimable accumulate independently and correctly across a full RUNTIME_ORDER pass"
all_present
reset_logs
FAILED=0
TOTAL_BYTES=0
SAFE_RECLAIMABLE_BYTES=0
PURGE_RECLAIMABLE_BYTES=0
MODE="report"
INCLUDE_PURGE=false
DOCKER_INFO_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_SYSTEM_DF_FIXTURE_OK"
DOCKER_SYSTEM_DF_FAIL_AFTER=""
ORIGINAL_RT_SIZE_UV="${RT_SIZE[uv]}"
ORIGINAL_RT_SIZE_NPM="${RT_SIZE[npm]}"
ORIGINAL_RT_SIZE_PIP="${RT_SIZE[pip]}"
ORIGINAL_RT_SIZE_BUN="${RT_SIZE[bun]}"
ORIGINAL_RT_SIZE_CARGO_FOR_TOTALS="${RT_SIZE[cargo]}"
rt_size_totals_uv() { printf '10000 1000\n'; }
rt_size_totals_npm() { printf '20000 2000\n'; }
rt_size_totals_pip() { printf '5000 5000\n'; }
rt_size_totals_bun() { printf '6000 6000\n'; }
rt_size_totals_cargo() { printf '7000 7000\n'; }
RT_SIZE[uv]=rt_size_totals_uv
RT_SIZE[npm]=rt_size_totals_npm
RT_SIZE[pip]=rt_size_totals_pip
RT_SIZE[bun]=rt_size_totals_bun
RT_SIZE[cargo]=rt_size_totals_cargo
for rt in "${RUNTIME_ORDER[@]}"; do
    process_runtime "$rt" >/dev/null 2>&1 || true
done
assert_eq "10000048000" "$TOTAL_BYTES" "footprint total sums every runtime's total, including cargo's and docker's"
assert_eq "6000000000" "$SAFE_RECLAIMABLE_BYTES" "safe-tier total is docker's reclaimable alone"
assert_eq "14000" "$PURGE_RECLAIMABLE_BYTES" "purge-tier total sums uv+npm+pip+bun's reclaimable, excluding cargo (no verb) and docker (safe-only)"
RT_SIZE[uv]="$ORIGINAL_RT_SIZE_UV"
RT_SIZE[npm]="$ORIGINAL_RT_SIZE_NPM"
RT_SIZE[pip]="$ORIGINAL_RT_SIZE_PIP"
RT_SIZE[bun]="$ORIGINAL_RT_SIZE_BUN"
RT_SIZE[cargo]="$ORIGINAL_RT_SIZE_CARGO_FOR_TOTALS"
TOTAL_BYTES=0
SAFE_RECLAIMABLE_BYTES=0
PURGE_RECLAIMABLE_BYTES=0

echo "[delta] dual-verb interactive, both confirms accepted: one delta spans both verbs, not two"
all_present
reset_logs
FAILED=0
DELTA_BYTES=0
CONFIRM_RESULT=0
MODE="interactive"
INCLUDE_PURGE=true
queue_probe_sequence "1000000 500000" "200000 500000"
RT_SIZE[uv]=rt_size_from_queue
DUAL_FILE="$SANDBOX/dual-verb-delta-output.log"
: > "$DUAL_FILE"
process_runtime uv >"$DUAL_FILE" 2>&1 || true
dual_output="$(cat "$DUAL_FILE")"
dual_delta_lines="$(grep -c 'observed footprint change' <<< "$dual_output")"
assert_eq "uv cache prune|uv cache clean|" "$MUTATE_LOG" "both verbs actually ran (safe then purge) ahead of the delta section"
assert_eq "1" "$dual_delta_lines" "exactly one delta line is printed for a dual-verb run, not one per verb"
dual_delta_line="$(grep 'observed footprint change' <<< "$dual_output")"
assert_contains "$dual_delta_line" "800000 bytes" "the single delta reflects the before/after pair spanning both verbs (1000000 - 200000), not an intermediate reading between them"
assert_eq "800000" "$DELTA_BYTES" "the grand total reflects the one spanning delta, not two"
RT_SIZE[uv]=rt_generic_size
CONFIRM_RESULT=1

echo "[partial failure] one failing runtime warns and is skipped; others still run; exit is nonzero"
all_present
reset_logs
FAILED=0
TOTAL_BYTES=0
SAFE_RECLAIMABLE_BYTES=0
PURGE_RECLAIMABLE_BYTES=0
DELTA_BYTES=0
DOCKER_INFO_RESULT=0
DOCKER_BUILDX_DU_FIXTURE="$DOCKER_BUILDX_DU_FIXTURE_OK"
UV_PRUNE_RESULT=1
MODE="yes"
INCLUDE_PURGE=false
DOCKER_UNTIL=""
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
SAFE_RECLAIMABLE_BYTES=0
PURGE_RECLAIMABLE_BYTES=0
DELTA_BYTES=0
UV_PRUNE_RESULT=1
DOCKER_INFO_RESULT=0
DOCKER_BUILDX_DU_FIXTURE="$DOCKER_BUILDX_DU_FIXTURE_OK"
MODE="yes"
INCLUDE_PURGE=false
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

echo "[argument parsing] --docker-until is validated at parse time, in both spellings"
# Regression guard: validation used to happen only as a side effect of the
# docker age-sum size probe. When that probe was replaced (the age-sum has no
# predictive power over real reclaim), an unvalidated window would have flowed
# straight into `docker builder prune --filter`, leaving only the daemon to
# reject it -- and only after every other runtime had already been reported.
for bad_window in "bogus" "99x" "" "168"; do
    set +e
    ( main --docker-until "$bad_window" >/dev/null 2>&1 )
    status=$?
    set -e
    assert_eq "2" "$status" "--docker-until '$bad_window' (space form) exits 2"

    set +e
    ( main "--docker-until=$bad_window" >/dev/null 2>&1 )
    status=$?
    set -e
    assert_eq "2" "$status" "--docker-until=$bad_window (equals form) exits 2"
done

# A rejected window must never reach DOCKER_UNTIL, and must never be the
# value a later prune filter is built from.
DOCKER_UNTIL="168h"
set +e
set_docker_until "bogus" >/dev/null 2>&1
status=$?
set -e
assert_eq "2" "$status" "set_docker_until reports 2 on an invalid window"
assert_eq "168h" "$DOCKER_UNTIL" "a rejected window leaves DOCKER_UNTIL untouched"

set +e
set_docker_until "24h" >/dev/null 2>&1
status=$?
set -e
assert_eq "0" "$status" "set_docker_until accepts a valid window"
assert_eq "24h" "$DOCKER_UNTIL" "an accepted window is assigned"
DOCKER_UNTIL="168h"

echo "[main] full run smoke: --yes produces a per-tier Total section with an observed delta line"
all_present
reset_logs
DOCKER_INFO_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_SYSTEM_DF_FIXTURE_OK"
DOCKER_SYSTEM_DF_FAIL_AFTER=""
MAIN_YES_FILE="$SANDBOX/main-yes-output.log"
: > "$MAIN_YES_FILE"
( main --yes >"$MAIN_YES_FILE" 2>&1 ) || true
main_yes_output="$(cat "$MAIN_YES_FILE")"
assert_contains "$main_yes_output" "Total cache footprint seen:" "the --yes Total section prints the footprint total"
assert_contains "$main_yes_output" "Estimated safe-tier reclaimable" "the --yes Total section prints the safe-tier estimate, labelled"
assert_contains "$main_yes_output" "Estimated purge-tier reclaimable" "the --yes Total section prints the purge-tier estimate, labelled"
assert_contains "$main_yes_output" "Observed footprint change" "the --yes Total section prints the observed delta line, since an action ran"

echo "[main] full run smoke: --report produces a per-tier Total section with no delta line"
all_present
reset_logs
DOCKER_INFO_RESULT=0
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_SYSTEM_DF_FIXTURE_OK"
DOCKER_SYSTEM_DF_FAIL_AFTER=""
MAIN_REPORT_FILE="$SANDBOX/main-report-output.log"
: > "$MAIN_REPORT_FILE"
( main --report >"$MAIN_REPORT_FILE" 2>&1 ) || true
main_report_output="$(cat "$MAIN_REPORT_FILE")"
assert_contains "$main_report_output" "Total cache footprint seen:" "the --report Total section prints the footprint total"
assert_contains "$main_report_output" "Estimated safe-tier reclaimable" "the --report Total section prints the safe-tier estimate, labelled"
assert_contains "$main_report_output" "Estimated purge-tier reclaimable" "the --report Total section prints the purge-tier estimate, labelled"
assert_not_contains "$main_report_output" "Observed footprint change" "the --report Total section prints no delta line at all -- there was no action"
assert_eq "" "$MUTATE_LOG" "a full --report run via main() still performs no mutating calls"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
