# shellcheck shell=bash
#
# Codex suite: the `codex` runtime -- leaked Codex marketplace staging copies
# (../../cache-prune/adapters.sh probes, ../../cache-prune/actions.sh purge).
#
# Sourced by ../cache-prune.sh, which owns the harness, sandbox and doubles.
# Every fixture lives under the sandbox: CACHE_PRUNE_CODEX_HOME_ROOT is
# re-pointed at a synthetic home root here, never the real $HOME.
# shellcheck disable=SC1091,SC2317,SC2034

CODEX_ROOT="$SANDBOX/codex-root"
CODEX_STG="$CODEX_ROOT/.codex-alpha/.tmp/marketplaces/.staging"
CODEX_OLD="$CODEX_STG/marketplace-upgrade-old1"
CODEX_YOUNG="$CODEX_STG/marketplace-upgrade-young1"
CODEX_BACKUP="$CODEX_STG/marketplace-backup-keep"
CODEX_LINK="$CODEX_STG/marketplace-upgrade-link"
CODEX_LINK_TARGET="$CODEX_STG/link-target"
# A home whose .staging is a symlink to elsewhere (symlinked ancestor).
CODEX_ELSEWHERE="$SANDBOX/codex-elsewhere"
CODEX_ANC_OLD="$CODEX_ELSEWHERE/marketplace-upgrade-anc"

codex_old_dir() {
    mkdir -p "$1"
    head -c 4096 /dev/zero > "$1/payload.bin"
    touch -d '2 days ago' "$1"
}

codex_build_fixture() {
    rm -rf "$CODEX_ROOT" "$CODEX_ELSEWHERE"
    mkdir -p "$CODEX_STG" "$CODEX_ROOT/.codex-empty/.tmp/marketplaces/.staging" \
        "$CODEX_ROOT/.codex-bare" "$CODEX_ROOT/.codex-anc/.tmp/marketplaces"
    codex_old_dir "$CODEX_OLD"
    mkdir -p "$CODEX_YOUNG"
    head -c 2048 /dev/zero > "$CODEX_YOUNG/payload.bin"
    codex_old_dir "$CODEX_BACKUP"
    codex_old_dir "$CODEX_LINK_TARGET"
    ln -s "$CODEX_LINK_TARGET" "$CODEX_LINK"
    touch -h -d '2 days ago' "$CODEX_LINK"
    codex_old_dir "$CODEX_ANC_OLD"
    ln -s "$CODEX_ELSEWHERE" "$CODEX_ROOT/.codex-anc/.tmp/marketplaces/.staging"
}

codex_run() {
    local mode="$1" include="$2" out="$3"
    all_present
    FAILED=0
    MODE="$mode"
    INCLUDE_PURGE="$include"
    process_runtime codex >"$out" 2>&1 || true
    MODE="report"
    INCLUDE_PURGE=false
}

CODEX_OUT="$SANDBOX/codex-out.log"


echo "[codex detect] absent .staging is not detected; empty .staging probes 0/0"
reset_logs
CACHE_PRUNE_CODEX_HOME_ROOT="$SANDBOX/codex-only-bare"
mkdir -p "$CACHE_PRUNE_CODEX_HOME_ROOT/.codex"
assert_failure "a Codex home without .staging is not detected" rt_codex_detect
assert_eq "unavailable 0 0 -" "$(rt_codex_size "")" "no .staging probes unavailable"
mkdir -p "$CACHE_PRUNE_CODEX_HOME_ROOT/.codex/.tmp/marketplaces/.staging"
assert_success "an empty .staging is detected" rt_codex_detect
assert_eq "available 0 0 codex" "$(rt_codex_size "")" "an empty .staging probes available 0 total 0 reclaimable"


echo "[codex size] old vs young: all entries count to total, only old ones reclaim"
codex_build_fixture
CACHE_PRUNE_CODEX_HOME_ROOT="$CODEX_ROOT"
codex_expect_old=$(repo_du_sum "$CODEX_OLD")
codex_expect_total=$(repo_du_sum "$CODEX_OLD" "$CODEX_YOUNG" "$CODEX_LINK" "$CODEX_ANC_OLD")
assert_eq "available $codex_expect_total $codex_expect_old codex" "$(rt_codex_size "")" \
    "total covers every marketplace-upgrade-* entry; reclaimable only entries over 24h with no symlink in their path"
