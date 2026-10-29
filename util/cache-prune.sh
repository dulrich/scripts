#!/usr/bin/env bash
# shellcheck source=util/lib/build-id.sh
case " $* " in *" --help "*|*" -h "*) ;; *) . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/build-id.sh"; build_flags "${BASH_SOURCE[0]}" "$@" ;; esac
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
# size-probe / verb functions). Each runtime registers itself from its own
# module, so adding an ecosystem is adding a module, not editing the
# registry or the dispatch logic in process_runtime.
#
# This file owns the command-line surface, the (empty) registry and the
# per-runtime lifecycle only. The modules it sources own the rest, split by
# responsibility -- they live in a subdirectory precisely so util/dispatch.sh,
# which routes util/*.sh, cannot mistake them for subcommands:
#
#   cache-prune/measurement.sh  the probe-record type + the one delta helper
#   cache-prune/adapters.sh     shared size probes (census, path du)
#   cache-prune/actions.sh      the election rules and verb execution
#   cache-prune/docker-residue.sh  docker image/container/volume residue:
#                               classifier (docker's RT_DETAIL) and the
#                               residue removal step (docker's RT_RESIDUE)
#   cache-prune/runtimes/*.sh   one self-registering module per core runtime
#                               (its adapters, verbs and help text)
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
# shellcheck source=util/cache-prune/docker-residue.sh
source "$CACHE_PRUNE_LIB/docker-residue.sh"

FAILED=0
TOTAL_BYTES=0
# Reclaimable bytes are kept per tier, never as one figure that would conflate
# a safe-verb prediction with a purge-verb one: a runtime's census reclaimable
# bytes are routed into exactly one of these (or neither, for a
# runtime with no verbs) by report_measurement, never both.
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
# probe, because the string flows unchecked into `docker builder prune
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

# print_help_fragments: print each help fragment a runtime module contributed
# (see "help fragments" in the registry section), verbatim. An empty array
# prints nothing, so with no fleet module loaded the core help is unchanged.
print_help_fragments() {
    local fragment

    for fragment in "$@"; do
        printf '%s\n' "$fragment"
    done
}

