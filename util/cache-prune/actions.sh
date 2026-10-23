# shellcheck shell=bash

# actions.sh: the election rules that decide which of a runtime's verbs run
# in a given mode, and their execution. The verbs themselves live in
# runtimes/<name>.sh. Sourced by ../cache-prune.sh; not a util subcommand.
#
# Nothing here measures anything: the before/after probes bracketing these
# verbs belong to the lifecycle layer in ../cache-prune.sh, which calls
# run_elected_verbs exactly once between them.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

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
# (docker) can never be purge_elected.
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
#
# Both delegate the mode x tier decision to tier_elected below, which the
# docker residue step uses too -- one election, one place.
#
# tier_elected <kind> <prompt> [<interactive_only_note>]
#   kind safe:  --report -> never; --yes -> always; interactive -> confirm
#   kind purge: --report -> never; --yes -> only with --include-purge;
#               interactive -> confirm only with --include-purge
#   kind optin: as purge, but interactive confirms unconditionally
#   kind item:  per-item confirm -- never under --report or --yes;
#               interactive -> confirm only with --include-purge
# A non-empty interactive_only_note (RT_INTERACTIVE_ONLY) marks
# interactive-only data: under --yes the note is printed and nothing is
# elected, whatever --include-purge says; the skip is a note, not a failure.
tier_elected() {
    local kind="$1"
    local prompt="$2"
    local only_note="${3:-}"

    case "$MODE" in
        yes)
            if [[ -n "$only_note" ]]; then
                printf '%s\n' "$only_note"
                return 1
            fi
            case "$kind" in
                safe) return 0 ;;
                purge|optin) [[ "$INCLUDE_PURGE" == true ]] ;;
                *) return 1 ;;
            esac
            ;;
        interactive)
            case "$kind" in
                safe|optin) confirm "$prompt" ;;
                purge|item) [[ "$INCLUDE_PURGE" == true ]] && confirm "$prompt" ;;
                *) return 1 ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

safe_elected() {
    local name="$1"

    [[ -n "${RT_PRUNE[$name]:-}" ]] || return 1
    tier_elected safe "Prune $name cache?"
}

purge_elected() {
    local name="$1"
    local kind=optin
    local prompt="Purge $name cache? (opt-in, destructive)"

    [[ -n "${RT_PURGE[$name]:-}" ]] || return 1
    # A runtime with a safe verb too (uv, npm) gates its purge behind
    # --include-purge even interactively; a purge-only one does not.
    [[ -n "${RT_PRUNE[$name]:-}" ]] && kind=purge

    # The custom prompt is only built when it can be shown -- trash's probes
    # the trash dir, which --yes never needs.
    if [[ "$MODE" == interactive && -n "${RT_PURGE_PROMPT[$name]:-}" ]]; then
        prompt=$("${RT_PURGE_PROMPT[$name]}")
    fi

    tier_elected "$kind" "$prompt" "${RT_INTERACTIVE_ONLY[$name]:-}"
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
# from the reclaim-effectiveness work). Under --yes, a purge election
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

### guarded deletion ##########################################################

# guarded_remove <root-real> <path>: the one deletion every guarded purge
# ends in. The parent of <path> is resolved and the basename re-appended, so
# a symlinked leaf is removed as a link and never followed. Prints nothing;
# GUARDED_REMOVE_PATH is set to the candidate for the caller's own message.
#   0  removed
#   1  parent unresolvable, or candidate does not exist
#   2  candidate is not strictly inside <root-real> (the root itself too)
#   3  rm failed
guarded_remove() {
    local root_real="$1"
    local path="$2"
    local parent_real candidate

    GUARDED_REMOVE_PATH=""
    parent_real=$(realpath -e -- "${path%/*}" 2>/dev/null) || return 1
    candidate="$parent_real/${path##*/}"
    # shellcheck disable=SC2034  # read by callers that name the path in a message
    GUARDED_REMOVE_PATH="$candidate"
    [[ -e "$candidate" || -L "$candidate" ]] || return 1
    [[ "$candidate" == "$root_real"/* ]] || return 2
    rm -rf --one-file-system -- "$candidate" || return 3
}
