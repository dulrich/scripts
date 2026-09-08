#!/usr/bin/env bash
# Hermetic regression tests for ../cache-prune.sh -- the canonical entry
# point. This file owns the harness, the fixture sandbox and the command
# doubles; the assertions themselves live in focused suites under
# cache-prune/, sourced at the bottom in the order the implementation
# modules layer (adapters -> measurement -> actions -> cli). Sourced, not
# executed: every suite shares this file's doubles, PASS/FAIL counters and
# sandbox, and the single "N passed, M failed" summary below stays the one
# result line.
#
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

# queue_probe_sequence: load one probe record per probe call, in call order
# -- "<status> <total> <reclaimable> <source>", the transport documented in
# ../cache-prune/measurement.sh. Pair with
# `RT_SIZE[<name>]=rt_size_from_queue`. Queueing a source identity here is
# what lets a test drive a before/after pair whose provenance differs
# without going near a real docker daemon.
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
DOCKER_BUILDX_DU_EXPECTED_RECORD="available 10000000000 4000000000 buildx-du"

# Synthetic fallback `docker system df` (plain, non -v) fixture: "Build
# Cache" is a two-word label, exercising the $3..$6 field-offset trap, and
# every RECLAIMABLE cell (including Build Cache's own) carries a trailing
# "(NN%)" to exercise the defensive percentage strip.
DOCKER_SYSTEM_DF_FIXTURE_OK=$'TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE\nImages          12        4         3.2GB     1.1GB (34%)\nContainers      5         2         50MB      10MB (20%)\nLocal Volumes   8         3         500MB     50MB (10%)\nBuild Cache     42        0         10GB      6GB (60%)\n'
DOCKER_SYSTEM_DF_EXPECTED_BYTES="10000000000 6000000000"
DOCKER_SYSTEM_DF_EXPECTED_RECORD="available 10000000000 6000000000 system-df"

DOCKER_BUILDX_DU_FIXTURE="$DOCKER_BUILDX_DU_FIXTURE_OK"
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_SYSTEM_DF_FIXTURE_OK"

# --- suites --------------------------------------------------------------
#
# Sourced (not run as subprocesses) so they share the harness, the doubles
# and the sandbox above. Each suite mirrors one implementation module; cli
# covers the command-line surface ../cache-prune.sh keeps for itself.

# shellcheck source=util/tests/cache-prune/adapters.sh
source "$HERE/cache-prune/adapters.sh"
# shellcheck source=util/tests/cache-prune/measurement.sh
source "$HERE/cache-prune/measurement.sh"
# shellcheck source=util/tests/cache-prune/actions.sh
source "$HERE/cache-prune/actions.sh"
# shellcheck source=util/tests/cache-prune/cli.sh
source "$HERE/cache-prune/cli.sh"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