usage() {
    cat <<'EOF'
usage: cache-prune [--report | --yes [--include-purge]]
                    [--docker-until <window>] [-h|--help]

Reports (and, outside --report, optionally prunes) rebuildable
language-runtime caches (uv, npm, docker, pip, bun, cargo) plus leaked
Codex staging copies (codex) and the home trash (trash) for the invoking
user. Refuses to run as root.

Modes:
  (default)              interactive; per-runtime confirm (default: No)
  --report               report cache sizes only; never prompts, never mutates
  --yes                  auto-confirm the safe verb for uv, npm, docker;
                         pip, bun, cargo and codex have no safe verb and are
                         skipped entirely, never prompted; trash is never
                         emptied under --yes
  --yes --include-purge  purges pip, bun, cargo and codex (their only verb;
                         cargo clears registry/src children only); for uv,
                         npm and docker this instead runs their purge verb in
                         place of their safe verb, not in addition to it; trash
                         is still skipped (interactive confirm only)

uv and npm each carry two verbs: a conservative safe verb (uv cache prune,
npm cache verify) that frees little by design, and a destructive purge
verb (uv cache clean, npm cache clean --force) that clears the whole
cache and forces a re-download on next use -- the cache-only bytes this
tool reports as reclaimable are mostly only reachable via the purge verb.
docker carries two verbs too: its safe verb (docker builder prune) frees
the figure reported as reclaimable; its purge verb (docker builder
prune -a) clears the whole unused build cache, up to its reported total,
forcing cold rebuilds, and is never age-filtered.
pip and bun have only the destructive purge verb. Interactively, each
destructive purge gets its own separate confirm: pip/bun are offered
theirs unconditionally (it is their only verb), uv/npm/docker
are offered theirs
only when --include-purge was also passed -- without it, plain interactive
use never risks their caches.

Docker image/container residue (after the build-cache verb(s), from a fresh
classification; never in --report; named volumes are reported, never removed):
  superseded images      an older tag of a repository a live compose
                         service or Dockerfile base uses -- safe tier:
                         removed by --yes (docker rmi <repo:tag>), one
                         confirm interactively
  stale containers       created/exited containers of no current compose
                         service -- purge tier: removed (docker rm) only by
                         --yes --include-purge, or one confirm interactively
                         with --include-purge
  anonymous volumes      dangling volumes labelled com.docker.volume.anonymous
                         that were already dangling before this run's
                         removals -- purge tier, same rule as stale
                         containers (docker volume rm <name>)
  unreferenced images    images nothing live references -- never removed
                         non-interactively; interactive --include-purge
                         offers one confirm per image
  Order: stale containers, anonymous volumes, superseded, unreferenced. Never -f, never prune.
  A per-item failure (e.g. an image still in use) is a warning; the rest
  continue. The step prints its own images/containers/volumes footprint change.

Options:
  --docker-until <window>  narrow the docker safe builder prune (never the
                           purge verb, which is always unfiltered) to records at
                           least that old (default: no filter -- the safe
                           prune targets the full build cache docker
                           itself reports as reclaimable). Opt-in because
                           a window leaves recent build cache in place,
                           while the default clears all of it.
  -h, --help               show this help and exit

EOF
    print_help_fragments "${CACHE_PRUNE_HELP_RUNTIMES[@]}"
    print_help_fragments "${CACHE_PRUNE_HELP_CORE_RUNTIMES[@]}"
    cat <<'EOF'
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
EOF
    print_help_fragments "${CACHE_PRUNE_HELP_CORE_ENV_LEAD[@]}"
    cat <<'EOF'
  CACHE_PRUNE_REPO_ROOT
                overrides the root docker residue classification searches
                for compose files (default /home/_shared_code)
  CACHE_PRUNE_COMPOSE_PROJECT_DIRS
                newline-separated <file>=<dir> pairs, both relative to that
                root: each listed compose file is resolved with
                --project-directory <root>/<dir> (default: none pinned)
EOF
    print_help_fragments "${CACHE_PRUNE_HELP_ENV[@]}"
    print_help_fragments "${CACHE_PRUNE_HELP_CORE_ENV[@]}"
}

### registry ##################################################################

# The registry starts empty: every runtime -- core (runtimes/*.sh) and fleet
# (fleet/*.sh) -- registers itself through register_runtime (its
# RUNTIME_ORDER slot) plus its own RT_* entries below. A runtime's tier
# follows from membership alone: it is safe-tier exactly when it has an
# RT_PRUNE entry, purge-tier when it has an RT_PURGE entry (uv/npm/docker carry
# both), and has no verbs when it has neither.
RUNTIME_ORDER=()

declare -A RT_DETECT=()

# RT_ABSENT: the optional "why was this runtime not detected" function per
# runtime; prints one short reason. A missing executable reads `no <tool> on
# host`; a runtime with no entry (or an empty reason) reads `not detected`.
# Read only from the report layer (process_runtime) -- detect predicates stay
# silent so the probe-record seam is untouched.
declare -A RT_ABSENT=()

# runtime_absent_reason: the skip reason for a runtime whose detect failed.
runtime_absent_reason() {
    local name="$1" reason=""

    if [[ -n "${RT_ABSENT[$name]:-}" ]]; then
        reason=$("${RT_ABSENT[$name]}")
    fi
    printf '%s\n' "${reason:-not detected}"
}

# RT_CACHE_DIR: optional. A runtime whose cache is not one resolvable
# directory (docker's is daemon-owned; codex, trash and fleet residue is
# spread over many directories) has no entry. resolve_cache_dir already
# treats a missing entry as "nothing to resolve" and leaves RUNTIME_CACHE_DIR
# empty, which is exactly what they want; their size adapters ignore the
# positional argument they are handed.
declare -A RT_CACHE_DIR=()

declare -A RT_SIZE=()

# RT_PRUNE holds *only* safe verbs -- destructive purges live in RT_PURGE
# below, ending the old conflation where this array held both.
declare -A RT_PRUNE=()

