#!/usr/bin/env bash
set -euo pipefail

# cache-prune.sh: report and (optionally) prune rebuildable language-runtime
# caches for the *invoking user*. Every cache here (uv, npm, pip, bun, cargo)
# lives under the calling account, and docker's build cache is reachable only
# through the daemon the calling account can talk to -- running this as root
# would report and prune root's own (almost always empty) caches while
# silently leaving the real ones untouched. Hence require_not_root below,
# the mirror of debian-maintenance.sh's require_root.
#
# Runtimes are described by a small registry (name -> detect / cache-dir /
# size-probe / prune functions, plus a safety class). Adding an ecosystem is
# adding a registry entry, not editing the dispatch logic in process_runtime.
#
# This file owns the command-line surface, the registry and the per-runtime
# lifecycle only. The three modules it sources own the rest, split by
# responsibility -- they live in a subdirectory precisely so util/dispatch.sh,
# which routes util/*.sh, cannot mistake them for subcommands:
#
#   cache-prune/measurement.sh  the probe-record type + the one delta helper
#   cache-prune/adapters.sh     per-runtime detect / locate / size probes
#   cache-prune/actions.sh      the verbs and the election rules
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

# Resolved dynamically (dirname of the *real* path, as util/dispatch.sh does)
# so the modules are still found when this script is invoked through a
# symlink or sourced from a test.
CACHE_PRUNE_LIB=$(dirname "$(realpath "${BASH_SOURCE[0]}")")/cache-prune
# shellcheck source=util/cache-prune/measurement.sh
source "$CACHE_PRUNE_LIB/measurement.sh"
# shellcheck source=util/cache-prune/adapters.sh
source "$CACHE_PRUNE_LIB/adapters.sh"
# shellcheck source=util/cache-prune/actions.sh
source "$CACHE_PRUNE_LIB/actions.sh"

FAILED=0
TOTAL_BYTES=0
# The old single RECLAIMABLE_BYTES conflated a safe-verb prediction with a
# purge-verb one under one figure -- split per tier (WP-3, decision 4 of
# plans/cache-prune-reclaim-effectiveness.md): a runtime's census reclaimable
# bytes are routed into exactly one of these (or neither, for cargo, which
# has no verb at all) by report_measurement, never both.
SAFE_RECLAIMABLE_BYTES=0
PURGE_RECLAIMABLE_BYTES=0
# DELTA_BYTES: the grand-total observed footprint change, summed only over
# runtimes that produced a usable delta (see report_delta). Signed -- a
# concurrent cache write can make an individual runtime's delta negative.
DELTA_BYTES=0

# Lifecycle slots. process_runtime's helpers hand their results back through
# these rather than through stdout, because those helpers also print
# user-facing text (and, via the election helpers, prompt): capturing them in
# a command substitution would swallow the report and break interactivity.
# The measurement helper is the exception -- it prints nothing, so its record
# travels on stdout like every other probe record.
RUNTIME_CACHE_DIR=""
RUNTIME_ACTED=false
RUNTIME_VERB_FAILED=false

