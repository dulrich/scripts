# shellcheck shell=bash
#
# Action suite: mode matrix, verb election, prompt order and the verbs
# themselves -- everything in ../../cache-prune/actions.sh.
#
# Sourced by ../cache-prune.sh, the canonical test entry point, which owns
# the harness (ok/bad/assert_*), the fixture sandbox and the command
# doubles every assertion here relies on. Not runnable on its own.
# shellcheck disable=SC1091,SC2317,SC2034

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


echo "[cargo] purge-only: registry/src children, filesystem-backed (sandboxed CARGO_HOME)"
cargo_fixture() {
    rm -rf "$CARGO_HOME"
    mkdir -p "$CARGO_HOME/registry/src/idx-1/foo-1.0/src" "$CARGO_HOME/registry/src/idx-1/bar-2.0" \
        "$CARGO_HOME/registry/cache/idx-1" "$CARGO_HOME/registry/index/idx-1"
    printf 'fn main() {}\n' > "$CARGO_HOME/registry/src/idx-1/foo-1.0/src/lib.rs"
    printf 'bar\n' > "$CARGO_HOME/registry/src/idx-1/bar-2.0/lib.rs"
    printf 'crate' > "$CARGO_HOME/registry/cache/idx-1/foo-1.0.crate"
    printf 'idx' > "$CARGO_HOME/registry/index/idx-1/cfg"
}
cargo_run() {
    all_present
    reset_logs
    FAILED=0
    MODE="yes"
    INCLUDE_PURGE="$1"
    CARGO_STATUS=0
    process_runtime cargo >/dev/null 2>"$SANDBOX/cargo-warn.log" || CARGO_STATUS=$?
    cargo_warn="$(cat "$SANDBOX/cargo-warn.log")"
}
assert_eq "set" "${RT_PURGE[cargo]+set}" "cargo has an RT_PURGE entry"
assert_eq "optin" "${RT_CLASS[cargo]}" "cargo is a purge-only opt-in runtime"
assert_eq "" "${RT_PRUNE[cargo]+set}" "cargo intentionally has no prune-registry entry"

cargo_fixture
cargo_run false
assert_success "--yes alone leaves registry/src untouched" test -f "$CARGO_HOME/registry/src/idx-1/foo-1.0/src/lib.rs"
assert_eq "" "$MUTATE_LOG" "cargo makes no command-double mutating call"

cargo_fixture
cargo_run true
assert_eq "00" "$CARGO_STATUS$FAILED" "--yes --include-purge purge of cargo succeeds"
assert_eq "" "$(ls -A "$CARGO_HOME/registry/src")" "purge empties registry/src children"
assert_success "registry/src itself is kept" test -d "$CARGO_HOME/registry/src"
assert_success "registry/cache contents survive" test -f "$CARGO_HOME/registry/cache/idx-1/foo-1.0.crate"
assert_success "registry/index contents survive" test -f "$CARGO_HOME/registry/index/idx-1/cfg"
assert_success "lock files absent beforehand are created, never removed" \
    test -e "$CARGO_HOME/.package-cache" -a -e "$CARGO_HOME/.package-cache-mutate"

for held in .package-cache .package-cache-mutate; do
    cargo_fixture
    : > "$CARGO_HOME/$held"
    rm -f "$SANDBOX/cargo-ready"
    ( exec 9<>"$CARGO_HOME/$held"; flock -n 9 && : > "$SANDBOX/cargo-ready"; exec sleep 30 ) &
    holder=$!
    for _ in $(seq 1 100); do [[ -e "$SANDBOX/cargo-ready" ]] && break; sleep 0.05; done
    cargo_run true
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    assert_success "held $held skips: nothing deleted" test -f "$CARGO_HOME/registry/src/idx-1/foo-1.0/src/lib.rs"
    assert_contains "$cargo_warn" "cargo: skipped $CARGO_HOME/registry/src (guard: a cargo package-cache lock is held)" "held $held warns"
    assert_eq "00" "$CARGO_STATUS$FAILED" "held $held leaves exit status and FAILED unchanged"