# RT_PURGE holds destructive purge verbs. A verb that deletes files directly
# rather than delegating to a package manager (codex, fleet modules) passes
# every path through its own guards first.
declare -A RT_PURGE=()

# RT_PURGE_UNPREDICTED_NOTE: for a runtime carrying both verbs whose size probe
# predicts the *safe* verb (docker), not the purge verb. The report keeps the
# probe's reclaimable on the safe line (SAFE_RECLAIMABLE_BYTES) and prints this
# note naming the purge verb's scope instead of a purge figure. The value is the
# note text.
declare -A RT_PURGE_UNPREDICTED_NOTE=()

# RT_DETAIL: an optional per-runtime breakdown printed immediately after the
# runtime's own size line. Registry data, like RT_SAFE_ESTIMATE_NOTE below:
# a runtime whose single reported figure is a sum over materially different
# kinds of residue (docker: build cache vs image/container residue; codex:
# per-profile staging copies, only the old ones reclaimable) owes the reader
# that split, and the fact that it does is a property of that
# runtime's source, not of the reporting lifecycle. The seam exists so the
# size adapter stays a pure probe: it returns one record and prints nothing,
# per the contract at the top of cache-prune/measurement.sh, and the
# user-facing breakdown is printed from here.
declare -A RT_DETAIL=()

# RT_RESIDUE: an optional per-runtime residue step, run by process_runtime
# after run_elected_verbs and the build-cache delta (outside --report, and
# only when the size probe was available). docker's image/container residue
# lives here rather than in RT_PURGE because a purge election replaces the
# safe verb under --yes, which would stop `docker builder prune` running.
# The step sets RUNTIME_ACTED when it removes anything (after the build-cache
# delta has already been reported) and prints its own measured delta.
declare -A RT_RESIDUE=()

# RT_SAFE_ESTIMATE_NOTE: an optional caveat printed under a runtime's
# safe-tier estimate. Registry data rather than an `if [[ $name == docker ]]`
# branch in the report layer -- the reason docker's number needs a caveat is
# a property of docker's source, not of the reporting lifecycle.
declare -A RT_SAFE_ESTIMATE_NOTE=()

# RT_INTERACTIVE_ONLY: purge-tier runtimes that are never elected under
# --yes, whatever --include-purge says -- only an interactive confirm empties
# them. Registry data for the same reason as RT_SAFE_ESTIMATE_NOTE: trash is
# data the user deleted, not a rebuildable cache, and that is a property of
# its source, not of the election logic (same posture as unreferenced docker
# images in cache-prune/docker-residue.sh). The value is the skip note
# purge_elected prints under --yes.
declare -A RT_INTERACTIVE_ONLY=()

# RT_PURGE_PROMPT: an optional function printing a runtime's interactive purge
# confirm text, in place of the generic "Purge <name> cache?" prompt -- for a
# runtime whose confirm owes the user more (trash: the size, and that it is
# user-deleted data).
declare -A RT_PURGE_PROMPT=()

# Help fragments, printed verbatim by usage(). Fleet modules append to
# CACHE_PRUNE_HELP_RUNTIMES / CACHE_PRUNE_HELP_ENV. Core runtime modules use
# their own arrays, because usage() prints them at fixed slots around the
# fleet fragments: CACHE_PRUNE_HELP_CORE_ENV_LEAD before the shared
# CACHE_PRUNE_REPO_ROOT entry and the fleet env, CACHE_PRUNE_HELP_CORE_RUNTIMES
# and CACHE_PRUNE_HELP_CORE_ENV after the fleet fragments.
CACHE_PRUNE_HELP_RUNTIMES=()
CACHE_PRUNE_HELP_ENV=()
CACHE_PRUNE_HELP_CORE_RUNTIMES=()
CACHE_PRUNE_HELP_CORE_ENV_LEAD=()
CACHE_PRUNE_HELP_CORE_ENV=()

# register_runtime <name> [<after>]: insert <name> into RUNTIME_ORDER right
# after <after>; appended when <after> is omitted or not registered (the core
# modules register by appending, in their fixed source order below).
register_runtime() {
    local name="$1"
    local after="${2:-}"
    local entry
    local -a order=()
    local placed=false

    for entry in "${RUNTIME_ORDER[@]}"; do
        order+=("$entry")
        if [[ -n "$after" && "$entry" == "$after" ]]; then
            order+=("$name")
            placed=true
        fi
    done
    $placed || order+=("$name")
    RUNTIME_ORDER=("${order[@]}")
}