section() {
    printf '\n==== %s ====\n' "$1"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

confirm() {
    local prompt="${1:-Continue?}"
    local reply

    read -r -p "$prompt [y/N] " reply
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# set_docker_until: validate a --docker-until window before accepting it.
# Validation lives here, at parse time, rather than inside the docker size
# probe where it used to sit as a side effect of the age-sum walk. Once that
# walk was removed the string flowed unchecked into `docker builder prune
# --filter`, leaving only the daemon to reject it -- after every other
# runtime had already been reported. An invalid window is a usage error, so
# it is caught before any work happens, like every other bad flag.
set_docker_until() {
    local window="$1"

    if ! docker_window_seconds "$window" >/dev/null; then
        die "invalid --docker-until window: '$window'" \
            "(expected <number><s|m|h|d|w>, e.g. 168h)"
        return 2
    fi

    DOCKER_UNTIL="$window"
}

# require_not_root: the load-bearing guard of this whole script. Takes the
# EUID to check as an optional argument (real bash EUID is read-only, so
# tests parameterize this instead of trying to fake the shell variable).
# shellcheck disable=SC2120  # main() intentionally calls this with no args
require_not_root() {
    local euid="${1:-$EUID}"

    if ((euid == 0)); then
        die "Refusing to run as root: uv/npm/pip/bun/cargo caches live under" \
            "the invoking user's account, not root's -- running this as root" \
            "would report and prune root's own empty caches. Re-run as your" \
            "normal user."
    fi
}

require_tty() {
    if [[ ! -t 0 || ! -t 1 ]]; then
        die "An interactive terminal is required for this mode. Use --report" \
            "or --yes for non-interactive use."
    fi
}

usage() {
    cat <<'EOF'
usage: cache-prune [--report | --yes [--include-purge]]
                    [--docker-until <window>] [-h|--help]

Reports (and, outside --report, optionally prunes) rebuildable
language-runtime caches for the invoking user. Refuses to run as root.

Modes:
  (default)              interactive; per-runtime confirm (default: No)
  --report               report cache sizes only; never prompts, never mutates
  --yes                  auto-confirm the safe verb for uv, npm, docker;
                         pip and bun have no safe verb and are skipped
                         entirely, never prompted
  --yes --include-purge  purges pip and bun (their only verb); for uv and
                         npm this instead runs their purge verb in place
                         of their safe verb, not in addition to it

uv and npm each carry two verbs: a conservative safe verb (uv cache prune,
npm cache verify) that frees little by design, and a destructive purge
verb (uv cache clean, npm cache clean --force) that clears the whole
cache and forces a re-download on next use -- the cache-only bytes this
tool reports as reclaimable are mostly only reachable via the purge verb.
pip and bun have only the destructive purge verb. Interactively, each
destructive purge gets its own separate confirm: pip/bun are offered
theirs unconditionally (it is their only verb), uv/npm are offered theirs
only when --include-purge was also passed -- without it, plain interactive
use never risks their caches.

Options:
  --docker-until <window>  narrow the docker builder prune to records at
                           least that old (default: no filter -- the safe
                           prune targets the full build cache docker
                           itself reports as reclaimable). This widens the
                           tool's previous default scope and is its single
                           highest-risk behaviour change.
  -h, --help               show this help and exit

Notes:
  Reclaimable is reported per tier, never as one combined figure: docker's
  safe-tier figure is an upper bound (Docker's own "not pinned by an active
  build" definition), not a guarantee of what a prune will actually free;
  uv/npm/pip/bun's purge-tier figure is what a full clean would free, and is
  never printed against their safe verb -- uv/npm's safe verb frees an
  unpredictable amount by design (no dry run exists for it) and is reported
  as such rather than with a number attached to it.

  Every action (outside --report) measures the affected cache immediately
  before and after and reports the observed footprint change -- a
  measurement, not an exact attribution: docker's own accounting has been
  measured to disagree with real disk freed by about 1%, and a concurrent
  cache write can make the delta negative. A run that frees nothing reports
  0B explicitly rather than falling back to the estimate.

Honoured environment:
  BUN_INSTALL   overrides bun's install prefix (cache under install/cache)
  CARGO_HOME    overrides cargo's home (registry cache is reported, never
                pruned -- there is no safe cargo prune verb yet)
EOF
}

### registry ##################################################################

RUNTIME_ORDER=(uv npm docker pip bun cargo)

# RT_CLASS describes how a runtime participates in the *safe* tier only
# (RT_PRUNE below) -- it says nothing about purge-tier (RT_PURGE) membership,
# which a safe runtime may or may not also have (uv/npm carry both):
#   safe   -- has a safe verb that runs unprompted under --yes
#   optin  -- has no safe verb; reachable only through the purge tier
#   report -- has no verbs at all
declare -A RT_CLASS=(
    [uv]=safe
    [npm]=safe
    [docker]=safe
    [pip]=optin
    [bun]=optin
    [cargo]=report
)

declare -A RT_DETECT=(
    [uv]=rt_uv_detect
    [npm]=rt_npm_detect
    [docker]=rt_docker_detect
    [pip]=rt_pip_detect
    [bun]=rt_bun_detect
    [cargo]=rt_cargo_detect
)

# docker intentionally has no entry here: its cache is daemon-owned, not a
# directory this account can resolve or `du`.
declare -A RT_CACHE_DIR=(
    [uv]=rt_uv_cache_dir
    [npm]=rt_npm_cache_dir
    [pip]=rt_pip_cache_dir
    [bun]=rt_bun_cache_dir
    [cargo]=rt_cargo_cache_dir
)

declare -A RT_SIZE=(
    [uv]=rt_generic_size
    [npm]=rt_generic_size
    [docker]=rt_docker_size
    [pip]=rt_generic_size
    [bun]=rt_generic_size
    [cargo]=rt_generic_size
)

# RT_PRUNE holds *only* safe verbs -- pip and bun's destructive purges live
# in RT_PURGE below, ending the old conflation where this array held both.
# cargo intentionally has no entry here: report-only, no safe prune verb
# exists yet (cargo-cache is not installed). A future `command -v
# cargo-cache` check could add an entry (and flip cargo's class to safe)
# without restructuring anything else.
declare -A RT_PRUNE=(
    [uv]=rt_uv_prune
    [npm]=rt_npm_prune
    [docker]=rt_docker_prune
)

# RT_PURGE holds destructive purge verbs. uv and npm carry both a safe verb
# above and a purge verb here; pip and bun have no safe verb and live only
# here; docker and cargo have no entry -- docker has no destructive verb at
# all (its safe prune is the only action), and cargo has neither verb (see
# RT_CLASS above).
declare -A RT_PURGE=(
    [uv]=rt_uv_purge
    [npm]=rt_npm_purge
    [pip]=rt_pip_purge
    [bun]=rt_bun_purge
)

# RT_SAFE_ESTIMATE_NOTE: an optional caveat printed under a runtime's
# safe-tier estimate. Registry data rather than an `if [[ $name == docker ]]`
# branch in the report layer -- the reason docker's number needs a caveat is
# a property of docker's source, not of the reporting lifecycle.
declare -A RT_SAFE_ESTIMATE_NOTE=(
    [docker]='note: docker reclaimable is an upper bound (not pinned by an active build), not a guarantee of what a prune will free.'
)

### mode matrix ###############################################################

MODE="interactive"
INCLUDE_PURGE=false

### lifecycle #################################################################

# resolve_cache_dir: settle where a runtime's cache lives, into
# RUNTIME_CACHE_DIR. Returns 0 to continue, 1 for a hard failure, 2 for a
# graceful skip (both already reported).
resolve_cache_dir() {
    local name="$1"
    local dir_fn="${RT_CACHE_DIR[$name]:-}"
    local status

    RUNTIME_CACHE_DIR=""
    [[ -n "$dir_fn" ]] || return 0

    # `$?` inside a negated `if !`/`&&`/`||` reflects the status of that
    # logical operator, not of the command it wraps -- so the resolver's
    # real exit code (needed here to distinguish a hard failure, 1, from
    # an unresolvable-result skip, 2) must be captured via `|| status=$?`
    # instead, with `status` reset to 0 first.
    status=0
    RUNTIME_CACHE_DIR=$("$dir_fn") || status=$?

    if ((status == 2)); then
        printf 'skip: %s cache location unresolved\n' "$name"
        return 2
    elif ((status != 0)); then
        warn "$name: failed to resolve cache location"
        FAILED=1
        return 1
    fi
}

# measure_runtime: run a runtime's size adapter and echo the probe record it
# returned. Prints nothing else, so the caller can capture it. Exit 1 = the
# probe itself failed; exit 2 = it returned something that is not a
# well-formed record (a regressed adapter emitting a bare pair, junk, or
# nothing). Both are the caller's to report.
measure_runtime() {
    local name="$1"
    local record

    record=$("${RT_SIZE[$name]}" "$RUNTIME_CACHE_DIR") || return 1
    probe_is_valid "$record" || return 2

    printf '%s\n' "$record"
}

# report_measurement: print one runtime's size line and its per-tier
# reclaimable estimate, and fold both into the grand totals.
#
# Which tier a runtime's census reclaimable bytes belong to follows purely
# from registry membership (WP-3 decision 4: never one conflated figure),
# matching the pinned per-runtime-kind table exactly: a runtime with a purge
# verb (uv/npm dual-verb, pip/bun purge-only) reports it as a purge-tier
# estimate -- for uv/npm this is the *only* figure printed, because their
# safe verb cannot be predicted (premises (b)/(c)); a runtime with only a
# safe verb (docker) reports it safe-tier; a runtime with neither (cargo)
# reports neither -- its bytes go into TOTAL_BYTES and stop there.
report_measurement() {
    local name="$1"
    local total="$2"
    local reclaimable="$3"

    printf '%s cache size: %s total (%d bytes)\n' \
        "$name" "$(human_bytes "$total")" "$total"
    TOTAL_BYTES=$((TOTAL_BYTES + total))

    if [[ -n "${RT_PURGE[$name]:-}" ]]; then
        printf '%s reclaimable via the purge verb (%s, %d bytes) -- requires --include-purge\n' \
            "$name" "$(human_bytes "$reclaimable")" "$reclaimable"
        PURGE_RECLAIMABLE_BYTES=$((PURGE_RECLAIMABLE_BYTES + reclaimable))
        if [[ -n "${RT_PRUNE[$name]:-}" ]]; then
            printf 'note: %s'"'"'s safe verb cannot be predicted (no dry run exists) -- it is not represented by any reclaimable figure here.\n' "$name"
        fi
    elif [[ -n "${RT_PRUNE[$name]:-}" ]]; then
        printf '%s reclaimable via the safe verb (%s, %d bytes)\n' \
            "$name" "$(human_bytes "$reclaimable")" "$reclaimable"
        SAFE_RECLAIMABLE_BYTES=$((SAFE_RECLAIMABLE_BYTES + reclaimable))
        if [[ -n "${RT_SAFE_ESTIMATE_NOTE[$name]:-}" ]]; then
            printf '%s\n' "${RT_SAFE_ESTIMATE_NOTE[$name]}"
        fi
    fi
}

# report_delta: take the one post-action measurement and report the observed
# footprint change against the before-measurement.
#
# One post-action probe spans every verb that ran: a dual-verb runtime gets
# exactly one before-probe and one after-probe covering both, never a probe
# between them. It runs whether or not a verb reported failure -- a failed
# verb can still have done partial work (edge case 4), and the destructive
# step already happened regardless of whether it can be measured (edge case
# 3), so neither is a reason to skip measuring.
#
# Whether the two measurements may be subtracted at all is not decided here:
# probe_compare owns that, for every runtime alike. An ineligible pair is
# reported as unavailable with probe_compare's reason and contributes
# nothing to DELTA_BYTES -- and, per edge case 3, does not set FAILED: the
# action itself already happened and the user's caches are fine either way,
# only the measurement failed.
report_delta() {
    local name="$1"
    local before="$2"
    local after verdict verdict_status delta note

    after=$(measure_runtime "$name") || after=""

    verdict=$(probe_compare "$name" "$before" "$after")
    read -r verdict_status delta <<< "$verdict"

    if [[ "$verdict_status" != available ]]; then
        printf '%s: observed footprint change: unavailable (%s)\n' \
            "$name" "${verdict#* }"
        return 0
    fi

    DELTA_BYTES=$((DELTA_BYTES + delta))

    note=""
    if [[ "$RUNTIME_VERB_FAILED" == true ]]; then
        # Edge case 4: a failed verb may still have done partial work.
        # Reported, not suppressed -- and still summed into DELTA_BYTES,
        # since it is a genuine measurement, just of a partial result.
        note=" -- partial result: the action above reported failure"
    elif ((delta < 0)); then
        # Edge case 2: reported signed, as observed -- never clamped to
        # zero, never treated as a failure.
        note=" -- negative: the cache grew between probes (a concurrent write can do this)"
    fi
    # Edge case 1: a zero delta prints "0.0B" here exactly like any other
    # value -- never substituted with the estimate, because this is always
    # the freshly computed real number, not a fallback.
    printf '%s: observed footprint change: %s (%d bytes)%s\n' \
        "$name" "$(human_bytes_signed "$delta")" "$delta" "$note"
}

# process_runtime: the whole per-runtime lifecycle, in order --
# detect/resolve, measure/report, elect/run, measure/report the outcome.
# Every step above is a named helper; nothing here is specific to any one
# runtime.
process_runtime() {
    local name="$1"
    local before status
    local before_total before_reclaimable

    RUNTIME_ACTED=false
    RUNTIME_VERB_FAILED=false

    section "$name"

    if ! "${RT_DETECT[$name]}"; then
        printf 'skip: %s not detected\n' "$name"
        return 0
    fi

    status=0
    resolve_cache_dir "$name" || status=$?
    if ((status == 2)); then
        return 0
    elif ((status != 0)); then
        return 1
    fi

    status=0
    before=$(measure_runtime "$name") || status=$?
    if ((status == 1)); then
        warn "$name: failed to determine cache size"
        FAILED=1
        return 1
    elif ((status != 0)); then
        # Seam-contract guard: without it, a probe that regressed to a bare
        # pair (or to nothing) would be read with a field missing and
        # `$((SAFE_RECLAIMABLE_BYTES + ))` would evaluate that as 0 silently
        # -- no crash, just a quietly wrong total, which is exactly the
        # failure class this reporting-fidelity effort exists to eliminate.
        # Treat it as a probe failure, the same path a hard failure takes.
        warn "$name: cache size probe returned a malformed result"
        FAILED=1
        return 1
    fi

    if probe_is_available "$before"; then
        read -r _ before_total before_reclaimable _ <<< "$before"
        report_measurement "$name" "$before_total" "$before_reclaimable"
    else
        printf '%s cache size: unavailable\n' "$name"
    fi

    if [[ "${RT_CLASS[$name]}" == report ]]; then
        printf 'note: no prune verb exists for %s yet; report-only -- these bytes count toward total footprint only, never a reclaimable tier.\n' "$name"
        return 0
    fi

    if ! probe_is_available "$before"; then
        printf 'skip: %s size unavailable, skipping action for safety.\n' "$name"
        return 0
    fi

    if [[ "$MODE" == report ]]; then
        return 0
    fi

    run_elected_verbs "$name"

    if [[ "$RUNTIME_ACTED" == false ]]; then
        printf '%s: skipped.\n' "$name"
    else
        report_delta "$name" "$before"
    fi

    if [[ "$RUNTIME_VERB_FAILED" == true ]]; then
        return 1
    fi
}

main() {
    MODE="interactive"
    INCLUDE_PURGE=false
    DOCKER_UNTIL=""
    FAILED=0
    TOTAL_BYTES=0
    SAFE_RECLAIMABLE_BYTES=0
    PURGE_RECLAIMABLE_BYTES=0
    DELTA_BYTES=0

    while (($#)); do
        case "$1" in
            --report)
                MODE="report"
                shift
                ;;
            --yes)
                MODE="yes"
                shift
                ;;
            --include-purge)
                INCLUDE_PURGE=true
                shift
                ;;
            --docker-until)
                if (($# < 2)); then
                    die "usage: $0 [--report|--yes] [--include-purge] [--docker-until <window>] [-h|--help]"
                    return 2
                fi
                set_docker_until "$2" || return 2
                shift 2
                ;;
            --docker-until=*)
                set_docker_until "${1#*=}" || return 2
                shift
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *)
                die "usage: $0 [--report|--yes] [--include-purge] [--docker-until <window>] [-h|--help]"
                return 2
                ;;
        esac
    done

    # shellcheck disable=SC2119  # no args: checks the real $EUID, by design
    require_not_root

    # --report must work non-TTY (cron/monitoring-safe); --yes without any
    # purge prompt likewise needs no TTY. Only the interactive mode can
    # prompt, so only it requires one -- calling require_tty unconditionally
    # here would break the --report invariant.
    if [[ "$MODE" == interactive ]]; then
        require_tty
    fi

    local name
    for name in "${RUNTIME_ORDER[@]}"; do
        process_runtime "$name" || true
    done

    section "Total"
    printf 'Total cache footprint seen:                   %s (%d bytes)\n' "$(human_bytes "$TOTAL_BYTES")" "$TOTAL_BYTES"
    printf 'Estimated safe-tier reclaimable (upper bound): %s (%d bytes)\n' "$(human_bytes "$SAFE_RECLAIMABLE_BYTES")" "$SAFE_RECLAIMABLE_BYTES"
    printf 'Estimated purge-tier reclaimable (--include-purge): %s (%d bytes)\n' "$(human_bytes "$PURGE_RECLAIMABLE_BYTES")" "$PURGE_RECLAIMABLE_BYTES"
    if [[ "$MODE" != report ]]; then
        printf 'Observed footprint change (measured, not predicted): %s (%d bytes)\n' \
            "$(human_bytes_signed "$DELTA_BYTES")" "$DELTA_BYTES"
    fi
    printf 'Total counts every byte present, including cargo'"'"'s (it has no prune verb); the safe- and purge-tier figures are separate per-verb estimates and are never summed into one number; the observed footprint change is what was actually measured before/after acting, not a prediction.\n'

    if ((FAILED != 0)); then
        return 1
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
