# shellcheck shell=bash
#
# CLI suite: the command-line surface ../../cache-prune.sh keeps for
# itself -- the root refusal, argument parsing and full main() runs.
#
# Sourced by ../cache-prune.sh, the canonical test entry point, which owns
# the harness (ok/bad/assert_*), the fixture sandbox and the command
# doubles every assertion here relies on. Not runnable on its own.
# shellcheck disable=SC1091,SC2317,SC2034

echo "[require_not_root] root refusal"
assert_failure "root EUID is refused" require_not_root 0
assert_success "non-root EUID is accepted" require_not_root 1000


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
