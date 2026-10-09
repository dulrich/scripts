# shellcheck shell=bash
#
# Trash suite: the `trash` runtime -- the user's home trash, emptied only by
# `gio trash --empty` behind an interactive confirm, never under --yes
# (../../cache-prune/adapters.sh probes, ../../cache-prune/actions.sh verb).
#
# Sourced by ../cache-prune.sh, which owns the harness, sandbox and doubles.
# CACHE_PRUNE_GIO is always the harness's recording gio double (never the real
# gio, whose daemon empties the REAL trash regardless of env), and
# CACHE_PRUNE_TRASH_DIR is re-pointed at a sandbox fixture here.
# shellcheck disable=SC1091,SC2317,SC2034

TRASH_FIXTURE="$SANDBOX/trash-fixture"
TRASH_OUT="$SANDBOX/trash-out.log"

trash_build_fixture() {
    rm -rf "$TRASH_FIXTURE"
    mkdir -p "$TRASH_FIXTURE/files/dir1" "$TRASH_FIXTURE/info"
    head -c 4096 /dev/zero > "$TRASH_FIXTURE/files/a.bin"
    head -c 8192 /dev/zero > "$TRASH_FIXTURE/files/dir1/b.bin"
    head -c 100 /dev/zero > "$TRASH_FIXTURE/info/a.bin.trashinfo"
    head -c 100 /dev/zero > "$TRASH_FIXTURE/info/dir1.trashinfo"
}

trash_run() {
    local mode="$1" include="$2"
    all_present
    FAILED=0
    MODE="$mode"
    INCLUDE_PURGE="$include"
    process_runtime trash >"$TRASH_OUT" 2>&1 || true
    MODE="report"
    INCLUDE_PURGE=false
}

trash_reset() {
    reset_logs
    : > "$GIO_LOG_FILE"
    export GIO_RESULT=0
}

trash_build_fixture
CACHE_PRUNE_TRASH_DIR="$TRASH_FIXTURE"
trash_expect=$(( $(du -sb "$TRASH_FIXTURE/files" | awk '{print $1}') + $(du -sb "$TRASH_FIXTURE/info" | awk '{print $1}') ))


echo "[trash detect] gio and the trash dir must both exist"
assert_success "gio double plus fixture dir is detected" rt_trash_detect
CACHE_PRUNE_GIO="$SANDBOX/no-such-gio"
assert_failure "an unresolvable gio command is not detected" rt_trash_detect
CACHE_PRUNE_GIO="$GIO_SHIM_DIR/gio"
CACHE_PRUNE_TRASH_DIR="$SANDBOX/absent-trash"
assert_failure "an absent trash dir is not detected" rt_trash_detect
CACHE_PRUNE_TRASH_DIR="$TRASH_FIXTURE"


echo "[trash --report] files/ + info/ sized, nothing emptied"
trash_reset
assert_eq "available $trash_expect $trash_expect trash" "$(rt_trash_size "")" "size counts files/ + info/, all reclaimable"
trash_run report false
trash_output="$(cat "$TRASH_OUT")"
assert_contains "$trash_output" "trash: 2 items in files/" "detail counts the items in files/"
assert_contains "$trash_output" "emptied only after an interactive confirm, never under --yes" "the reclaimable line states the interactive-only gate"
assert_eq "" "$(cat "$GIO_LOG_FILE")" "--report never invokes gio"
assert_success "--report leaves the fixture intact" test -f "$TRASH_FIXTURE/files/a.bin"


for trash_include in false true; do
    echo "[trash --yes include-purge=$trash_include] never emptied, skip note, not a failure"
    trash_reset
    CONFIRM_RESULT=0
    trash_run yes "$trash_include"
    trash_output="$(cat "$TRASH_OUT")"
    assert_eq "" "$(cat "$GIO_LOG_FILE")" "--yes (include-purge=$trash_include) never invokes gio"
    assert_contains "$trash_output" "skipped: trash needs an interactive confirm" "--yes (include-purge=$trash_include) prints the skip note"
    assert_eq "0:false" "$FAILED:$RUNTIME_ACTED" "--yes (include-purge=$trash_include) skip is no failure and no action"
    assert_not_contains "$trash_output" "trash: observed footprint change" "--yes (include-purge=$trash_include) prints no delta line"
done


echo "[trash interactive] the one confirm gates gio trash --empty"
trash_reset
CONFIRM_RESULT=1
trash_run interactive false
assert_eq "" "$(cat "$GIO_LOG_FILE")" "a declined confirm never invokes gio"
trash_reset
CONFIRM_RESULT=0
trash_run interactive false
assert_eq "trash --empty" "$(cat "$GIO_LOG_FILE")" "an accepted confirm invokes gio with exactly trash --empty"
assert_contains "$CONFIRM_LOG" "Empty trash ($(human_bytes "$trash_expect"), $trash_expect bytes of user-deleted data" "the confirm names the size and that it is user-deleted data"
assert_contains "$(cat "$TRASH_OUT")" "trash: observed footprint change: " "an accepted purge prints a delta line"


echo "[trash interactive] a failing gio is a verb failure"
trash_reset
CONFIRM_RESULT=0
export GIO_RESULT=3
trash_run interactive false
assert_contains "$(cat "$TRASH_OUT")" "trash: prune failed" "a non-zero gio exit is reported as a failed verb"
assert_eq "1" "$FAILED" "a non-zero gio exit sets FAILED"

export GIO_RESULT=0
CONFIRM_RESULT=1
CACHE_PRUNE_TRASH_DIR="$SANDBOX/absent-trash"