### core runtimes #############################################################

# Sourced in this fixed order, which is RUNTIME_ORDER's core order.
# shellcheck source=util/cache-prune/runtimes/uv.sh
source "$CACHE_PRUNE_LIB/runtimes/uv.sh"
# shellcheck source=util/cache-prune/runtimes/npm.sh
source "$CACHE_PRUNE_LIB/runtimes/npm.sh"
# shellcheck source=util/cache-prune/runtimes/docker.sh
source "$CACHE_PRUNE_LIB/runtimes/docker.sh"
# shellcheck source=util/cache-prune/runtimes/pip.sh
source "$CACHE_PRUNE_LIB/runtimes/pip.sh"
# shellcheck source=util/cache-prune/runtimes/bun.sh
source "$CACHE_PRUNE_LIB/runtimes/bun.sh"
# shellcheck source=util/cache-prune/runtimes/cargo.sh
source "$CACHE_PRUNE_LIB/runtimes/cargo.sh"
# shellcheck source=util/cache-prune/runtimes/codex.sh
source "$CACHE_PRUNE_LIB/runtimes/codex.sh"
# shellcheck source=util/cache-prune/runtimes/trash.sh
source "$CACHE_PRUNE_LIB/runtimes/trash.sh"

### fleet modules #############################################################