codex_detail="$(rt_codex_detail)"
assert_contains "$codex_detail" "codex .codex-alpha staging: 3 entries" "detail prints a per-profile entry count"
assert_contains "$codex_detail" "2 not reclaimable (under 24h old or a symlink)" "detail counts the too-young (and symlinked) entries"


echo "[codex --report] sizes only, deletes nothing"
reset_logs
codex_run report false "$CODEX_OUT"
assert_contains "$(cat "$CODEX_OUT")" "==== codex ====" "codex reports its own section"
assert_success "--report leaves the old entry in place" test -d "$CODEX_OLD"


echo "[codex --yes] bare --yes never purges codex"
reset_logs
codex_run yes false "$CODEX_OUT"
assert_success "bare --yes leaves the old entry in place" test -d "$CODEX_OLD"


echo "[codex interactive] the one confirm gates the purge"
reset_logs
CONFIRM_RESULT=1
codex_run interactive false "$CODEX_OUT"
assert_contains "$CONFIRM_LOG" "Purge codex cache?" "interactive mode offers one codex purge confirm"
assert_success "a declined confirm deletes nothing" test -d "$CODEX_OLD"
reset_logs
CONFIRM_RESULT=0
codex_run interactive false "$CODEX_OUT"
assert_failure "an accepted confirm deletes the old entry" test -e "$CODEX_OLD"
assert_success "an accepted confirm keeps the young entry" test -d "$CODEX_YOUNG"


echo "[codex --yes --include-purge] removes only old marketplace-upgrade-* entries, under the guards"
codex_build_fixture
reset_logs
codex_run yes true "$CODEX_OUT"
codex_purge_output="$(cat "$CODEX_OUT")"
assert_failure "the old entry is removed" test -e "$CODEX_OLD"
assert_success "the young entry survives" test -d "$CODEX_YOUNG"
assert_success "a marketplace-backup-* sibling survives" test -f "$CODEX_BACKUP/payload.bin"
assert_success "an in-bound symlinked entry and its target survive" \
    repo_paths_exist "$CODEX_LINK" "$CODEX_LINK_TARGET/payload.bin"
assert_success "an entry under a symlinked .staging ancestor survives" test -f "$CODEX_ANC_OLD/payload.bin"
assert_not_contains "$codex_purge_output" "marketplace-upgrade-anc" "an entry under a symlinked ancestor is never a purge candidate"
codex_guard_output="$(codex_purge_path "$CODEX_ROOT/.codex-anc" "$CODEX_ROOT/.codex-anc/.tmp/marketplaces/.staging/marketplace-upgrade-anc")"
assert_contains "$codex_guard_output" "is a symlink)" "the purge guard still refuses a symlinked ancestor directly (defense in depth)"
assert_success "the guard leaves the ancestor-linked entry intact" test -f "$CODEX_ANC_OLD/payload.bin"
codex_delta_line="$(grep '^codex: observed footprint change: ' <<< "$codex_purge_output")"
assert_failure "an elected purge with old entries prints a nonzero observed delta" test -z "${codex_delta_line}" -o "${codex_delta_line#*(}" = "0 bytes)"
assert_eq "0" "$FAILED" "a purge with guarded skips is not a failure"


echo "[codex --yes --include-purge] only young entries -> explicit zero delta"
rm -rf "$CODEX_ROOT" "$CODEX_ELSEWHERE"
mkdir -p "$CODEX_YOUNG"
head -c 2048 /dev/zero > "$CODEX_YOUNG/payload.bin"
reset_logs
codex_run yes true "$CODEX_OUT"
assert_contains "$(cat "$CODEX_OUT")" "codex: observed footprint change: 0.0B (0 bytes)" "an elected purge with only young entries prints an explicit zero delta"
assert_success "the young entry survives" test -d "$CODEX_YOUNG"

CACHE_PRUNE_CODEX_HOME_ROOT="$SANDBOX/empty-codex-home-root"
