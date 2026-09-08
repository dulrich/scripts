# shellcheck shell=bash

# actions.sh: the verbs cache-prune can run, and the election rules that
# decide which of them run for a given runtime in a given mode. Sourced by
# ../cache-prune.sh; not a util subcommand.
#
# Nothing here measures anything: the before/after probes bracketing these
# verbs belong to the lifecycle layer in ../cache-prune.sh, which calls
# run_elected_verbs exactly once between them.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

### safe verbs ################################################################

rt_uv_prune() {
    uv cache prune
}

rt_npm_prune() {
    npm cache verify
}

# Empty by default: the safe prune runs unfiltered. --docker-until (parsed
# and validated by set_docker_until) opts into an age window.
DOCKER_UNTIL=""

# Never `docker image prune`, never `docker system prune` -- only the
# build-cache prune. Unfiltered by default: the `until=168h` age filter
# this used to carry blocked most of what docker itself calls reclaimable,
# because the build-cache DAG retains an old parent record whenever it has
# a recent child, regardless of the parent's own age. Measured live
# (premise (a), plans/cache-prune-reclaim-effectiveness.md): an unfiltered
# prune freed the reported Private slice exactly and touched nothing
# docker considers ACTIVE. That guarantee -- a prune never removes an
# ACTIVE record -- is the safety basis for the unfiltered default, not the
# age window. --docker-until still narrows the prune to records at least
# that old when a caller explicitly opts in; DOCKER_UNTIL is empty by
# default, so no --filter argument is passed at all, not an empty one.
rt_docker_prune() {
    if [[ -n "$DOCKER_UNTIL" ]]; then
        docker builder prune --filter "until=${DOCKER_UNTIL}" --force
    else
        docker builder prune --force
    fi
}

### purge verbs (destructive) #################################################

# rt_uv_purge / rt_npm_purge: the destructive purge verbs (RT_PURGE). Each
# clears the whole cache and forces a re-download on next use -- see the
# near-no-op behaviour of their safe counterparts above (premise (c),
# plans/cache-prune-reclaim-effectiveness.md) for why this is the verb that
# actually reaches the reported reclaimable bytes.
rt_uv_purge() {
    uv cache clean
}

rt_npm_purge() {
    npm cache clean --force
}

rt_pip_purge() {
    pip cache purge
}

# `bun pm cache rm` fails outside a package directory (measured: "No
# package.json was found for directory ..."), so it is run from a scratch
# directory holding a minimal package.json. If it still fails, warn and skip
# -- never fall back to deleting the cache path ourselves.
rt_bun_purge() {
    local scratch
    local status
    local oldpwd="$PWD"

    scratch=$(mktemp -d) || return 1
    printf '{}\n' > "$scratch/package.json"

    if ! cd "$scratch"; then
        rm -rf "$scratch"
        return 1
    fi

    status=0
    bun pm cache rm || status=$?

    cd "$oldpwd" || true
    rm -rf "$scratch"
    return "$status"
}

### election ##################################################################

# safe_elected / purge_elected: decide, per runtime, whether this run acts
# through the safe verb (RT_PRUNE) and/or the purge verb (RT_PURGE). Split
# in two -- rather than one should_act -- because a runtime may carry both
# verbs (uv, npm) and the two elections are independently gated: see
# run_elected_verbs below for how the two combine per mode.
#
# Each returns false outright when the runtime has no entry in its own
# registry array, regardless of mode -- a runtime with no RT_PRUNE entry
# (pip, bun) can never be safe_elected, and one with no RT_PURGE entry
# (docker, cargo) can never be purge_elected.
#
#   safe_elected:  --report -> never; --yes -> always; interactive ->
#                  confirm "Prune $name cache?"
#   purge_elected: --report -> never; --yes -> only with --include-purge;
#                  interactive, class optin (pip/bun, purge-only) ->
#                  confirm unconditionally -- suppressing this would make
#                  interactive mode silently do nothing for them, since the
#                  purge verb is their *only* verb;
#                  interactive, class safe (uv/npm, dual-verb) -> confirm
#                  only when --include-purge was also passed -- otherwise a
#                  plain interactive run would start prompting to blow away
#                  caches nobody asked to touch. This asymmetry is
#                  deliberate; do not unify the two interactive branches.
safe_elected() {
    local name="$1"

    [[ -n "${RT_PRUNE[$name]:-}" ]] || return 1

    case "$MODE" in
        yes)
            return 0
            ;;
        interactive)
            confirm "Prune $name cache?"
            ;;
        *)
            return 1
            ;;
    esac
}