done

cargo_fixture
rm -rf "$CARGO_HOME/registry/src"
mkdir -p "$SANDBOX/cargo-elsewhere/keep"
printf 'x' > "$SANDBOX/cargo-elsewhere/keep/file"
ln -s "$SANDBOX/cargo-elsewhere" "$CARGO_HOME/registry/src"
cargo_run true
assert_success "symlinked registry/src: the target contents survive" test -f "$SANDBOX/cargo-elsewhere/keep/file"
assert_contains "$cargo_warn" "(guard: symlinked or escapes CARGO_HOME)" "symlinked registry/src warns"
assert_eq "00" "$CARGO_STATUS$FAILED" "a symlink skip leaves exit status and FAILED unchanged"
rm -rf "$SANDBOX/cargo-elsewhere" "$CARGO_HOME"
mkdir -p "$CARGO_DIR"


echo "[registry] RT_PRUNE/RT_PURGE membership matches the safe/purge split"
assert_eq "" "${RT_PRUNE[pip]+set}" "pip has no RT_PRUNE entry -- it migrated to RT_PURGE entirely"
assert_eq "" "${RT_PRUNE[bun]+set}" "bun has no RT_PRUNE entry -- it migrated to RT_PURGE entirely"
assert_eq "set" "${RT_PURGE[cargo]+set}" "cargo has an RT_PURGE entry (purge-only, registry/src)"
assert_eq "" "${RT_PURGE[docker]+set}" "docker has no RT_PURGE entry (safe-only, no destructive verb)"
assert_eq "set" "${RT_PRUNE[uv]+set}" "uv keeps its RT_PRUNE (safe) entry"
assert_eq "set" "${RT_PURGE[uv]+set}" "uv also gained an RT_PURGE entry"
assert_eq "set" "${RT_PRUNE[npm]+set}" "npm keeps its RT_PRUNE (safe) entry"
assert_eq "set" "${RT_PURGE[npm]+set}" "npm also gained an RT_PURGE entry"
assert_eq "set" "${RT_PRUNE[docker]+set}" "docker keeps its RT_PRUNE (safe) entry"
assert_eq "set" "${RT_PURGE[pip]+set}" "pip has an RT_PURGE entry (its only verb)"
assert_eq "set" "${RT_PURGE[bun]+set}" "bun has an RT_PURGE entry (its only verb)"

# =========================================================================
# The observed footprint delta (from the cache-prune
# reclaim-effectiveness work). Every block below sets its own MODE/INCLUDE_PURGE and
# resets any probe-sequence state explicitly (reset_logs() clears SEQ_FILE,
# DOCKER_SYSTEM_DF_CALL_FILE and DOCKER_SYSTEM_DF_FAIL_AFTER) -- the
# ambient-state hazard both prior WPs in this plan hit.
# =========================================================================


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

# tier_elected: the one election helper. Each cell prints E (elected) or -
# plus every prompt shown, across report / yes / yes+purge / interactive /
# interactive+purge, with every confirm answered yes.
tier_matrix() {
    (
        exec 3>&1
        confirm() { printf '?' >&3; return 0; }
        local m p
        for m in report:false yes:false yes:true interactive:false interactive:true; do
            MODE="${m%%:*}" INCLUDE_PURGE="${m#*:}"
            if tier_elected "$1" prompt "${2:-}" >/dev/null; then p=E; else p=-; fi
            printf '%s ' "$p"
        done
    )
}
echo "[tier_elected] safe / purge / interactive-only / per-item"
assert_eq "- E E ?E ?E " "$(tier_matrix safe)" "safe: --yes always, interactive confirms"
assert_eq "- - E - ?E " "$(tier_matrix purge)" "purge: --yes needs --include-purge, interactive confirms only with it"
assert_eq "- - - ?E ?E " "$(tier_matrix optin "interactive only")" "interactive-only: never under --yes, interactive confirms"
assert_eq "- - - - ?E " "$(tier_matrix item)" "per-item: never under --yes, interactive confirms only with --include-purge"
