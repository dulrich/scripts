# shellcheck shell=bash
#
# Missing-tool suite: every optional host tool the tool probes reports a
# missing executable as `no <tool> on host`, never fails the run, and keeps a
# distinct reason for every other cause (daemon down, trash dir absent).
#
# Sourced by ../cache-prune.sh, the canonical test entry point, which owns the
# harness, the sandbox and the command doubles. Not runnable on its own. The
# fleet modules' missing-tool paths (target, repo's bun) live in
# fleet/*.sh.
# shellcheck disable=SC1091,SC2317,SC2034

# mt_hide <tool> <cmd...>: run <cmd> in a subshell where `command -v <tool>`
# fails, whatever the host (or the suite's command doubles) provide.
mt_hide() {
    local tool="$1"
    shift
    (
        eval "command() { if [[ \"\${1:-}\" == -v && \"\${2:-}\" == \"$tool\" ]]; then return 1; fi; builtin command \"\$@\"; }"
        "$@"
    )
}

# mt_process <name> <original-detect-definition>: the real detect predicate
# through the real process_runtime; prints the report and the exit status.
mt_process() {
    local name="$1" detect_def="$2" status=0

    if [[ -n "$detect_def" ]]; then
        eval "$detect_def"
    fi
    FAILED=0
    MODE=report
    INCLUDE_PURGE=false
    process_runtime "$name" || status=$?
    printf 'exit=%s failed=%s\n' "$status" "$FAILED"
}

echo "[missing tool] a runtime whose CLI is absent says no <tool> on host and does not fail"
for mt_tool in uv npm pip bun cargo; do
    mt_out=$(mt_hide "$mt_tool" mt_process "$mt_tool" "${ORIGINAL_RT_DETECT[$mt_tool]}" 2>&1)
    assert_contains "$mt_out" "skip: $mt_tool: no $mt_tool on host" "$mt_tool: a missing executable is named"
    assert_contains "$mt_out" "exit=0 failed=0" "$mt_tool: a missing executable never changes the exit status"
done
unset mt_tool mt_out

echo "[missing tool] docker: a missing CLI and a dead daemon are different reasons"
mt_out=$(mt_hide docker mt_process docker "$ORIGINAL_RT_DOCKER_DETECT" 2>&1)
assert_contains "$mt_out" "skip: docker: no docker on host" "a missing docker CLI is named"
assert_contains "$mt_out" "exit=0 failed=0" "a missing docker CLI is not a failure"
DOCKER_INFO_RESULT=1
mt_out=$(mt_process docker "$ORIGINAL_RT_DOCKER_DETECT" 2>&1)
DOCKER_INFO_RESULT=0
assert_contains "$mt_out" "skip: docker: docker daemon not reachable" "a present CLI with a dead daemon keeps its own reason"

echo "[missing tool] trash: a missing gio and an absent trash dir are different reasons"
mt_out=$(CACHE_PRUNE_GIO="$SANDBOX/no-such-gio" mt_process trash "$ORIGINAL_RT_TRASH_DETECT" 2>&1)
assert_contains "$mt_out" "skip: trash: no no-such-gio on host" "a missing gio command is named"
assert_contains "$mt_out" "exit=0 failed=0" "a missing gio is not a failure"
mt_out=$(CACHE_PRUNE_TRASH_DIR="$SANDBOX/absent-trash" mt_process trash "$ORIGINAL_RT_TRASH_DETECT" 2>&1)
assert_contains "$mt_out" "skip: trash: trash dir $SANDBOX/absent-trash absent" "an absent trash dir keeps its own reason"

echo "[missing tool] a runtime with no tool to blame keeps the generic reason"
mt_out=$(mt_process codex "$ORIGINAL_RT_CODEX_DETECT" 2>&1)
assert_contains "$mt_out" "skip: codex: not detected" "codex has no executable to name"

echo "[missing tool] docker residue: a missing jq is named in the report and the election"
mt_out=$(mt_hide jq rt_docker_detail 2>&1)
assert_eq "docker image/container/volume residue: unavailable (no jq on host)" "$mt_out" "the residue detail line names the missing jq"
mt_out=$(mt_hide jq docker_residue_capture 2>&1)
assert_contains "$mt_out" '"image_error":"no jq on host"' "the capture's fail-closed error names the missing jq"
