# shellcheck shell=bash
#
# Measurement suite: the probe-record transport, the one delta
# comparison helper, the reporting/accumulator behaviour built on them,
# and the F9 regression that pins provenance to the record.
#
# Sourced by ../cache-prune.sh, the canonical test entry point, which owns
# the harness (ok/bad/assert_*), the fixture sandbox and the command
# doubles every assertion here relies on. Not runnable on its own.
# shellcheck disable=SC1091,SC2317,SC2034

echo "[probe record] the transport carries provenance or is not a record"
assert_eq "available 1000 900 system-df" "$(probe_available 1000 900 system-df)" \
    "probe_available emits <status> <total> <reclaimable> <source> in that fixed order"
assert_eq "unavailable 0 0 -" "$(probe_unavailable)" \
    "probe_unavailable emits the canonical unavailable record"
# Fail-closed: this is the F9 defect expressed at the constructor. A probe
# that cannot name its source must not be able to produce an available
# record at all, because an available record is the only thing a delta can
# be computed from.
assert_eq "unavailable 0 0 -" "$(probe_available 1000 900 "")" \
    "an empty source identity yields an unavailable record, never an anonymous available one"
assert_eq "unavailable 0 0 -" "$(probe_available 1000 900 "two words")" \
    "a source identity containing whitespace is rejected the same way -- the record is one line, four fields"

echo "[probe record] validation rejects every non-record, including the retired bare pair"
assert_success "an available record validates" probe_is_valid "available 1000 900 system-df"
assert_success "the unavailable record validates" probe_is_valid "unavailable 0 0 -"
assert_failure "the retired bare <total> <reclaimable> pair is not a record" probe_is_valid "1000 900"
assert_failure "a bare 'unavailable' word is not a record" probe_is_valid "unavailable"
assert_failure "an available record missing its source is not a record" probe_is_valid "available 1000 900"
assert_failure "an empty probe result is not a record" probe_is_valid ""
assert_failure "a non-numeric byte field is not a record" probe_is_valid "available abc def census"
assert_success "probe_is_available accepts an available record" probe_is_available "available 1 2 census"
assert_failure "probe_is_available rejects an unavailable record" probe_is_available "unavailable 0 0 -"
assert_failure "probe_is_available rejects junk" probe_is_available "garbage"

echo "[probe_compare] one helper owns eligibility and signed subtraction"
assert_eq "available 200000" \
    "$(probe_compare uv "available 500000 100000 census" "available 300000 100000 census")" \
    "two available records from the same source subtract to a signed delta"
assert_eq "available 0" \
    "$(probe_compare uv "available 500000 1 census" "available 500000 1 census")" \
    "an unchanged cache compares to an explicit zero, not to nothing"
assert_eq "available -200000" \
    "$(probe_compare uv "available 500000 1 census" "available 700000 1 census")" \
    "a cache that grew compares to a negative delta, reported as observed"
assert_eq "unavailable docker size source changed between probes: system-df -> buildx-du" \
    "$(probe_compare docker "available 1000 900 system-df" "available 400 300 buildx-du")" \
    "a changed source is ineligible, and the reason names both sources"
assert_eq "unavailable npm size source changed between probes: census -> other" \
    "$(probe_compare npm "available 1000 900 census" "available 400 300 other")" \
    "the source-match rule is not docker-specific -- it holds for every runtime"
assert_eq "unavailable the post-action size probe failed" \
    "$(probe_compare uv "available 1000 900 census" "unavailable 0 0 -")" \
    "an unavailable after-record is ineligible"
assert_eq "unavailable the post-action size probe failed" \
    "$(probe_compare uv "available 1000 900 census" "")" \
    "a missing after-record is ineligible"
assert_eq "unavailable the post-action size probe failed" \
    "$(probe_compare uv "available 1000 900 census" "400 300")" \
    "a malformed after-record (a bare pair) is ineligible -- never subtracted as if it were a record"
assert_eq "unavailable the pre-action size probe failed" \
    "$(probe_compare uv "unavailable 0 0 -" "available 400 300 census")" \
    "an unavailable before-record is ineligible"
assert_success "probe_compare always exits 0 -- 'not comparable' is an answer, not an error" \
    probe_compare uv "unavailable 0 0 -" "garbage"

echo "[F9 regression] a docker source change with no scratch file still yields an unavailable delta"
# The defect this whole package exists for (F9,
# reviews/2026-09-07-tn-code-review.md). The before probe measured via
# system df, the after probe via buildx du, and the scratch file the old
# implementation smuggled that provenance through could not be created:
# both labels read back empty, the "did the source change?" guard compared
# "" with "" and passed, and 1000 - 400 was reported as a 600-byte
# measurement with exit 0. Measured on the pre-refactor code, verbatim:
#   docker: observed footprint change: 600.0B (600 bytes)
# Hermetic throughout: the probe values are injected, the action is a mock,
# and any call to a real docker binary is itself a failure below.
all_present
reset_logs
FAILED=0
DELTA_BYTES=0
TOTAL_BYTES=0
SAFE_RECLAIMABLE_BYTES=0
MODE="yes"
INCLUDE_PURGE=false
DOCKER_UNTIL=""