purge_elected() {
    local name="$1"
    local class="${RT_CLASS[$name]}"

    [[ -n "${RT_PURGE[$name]:-}" ]] || return 1

    case "$MODE" in
        yes)
            [[ "$INCLUDE_PURGE" == true ]]
            ;;
        interactive)
            case "$class" in
                safe)
                    [[ "$INCLUDE_PURGE" == true ]] && confirm "Purge $name cache? (opt-in, destructive)"
                    ;;
                *)
                    confirm "Purge $name cache? (opt-in, destructive)"
                    ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

### execution #################################################################

# run_verb: execute one verb function (either tier), with the shared
# failure/success reporting both share. Wording says "prune" even for a
# purge -- imprecise, left as-is: pip/bun's output must stay byte-identical
# to 4b9652d.
run_verb() {
    local name="$1"
    local verb_fn="$2"

    if ! "$verb_fn"; then
        warn "$name: prune failed"
        # shellcheck disable=SC2034  # FAILED is the aggregate exit flag, read by main() in ../cache-prune.sh
        FAILED=1
        return 1
    fi
    printf '%s: prune complete.\n' "$name"
}

# run_elected_verbs: run whichever verbs this mode elects for one runtime,
# in the pinned order, and report back through RUNTIME_ACTED /
# RUNTIME_VERB_FAILED rather than stdout -- the election helpers prompt the
# user as a side effect (confirm()), so this cannot be wrapped in a command
# substitution without swallowing the prompts.
#
# Election order *is* the behaviour, not style (Decision 7,
# plans/cache-prune-reclaim-effectiveness.md). Under --yes, a purge election
# supersedes the safe verb for a dual-verb runtime and the safe verb never
# runs -- its work is a strict subset, so running both would waste time and
# muddy the freed-bytes accounting. Interactively each elected verb runs,
# safe first: interactive mode is confirm-driven, so a user who accepts both
# prompts explicitly asked for both.
#
# A failed verb is recorded, not returned early: it must still be measured
# (edge case 4), so the lifecycle layer probes after this returns and only
# then propagates the failure. A failed safe verb still short-circuits the
# purge election that would otherwise follow it -- the `RUNTIME_VERB_FAILED
# == false` guard on the second interactive `if`.
run_elected_verbs() {
    local name="$1"

    # shellcheck disable=SC2034  # RUNTIME_ACTED is read by process_runtime() in ../cache-prune.sh
    RUNTIME_ACTED=false
    RUNTIME_VERB_FAILED=false

    if [[ "$MODE" == yes ]]; then
        if purge_elected "$name"; then
            # shellcheck disable=SC2034  # see the RUNTIME_ACTED note above
            RUNTIME_ACTED=true
            run_verb "$name" "${RT_PURGE[$name]}" || RUNTIME_VERB_FAILED=true
        elif safe_elected "$name"; then
            # shellcheck disable=SC2034  # see the RUNTIME_ACTED note above
            RUNTIME_ACTED=true
            run_verb "$name" "${RT_PRUNE[$name]}" || RUNTIME_VERB_FAILED=true
        fi
    else
        if safe_elected "$name"; then
            # shellcheck disable=SC2034  # see the RUNTIME_ACTED note above
            RUNTIME_ACTED=true
            run_verb "$name" "${RT_PRUNE[$name]}" || RUNTIME_VERB_FAILED=true
        fi
        if [[ "$RUNTIME_VERB_FAILED" == false ]] && purge_elected "$name"; then
            # shellcheck disable=SC2034  # see the RUNTIME_ACTED note above
            RUNTIME_ACTED=true
            run_verb "$name" "${RT_PURGE[$name]}" || RUNTIME_VERB_FAILED=true
        fi
    fi

    return 0
}