# Optional, unpublished runtime modules: every util/cache-prune/fleet/*.sh
# present is sourced here, after the core runtimes and before anything
# consumes the registry. A module follows the same contract as runtimes/*.sh,
# and may name a core runtime as its register_runtime <after> slot.
# The directory is absent from the public projection; with it absent nothing
# below runs and core behaviour and output are unchanged. It sits under
# cache-prune/, which util/dispatch.sh's util/*.sh glob cannot reach.
if [[ -d "$CACHE_PRUNE_LIB/fleet" ]]; then
    for cache_prune_module in "$CACHE_PRUNE_LIB"/fleet/*.sh; do
        [[ -f "$cache_prune_module" ]] || continue
        # shellcheck source=/dev/null
        source "$cache_prune_module"
    done
    unset cache_prune_module
fi

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

# measure_runtime: run a runtime's size adapter in the current shell -- so
# the scan globals it fills survive for RT_DETAIL and RT_PURGE_PROMPT -- and
# leave the validated probe record in PROBE_RECORD (measurement.sh). PROBE_RECORD
# is emptied before the adapter runs, so an adapter that sets nothing can
# never pass off a previous call's record as its own. Exit 1 = the probe
# itself failed; exit 2 = it left something that is not a well-formed record
# (a regressed adapter setting a bare pair, junk, or nothing). Both are the
# caller's to report, and on either PROBE_RECORD is left empty.
measure_runtime() {
    local name="$1"

    PROBE_RECORD=""
    if ! "${RT_SIZE[$name]}" "$RUNTIME_CACHE_DIR"; then
        PROBE_RECORD=""
        return 1
    fi
    if [[ -z "$PROBE_RECORD" ]] || ! probe_is_valid "$PROBE_RECORD"; then
        PROBE_RECORD=""
        return 2
    fi
}

# report_measurement: print one runtime's size line and its per-tier
# reclaimable estimate, and fold both into the grand totals.
#
# Which tier a runtime's census reclaimable bytes belong to follows purely
# from registry membership (reclaimable is never one conflated figure),
# matching the pinned per-runtime-kind table exactly: a runtime with a purge
# verb (uv/npm dual-verb, pip/bun purge-only) reports it as a purge-tier
# estimate -- for uv/npm this is the *only* figure printed, because their
# safe verb cannot be predicted (no dry run exists); a runtime with only a
# safe verb (docker) reports it safe-tier -- as does a dual-verb runtime whose
# probe predicts the safe verb (docker, RT_PURGE_UNPREDICTED_NOTE), which adds a
# purge-scope note and never a purge figure; a runtime with neither (none
# today) reports neither -- its bytes go into TOTAL_BYTES and stop there.
report_measurement() {
    local name="$1"
    local total="$2"
    local reclaimable="$3"

    printf '%s cache size: %s total (%d bytes)\n' \
        "$name" "$(human_bytes "$total")" "$total"
    TOTAL_BYTES=$((TOTAL_BYTES + total))

    if [[ -n "${RT_PURGE[$name]:-}" && -z "${RT_PURGE_UNPREDICTED_NOTE[$name]:-}" ]]; then
        local gate='requires --include-purge'
        if [[ -n "${RT_INTERACTIVE_ONLY[$name]:-}" ]]; then
            gate='emptied only after an interactive confirm, never under --yes'
        fi
        printf '%s reclaimable via the purge verb (%s, %d bytes) -- %s\n' \
            "$name" "$(human_bytes "$reclaimable")" "$reclaimable" "$gate"
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
        if [[ -n "${RT_PURGE[$name]:-}" && -n "${RT_PURGE_UNPREDICTED_NOTE[$name]:-}" ]]; then
            printf '%s\n' "${RT_PURGE_UNPREDICTED_NOTE[$name]}"
        fi
    fi
}

# report_delta: take the one post-action measurement and report the observed
# footprint change against the before-measurement.
#
# One post-action probe spans every verb that ran: a dual-verb runtime gets
# exactly one before-probe and one after-probe covering both, never a probe
# between them. It runs whether or not a verb reported failure -- a failed
# verb can still have done partial work, and the destructive step already
# happened regardless of whether it can be measured, so neither is a reason
# to skip measuring.
#
# Whether the two measurements may be subtracted at all is not decided here:
# probe_compare owns that, for every runtime alike. An ineligible pair is
# reported as unavailable with probe_compare's reason and contributes
# nothing to DELTA_BYTES -- and does not set FAILED: the
# action itself already happened and the user's caches are fine either way,
# only the measurement failed.
report_delta() {
    local name="$1"
    local before="$2"
    local after verdict verdict_status delta note

    after=""
    if measure_runtime "$name"; then
        after="$PROBE_RECORD"
    fi

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
        printf 'skip: %s: %s\n' "$name" "$(runtime_absent_reason "$name")"
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
    measure_runtime "$name" || status=$?
    before="$PROBE_RECORD"
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
        if [[ -n "${RT_DETAIL[$name]:-}" ]]; then
            "${RT_DETAIL[$name]}"
        fi
    else
        printf '%s cache size: unavailable\n' "$name"
    fi

    if ! probe_is_available "$before"; then
        printf 'skip: %s size unavailable, skipping action for safety.\n' "$name"
        return 0
    fi

    if [[ "$MODE" == report ]]; then
        return 0
    fi

    run_elected_verbs "$name"

    if [[ "$RUNTIME_ACTED" == true ]]; then
        report_delta "$name" "$before"
    fi

    # The residue step runs after the build-cache verb and its delta line,
    # bracketed by its own measurement -- never folded into either.
    if [[ -n "${RT_RESIDUE[$name]:-}" ]]; then
        "${RT_RESIDUE[$name]}"
    fi

    if [[ "$RUNTIME_ACTED" == false ]]; then
        printf '%s: skipped.\n' "$name"
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
    printf 'Estimated purge-tier reclaimable (--include-purge; trash interactive-only): %s (%d bytes)\n' "$(human_bytes "$PURGE_RECLAIMABLE_BYTES")" "$PURGE_RECLAIMABLE_BYTES"
    if [[ "$MODE" != report ]]; then
        printf 'Observed footprint change (measured, not predicted): %s (%d bytes)\n' \
            "$(human_bytes_signed "$DELTA_BYTES")" "$DELTA_BYTES"
    fi
    printf 'Total counts every byte present, including any runtime with no verb; the safe- and purge-tier figures are separate per-verb estimates and are never summed into one number; the observed footprint change is what was actually measured before/after acting, not a prediction.\n'

    if ((FAILED != 0)); then
        return 1
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