F9_DOCKER_CALL_FILE="$SANDBOX/f9-docker-calls.log"
: > "$F9_DOCKER_CALL_FILE"
F9_ORIGINAL_DOCKER="$(declare -f docker)"
# File-backed, like ALL_LOG_FILE: a size probe runs inside the subshell a
# command substitution forks, so a violation recorded in a plain variable
# there would not survive to be asserted on.
docker() { printf 'docker %s\n' "$*" >> "$F9_DOCKER_CALL_FILE"; return 99; }
rt_docker_detect() { return 0; }
# mktemp must be irrelevant on this path now. Shadowed to fail so that
# reintroducing any scratch-file side channel reproduces the exact
# production condition that made F9 report a number.
mktemp() { return 1; }

F9_ORIGINAL_RT_SIZE_DOCKER="${RT_SIZE[docker]}"
F9_ORIGINAL_RT_PRUNE_DOCKER="${RT_PRUNE[docker]}"
queue_probe_sequence "available 1000 900 system-df" "available 400 300 buildx-du"
RT_SIZE[docker]=rt_size_from_queue
rt_docker_prune_mock() { MUTATE_LOG+="MOCK docker builder prune|"; return 0; }
RT_PRUNE[docker]=rt_docker_prune_mock

F9_FILE="$SANDBOX/f9-output.log"
: > "$F9_FILE"
set +e
process_runtime docker >"$F9_FILE" 2>&1
f9_status=$?
set -e
unset -f mktemp
eval "$F9_ORIGINAL_DOCKER"
RT_SIZE[docker]="$F9_ORIGINAL_RT_SIZE_DOCKER"
RT_PRUNE[docker]="$F9_ORIGINAL_RT_PRUNE_DOCKER"

f9_output="$(cat "$F9_FILE")"
f9_delta_line="$(grep 'observed footprint change' <<< "$f9_output")"
assert_contains "$MUTATE_LOG" "MOCK docker builder prune" "the mocked action did run, so there really was something to measure around"
assert_contains "$f9_delta_line" "unavailable" "a cross-source pair reports the delta as unavailable even when no scratch file can be created"
assert_contains "$f9_delta_line" "docker size source changed between probes: system-df -> buildx-du" "the unavailable delta still names both sources -- provenance travels in the record, not in a file that can fail to exist"
assert_not_contains "$f9_delta_line" "600" "the cross-source subtraction 1000 - 400 is never reported as a measurement"
assert_eq "0" "$DELTA_BYTES" "an ineligible pair contributes exactly nothing to the grand-total delta"
assert_eq "0" "$FAILED" "an unmeasurable delta is not a failure -- the action itself succeeded"
assert_eq "0" "$f9_status" "process_runtime's exit status is unchanged from the success path"
assert_eq "" "$(cat "$F9_DOCKER_CALL_FILE")" "no docker command was invoked anywhere in this test"

echo "[contract guard] a malformed (non-pair) probe result is a failure, not a silent 0"
all_present
reset_logs
MODE="yes"
INCLUDE_PURGE=false
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
assert_contains "$guard_warning" "WARNING: uv:" "a single-value probe result (the retired bare-pair transport) warns"
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
rt_size_all_shared() { printf 'available 500 0 census\n'; }
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
rt_size_unavailable() { probe_unavailable; }
RT_SIZE["uv"]=rt_size_unavailable
process_runtime uv >/dev/null 2>&1 || true
assert_eq "12345" "$TOTAL_BYTES" "an unavailable size probe leaves the footprint total untouched"
assert_eq "2222" "$SAFE_RECLAIMABLE_BYTES" "an unavailable size probe leaves the safe-tier reclaimable total untouched"
assert_eq "6789" "$PURGE_RECLAIMABLE_BYTES" "an unavailable size probe leaves the purge-tier reclaimable total untouched"
RT_SIZE["uv"]=rt_generic_size
TOTAL_BYTES=0
SAFE_RECLAIMABLE_BYTES=0
PURGE_RECLAIMABLE_BYTES=0


echo "[cargo] reclaimable bytes count toward footprint only, never either reclaimable tier"
all_present
reset_logs
FAILED=0
TOTAL_BYTES=0
SAFE_RECLAIMABLE_BYTES=0
PURGE_RECLAIMABLE_BYTES=0
MODE="report"
rt_size_cargo_fixed() { printf 'available 4000 4000 census\n'; }
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


echo "[delta] computed from real before/after probe values against a changing fixture"
all_present
reset_logs
FAILED=0
DELTA_BYTES=0
MODE="yes"
INCLUDE_PURGE=false
queue_probe_sequence "available 500000 100000 census" "available 300000 100000 census"
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
queue_probe_sequence "available 500000 424242 census" "available 500000 424242 census"
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
queue_probe_sequence "unavailable 0 0 -"
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
queue_probe_sequence "available 500000 100000 census" "unavailable 0 0 -"
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
queue_probe_sequence "available 1000000 500000 census" "available 700000 500000 census"
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
queue_probe_sequence "available 500000 100000 census" "available 700000 100000 census"
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
rt_size_totals_uv() { printf 'available 10000 1000 census\n'; }
rt_size_totals_npm() { printf 'available 20000 2000 census\n'; }
rt_size_totals_pip() { printf 'available 5000 5000 census\n'; }
rt_size_totals_bun() { printf 'available 6000 6000 census\n'; }
rt_size_totals_cargo() { printf 'available 7000 7000 census\n'; }
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
queue_probe_sequence "available 1000000 500000 census" "available 200000 500000 census"
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
