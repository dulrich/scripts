# shellcheck shell=bash
#
# Adapter suite: detection, cache-location resolution, the directory
# census and docker's two size sources -- everything in
# ../../cache-prune/adapters.sh.
#
# Sourced by ../cache-prune.sh, the canonical test entry point, which owns
# the harness (ok/bad/assert_*), the fixture sandbox and the command
# doubles every assertion here relies on. Not runnable on its own.
# shellcheck disable=SC1091,SC2317,SC2034

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
assert_eq "$DOCKER_SYSTEM_DF_EXPECTED_RECORD" "$size_out" "rt_docker_size reports the system df pair end to end, with system-df named as its source"
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
assert_eq "$DOCKER_BUILDX_DU_EXPECTED_RECORD" "$size_out" "rt_docker_size falls back to buildx du end to end when system df fails, and names buildx-du as its source"
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
assert_eq "unavailable 0 0 -" "$size_out" "neither source parses, so rt_docker_size reports unavailable rather than a guess"
MODE="yes"
process_runtime docker >/dev/null 2>&1 || true
assert_not_contains "$MUTATE_LOG" "docker builder prune" "an unavailable docker size skips the prune action for safety"
DOCKER_BUILDX_DU_RESULT=0
DOCKER_BUILDX_DU_FIXTURE="$DOCKER_BUILDX_DU_FIXTURE_OK"
DOCKER_SYSTEM_DF_FIXTURE="$DOCKER_SYSTEM_DF_FIXTURE_OK"


echo "[rt_generic_size] inode-complete link census"
# A real fixture tree under the sandbox (itself `mktemp -d`), with actual
# `ln` hardlinks -- trap-cleaned by the sandbox's own EXIT trap. Byte counts
# are synthetic and small (no real machine cache sizes), chosen distinct
# enough to catch a total/reclaimable mixup.

CENSUS_PLAIN="$SANDBOX/census-plain"
mkdir -p "$CENSUS_PLAIN"
head -c 111 /dev/zero > "$CENSUS_PLAIN/plain.bin"
assert_eq "111 111" "$(dir_census_bytes "$CENSUS_PLAIN")" \
    "a plain unlinked file counts toward both total and reclaimable"

CENSUS_SHARED="$SANDBOX/census-shared"
mkdir -p "$CENSUS_SHARED"
head -c 222 /dev/zero > "$CENSUS_SHARED/a.bin"
ln "$CENSUS_SHARED/a.bin" "$CENSUS_SHARED/b.bin"
assert_eq "222 222" "$(dir_census_bytes "$CENSUS_SHARED")" \
    "a file hardlinked twice inside the tree counts once toward total and is fully reclaimable"

CENSUS_EXTERNAL="$SANDBOX/census-external"
CENSUS_EXTERNAL_OUTSIDE="$SANDBOX/census-external-outside"
mkdir -p "$CENSUS_EXTERNAL" "$CENSUS_EXTERNAL_OUTSIDE"
head -c 333 /dev/zero > "$CENSUS_EXTERNAL/inside.bin"
ln "$CENSUS_EXTERNAL/inside.bin" "$CENSUS_EXTERNAL_OUTSIDE/outside.bin"
assert_eq "333 0" "$(dir_census_bytes "$CENSUS_EXTERNAL")" \
    "a file with an additional link outside the tree counts toward total but contributes zero to reclaimable"

CENSUS_EMPTY="$SANDBOX/census-empty"
mkdir -p "$CENSUS_EMPTY"
assert_eq "0 0" "$(dir_census_bytes "$CENSUS_EMPTY")" "an empty directory returns 0 0"
assert_eq "0 0" "$(dir_census_bytes "$SANDBOX/census-does-not-exist")" "a nonexistent path returns 0 0"

echo "[rt_generic_size] the census reaches the registry as a probe record, source and all"
assert_eq "available 111 111 census" "$(rt_generic_size "$CENSUS_PLAIN")" \
    "the directory adapter wraps the census pair in a record naming census as its source"
assert_eq "available 333 0 census" "$(rt_generic_size "$CENSUS_EXTERNAL")" \
    "the record keeps total and reclaimable distinct and in the documented field order"
assert_eq "available 0 0 census" "$(rt_generic_size "$SANDBOX/census-does-not-exist")" \
    "a nonexistent cache directory is an available zero measurement, not an unavailable one"
assert_success "every directory-backed runtime therefore measures with one comparable source" \
    probe_is_available "$(rt_generic_size "$CENSUS_EMPTY")"
