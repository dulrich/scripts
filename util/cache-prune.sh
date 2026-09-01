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
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

FAILED=0
TOTAL_BYTES=0
# The old single RECLAIMABLE_BYTES conflated a safe-verb prediction with a
# purge-verb one under one figure -- split per tier (WP-3, decision 4 of
# plans/cache-prune-reclaim-effectiveness.md): a runtime's census reclaimable
# bytes are routed into exactly one of these (or neither, for cargo, which
# has no verb at all) by process_runtime, never both.
SAFE_RECLAIMABLE_BYTES=0
PURGE_RECLAIMABLE_BYTES=0
# DELTA_BYTES: the grand-total observed footprint change, summed only over
# runtimes that produced a usable delta (see process_runtime). Signed --
# a concurrent cache write can make an individual runtime's delta negative.
DELTA_BYTES=0
# DOCKER_SIZE_SOURCE_FILE: the module-level record of which of
# rt_docker_size's two sources (system-df / buildx-du / unavailable)
# produced its most recent result -- decision 3's source-match invariant
# needs this to refuse a delta built across sources. A plain variable
# assigned inside rt_docker_size cannot serve this role: rt_docker_size
# normally runs inside the subshell a command substitution
# (`size_out=$(rt_docker_size ...)`) forks to capture its stdout, and an
# assignment made there does not survive that subshell exiting -- the same
# hazard util/tests/cache-prune.sh's own ALL_LOG_FILE works around for the
# same reason. A real file does survive it. Empty by default (a no-op for
# every runtime but docker); process_runtime points this at a scratch file
# only around docker's before/after probes -- see there and
# docker_record_source.
DOCKER_SIZE_SOURCE_FILE=""

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

# human_bytes: render a byte count as a short human-readable size.
human_bytes() {
    local bytes="$1"

    awk -v n="$bytes" 'BEGIN {
        split("B KB MB GB TB PB", units, " ")
        i = 1
        while (n >= 1024 && i < 6) {
            n /= 1024
            i++
        }
        printf "%.1f%s", n, units[i]
    }'
}

# human_bytes_signed: like human_bytes, but tolerates a negative byte count.
# An observed footprint delta can be negative (a concurrent cache write
# growing the cache between the before/after probes -- see process_runtime),
# and human_bytes's own magnitude comparison (`n >= 1024`) is never true for
# a negative n, so a large negative delta would otherwise render as a bare
# "-5000000000.0B" instead of converting units. Strip the sign, format the
# magnitude, reattach it.
human_bytes_signed() {
    local bytes="$1"
    local sign=""

    if ((bytes < 0)); then
        sign="-"
        bytes=$((-bytes))
    fi

    printf '%s%s' "$sign" "$(human_bytes "$bytes")"
}

# generic size probe shared by every directory-backed runtime. A missing or
# unreadable cache directory reports "0 0", never an error. Emits
# "<total_bytes> <reclaimable_bytes>" from a single find pass, keyed by
# inode: an inode is reclaimable only when every link to it lives inside
# this tree (the count of links *seen* while walking equals the inode's own
# st_nlink) -- if something outside the tree (a venv) also holds it, freeing
# the cache copy returns nothing. Keying by inode also fixes the total
# itself: a file hardlinked twice within the cache counts once, matching
# what a prune would actually observe, not twice as a naive per-file sum
# would. This replaces `du -sb` outright (measured faster on real trees, not
# just more accurate -- see plans/cache-reporting-fidelity.md); note totals
# will shift slightly versus `du -sb`, which also counted directory inodes,
# while this sums regular files only -- expected, not a regression. `||
# true` on the pipeline keeps a `find` failure (e.g. a permission-denied
# subdirectory) from taking the whole script down under `set -e`: the awk
# END block still emits a well-formed "<total> <reclaimable>" (partial or
# "0 0") even when find's own exit status is non-zero.
rt_generic_size() {
    local dir="$1"
    local raw

    if [[ -z "$dir" || ! -d "$dir" ]]; then
        printf '0 0\n'
        return 0
    fi

    raw=$(find "$dir" -type f -printf '%n %i %s\n' 2>/dev/null |
        awk '{n[$2]=$1; s[$2]=$3; c[$2]++}
             END {for (i in s) {t += s[i]; if (c[i] == n[i]) r += s[i]}
                  printf "%d %d\n", t+0, r+0}') || true

    printf '%s\n' "$raw"
}

### uv ########################################################################

rt_uv_detect() {
    command -v uv >/dev/null 2>&1
}

rt_uv_cache_dir() {
    local dir

    dir=$(uv cache dir) || return 1
    [[ "$dir" == /* ]] || return 2
    printf '%s\n' "$dir"
}

rt_uv_prune() {
    uv cache prune
}

# rt_uv_purge: the destructive purge verb (RT_PURGE). Clears the whole
# cache and forces a re-download on next use -- see rt_uv_prune's near-no-op
# behaviour (premise (c), plans/cache-prune-reclaim-effectiveness.md) for
# why this is the verb that actually reaches the reported reclaimable bytes.
rt_uv_purge() {
    uv cache clean
}

### npm #######################################################################

rt_npm_detect() {
    command -v npm >/dev/null 2>&1
}

# npm here is nvm-managed: its cache location is PATH-dependent, so it is
# always asked for, never hardcoded. `npm config get cache` can print
# "undefined" on some configurations -- treat any non-absolute-path result
# as unresolvable and skip that runtime (exit 2), rather than treating it as
# a hard failure (exit 1, reserved for the command itself erroring out).
rt_npm_cache_dir() {
    local dir

    dir=$(npm config get cache) || return 1
    [[ "$dir" == /* ]] || return 2
    printf '%s\n' "$dir"
}

rt_npm_prune() {
    npm cache verify
}

# rt_npm_purge: the destructive purge verb (RT_PURGE). Clears the whole
# cache and forces a re-download on next use -- see rt_npm_prune's near-no-op
# behaviour (premise (c), plans/cache-prune-reclaim-effectiveness.md) for
# why this is the verb that actually reaches the reported reclaimable bytes.
rt_npm_purge() {
    npm cache clean --force
}

### docker ####################################################################

# Empty by default: the safe prune runs unfiltered. --docker-until (parsed
# by set_docker_until) opts into an age window; see rt_docker_prune.
DOCKER_UNTIL=""

# Detection folds in the daemon preflight: a present CLI with a dead daemon
# (or no permission to talk to it) must be a graceful skip, not an error, so
# `docker info` succeeding is part of the detect predicate itself.
rt_docker_detect() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# docker_window_seconds: parse a duration like "168h" into seconds. Supports
# s/m/h/d/w suffixes. Returns nonzero on anything it doesn't recognise.
docker_window_seconds() {
    local window="$1"

    if [[ ! "$window" =~ ^([0-9]+)(s|m|h|d|w)$ ]]; then
        return 1
    fi

    local num="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"

    case "$unit" in
        s) printf '%d\n' "$num" ;;
        m) printf '%d\n' $((num * 60)) ;;
        h) printf '%d\n' $((num * 3600)) ;;
        d) printf '%d\n' $((num * 86400)) ;;
        w) printf '%d\n' $((num * 604800)) ;;
    esac
}

# docker_size_to_bytes: normalize one docker-rendered size token (e.g.
# "68.26GB", "500MB", "100B") to an integer byte count. Docker's own
# human-size rendering is decimal (1000-based), matching the retiring
# docker_build_cache_bytes's unit_multiplier -- preserved here rather than
# re-derived.
docker_size_to_bytes() {
    local size="$1"

    awk -v size="$size" '
        function unit_multiplier(u) {
            if (u == "kB") return 1000
            if (u == "MB") return 1000 * 1000
            if (u == "GB") return 1000 * 1000 * 1000
            if (u == "TB") return 1000 * 1000 * 1000 * 1000
            return 1
        }
        BEGIN {
            num = size
            gsub(/[A-Za-z]+$/, "", num)
            unit = size
            gsub(/^[0-9.]+/, "", unit)
            printf "%d\n", num * unit_multiplier(unit)
        }
    '
}

# docker_buildx_du_bytes: parse `docker buildx du`'s trailing "Label:<ws>
# value" summary lines for Total and Reclaimable. Matched by label at line
# start (awk's default whitespace field-splitting absorbs the varying
# tab-stop padding docker uses to align "Shared:"/"Private:"/"Total:" of
# different lengths), never by field position or offset from the end --
# the per-record rows above the summary vary in count and some carry a `*`
# shared-marker suffix on their own SIZE field (e.g. "2.052GB*"), which a
# label-anchored match is naturally immune to. Exits nonzero if either
# label is never found, so the caller falls back rather than reporting a
# partial pair.
docker_buildx_du_bytes() {
    local raw="$1"
    local total reclaimable

    total=$(awk '/^Total:/ { v = $2 } END { print v }' <<< "$raw")
    reclaimable=$(awk '/^Reclaimable:/ { v = $2 } END { print v }' <<< "$raw")

    [[ -n "$total" && -n "$reclaimable" ]] || return 1

    printf '%d %d\n' "$(docker_size_to_bytes "$total")" "$(docker_size_to_bytes "$reclaimable")"
}

# docker_system_df_bytes: fallback parse of plain `docker system df`'s
# (non -v) Build Cache row, for hosts without buildx. "Build Cache" is two
# whitespace-separated words, so with the row's own label occupying $1/$2
# the numeric columns (TOTAL/ACTIVE/SIZE/RECLAIMABLE) sit at $3..$6, not
# $2..$5 as a one-word label would put them. SIZE ($5) is total_bytes,
# RECLAIMABLE ($6) is reclaimable_bytes. A reclaimable cell may carry a
# trailing "(NN%)" (seen on sibling rows in this table); stripped
# defensively even though fixed-field indexing already keeps it out of $6
# when it is space-separated. Exits nonzero if no Build Cache row is found.
docker_system_df_bytes() {
    local raw="$1"
    local total reclaimable

    total=$(awk '$1 == "Build" && $2 == "Cache" { v = $5 } END { print v }' <<< "$raw")
    reclaimable=$(awk '$1 == "Build" && $2 == "Cache" { v = $6 } END { print v }' <<< "$raw")
    reclaimable="${reclaimable%%(*}"

    [[ -n "$total" && -n "$reclaimable" ]] || return 1

    printf '%d %d\n' "$(docker_size_to_bytes "$total")" "$(docker_size_to_bytes "$reclaimable")"
}

# rt_docker_size ignores its positional argument (docker has no cache-dir
# resolver: its build cache is daemon-owned, not a directory this account
# can `du`). It no longer reads $DOCKER_UNTIL at all: the window is
# validated at parse time by set_docker_until and drives only
# rt_docker_prune's filter, never this report. Age cannot predict reclaim
# here -- see the DAG note on rt_docker_prune.
#
# Source order: plain `docker system df`'s Build Cache row first, `docker
# buildx du`'s trailing labelled lines second as a fallback, "unavailable"
# if both fail -- never a partial pair. The order tracks correspondence
# with the verb rt_docker_prune actually runs, not parse stability: measured
# live against an unfiltered prune (premise (a),
# plans/cache-prune-reclaim-effectiveness.md), system df's Build Cache
# RECLAIMABLE predicted the freed bytes exactly, while buildx du's
# Reclaimable overstated by the Shared slice it additionally counts. The
# two sources still measure different things and *will* disagree on the
# same machine: buildx's Reclaimable counts records shared with other
# build state, system df's excludes them. Both are legitimate upper bounds
# over what a real prune returns (see plans/cache-reporting-fidelity.md);
# this function deliberately does not try to reconcile them, it just picks
# per the order above.
#
# Also records which source produced the result, via docker_record_source
# (decision 3's source-match invariant, plans/cache-prune-reclaim-
# effectiveness.md): a before/after delta built from a system-df reading and
# a buildx-du reading is not a measurement, it is two different measurements
# subtracted, and premise (d) put their disagreement at ~9 GB on the same
# cache. process_runtime compares the before/after source before trusting a
# docker delta.
docker_record_source() {
    local source_label="$1"

    if [[ -n "$DOCKER_SIZE_SOURCE_FILE" ]]; then
        printf '%s\n' "$source_label" > "$DOCKER_SIZE_SOURCE_FILE"
    fi
}

rt_docker_size() {
    local raw pair

    if raw=$(docker system df 2>/dev/null) && pair=$(docker_system_df_bytes "$raw"); then
        docker_record_source "system-df"
        printf '%s\n' "$pair"
        return 0
    fi

    if raw=$(docker buildx du 2>/dev/null) && pair=$(docker_buildx_du_bytes "$raw"); then
        docker_record_source "buildx-du"
        printf '%s\n' "$pair"
        return 0
    fi

    docker_record_source "unavailable"
    printf 'unavailable\n'
}

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

### pip (opt-in) ##############################################################

rt_pip_detect() {
    command -v pip >/dev/null 2>&1
}

rt_pip_cache_dir() {
    local dir

    dir=$(pip cache dir) || return 1
    [[ "$dir" == /* ]] || return 2
    printf '%s\n' "$dir"
}

rt_pip_purge() {
    pip cache purge
}

### bun (opt-in) ##############################################################

rt_bun_detect() {
    command -v bun >/dev/null 2>&1
}

rt_bun_cache_dir() {
    printf '%s\n' "${BUN_INSTALL:-$HOME/.bun}/install/cache"
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

### cargo (report-only) #######################################################

rt_cargo_detect() {
    command -v cargo >/dev/null 2>&1
}

rt_cargo_cache_dir() {
    printf '%s\n' "${CARGO_HOME:-$HOME/.cargo}/registry"
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

# RT_PRUNE holds *only* safe verbs now -- pip and bun's destructive purges
# migrated to RT_PURGE below, ending the old conflation where this array
# held both. cargo intentionally has no entry here: report-only, no safe
# prune verb exists yet (cargo-cache is not installed). A future `command -v
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

### mode matrix ###############################################################

MODE="interactive"
INCLUDE_PURGE=false

# safe_elected / purge_elected: decide, per runtime, whether this run acts
# through the safe verb (RT_PRUNE) and/or the purge verb (RT_PURGE). Split
# in two -- rather than one should_act -- because a runtime may now carry
# both verbs (uv, npm) and the two elections are independently gated: see
# process_runtime's action block for how the two combine per mode.
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
#                  confirm unconditionally, same as today -- suppressing
#                  this would make interactive mode silently do nothing for
#                  them, since the purge verb is their *only* verb;
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

# run_verb: execute one verb function (either tier), with the shared
# failure/success reporting both share. Wording says "prune" even for a
# purge -- imprecise, left as-is: pip/bun must stay byte-identical to
# 4b9652d, and WP-3 owns the reporting rewrite. Failure handling here is
# unchanged by WP-3 (warn, FAILED=1, return 1): it is process_runtime's use
# of this return value that changed, not run_verb itself -- see the
# `verb_failed` handling below, which defers the early return past the
# post-action size probe instead of returning immediately the way
# `run_verb ... || return 1` used to.
run_verb() {
    local name="$1"
    local verb_fn="$2"

    if ! "$verb_fn"; then
        warn "$name: prune failed"
        FAILED=1
        return 1
    fi
    printf '%s: prune complete.\n' "$name"
}

process_runtime() {
    local name="$1"
    local class="${RT_CLASS[$name]}"
    local detect_fn="${RT_DETECT[$name]}"
    local dir_fn="${RT_CACHE_DIR[$name]:-}"
    local size_fn="${RT_SIZE[$name]}"
    local cache_dir=""
    local size_out status
    local total_bytes reclaimable_bytes

    section "$name"

    if ! "$detect_fn"; then
        printf 'skip: %s not detected\n' "$name"
        return 0
    fi

    if [[ -n "$dir_fn" ]]; then
        # `$?` inside a negated `if !`/`&&`/`||` reflects the status of that
        # logical operator, not of the command it wraps -- so the resolver's
        # real exit code (needed here to distinguish a hard failure, 1, from
        # an unresolvable-result skip, 2) must be captured via `|| status=$?`
        # instead, with `status` reset to 0 first.
        status=0
        cache_dir=$("$dir_fn") || status=$?
        if ((status == 2)); then
            printf 'skip: %s cache location unresolved\n' "$name"
            return 0
        elif ((status != 0)); then
            warn "$name: failed to resolve cache location"
            FAILED=1
            return 1
        fi
    fi

    # DOCKER_SIZE_SOURCE_FILE: shadows the script-level global of the same
    # name for the rest of this call only, pointed at a scratch file so
    # rt_docker_size's source recording survives the command-substitution
    # subshell both the before- and after-probe calls below fork (see
    # docker_record_source). Every other runtime leaves this at its
    # script-level default (""), so docker_record_source is a no-op for
    # them. The RETURN trap fires on every exit from this specific
    # invocation, whichever of the several return points below is taken --
    # verified: a trap set this way is scoped per call, not leaked across
    # process_runtime's many calls in RUNTIME_ORDER or across the test
    # suite's repeated direct calls.
    local DOCKER_SIZE_SOURCE_FILE=""
    local docker_before_source="" docker_after_source=""
    if [[ "$name" == docker ]]; then
        DOCKER_SIZE_SOURCE_FILE=$(mktemp) || DOCKER_SIZE_SOURCE_FILE=""
        if [[ -n "$DOCKER_SIZE_SOURCE_FILE" ]]; then
            trap 'rm -f "$DOCKER_SIZE_SOURCE_FILE"' RETURN
        fi
    fi

    if ! size_out=$("$size_fn" "$cache_dir"); then
        warn "$name: failed to determine cache size"
        FAILED=1
        return 1
    fi

    if [[ "$name" == docker && -n "$DOCKER_SIZE_SOURCE_FILE" ]]; then
        docker_before_source=$(cat "$DOCKER_SIZE_SOURCE_FILE" 2>/dev/null || true)
    fi

    # Seam-contract guard: a probe must return either "unavailable" or
    # exactly two non-negative decimal integers. Without this, a probe that
    # regresses to a single value would have `read -r total reclaimable`
    # leave reclaimable empty, and `$((SAFE_RECLAIMABLE_BYTES + ))` would
    # evaluate that as 0 silently -- no crash, just a quietly wrong
    # reclaimable total, which is exactly the failure class this whole
    # reporting-fidelity effort exists to eliminate. Treat it as a probe
    # failure, the same path a hard failure above already takes.
    if [[ "$size_out" != unavailable && ! "$size_out" =~ ^[0-9]+\ [0-9]+$ ]]; then
        warn "$name: cache size probe returned a malformed result"
        FAILED=1
        return 1
    fi

    if [[ "$size_out" == unavailable ]]; then
        printf '%s cache size: unavailable\n' "$name"
    else
        read -r total_bytes reclaimable_bytes <<< "$size_out"
        printf '%s cache size: %s total (%d bytes)\n' \
            "$name" "$(human_bytes "$total_bytes")" "$total_bytes"
        TOTAL_BYTES=$((TOTAL_BYTES + total_bytes))

        # Per-tier estimate routing (WP-3 decision 4: never one conflated
        # figure). Which tier a runtime's census reclaimable bytes belong to
        # follows purely from registry membership, matching the pinned
        # per-runtime-kind table exactly: a runtime with a purge verb
        # (uv/npm dual-verb, pip/bun purge-only) reports it as a purge-tier
        # estimate -- for uv/npm this is the *only* figure printed, because
        # their safe verb cannot be predicted (premises (b)/(c)); a runtime
        # with only a safe verb (docker) reports it safe-tier; a runtime
        # with neither (cargo) reports neither -- its bytes already went
        # into TOTAL_BYTES above and stop there.
        if [[ -n "${RT_PURGE[$name]:-}" ]]; then
            printf '%s reclaimable via the purge verb (%s, %d bytes) -- requires --include-purge\n' \
                "$name" "$(human_bytes "$reclaimable_bytes")" "$reclaimable_bytes"
            PURGE_RECLAIMABLE_BYTES=$((PURGE_RECLAIMABLE_BYTES + reclaimable_bytes))
            if [[ -n "${RT_PRUNE[$name]:-}" ]]; then
                printf 'note: %s'"'"'s safe verb cannot be predicted (no dry run exists) -- it is not represented by any reclaimable figure here.\n' "$name"
            fi
        elif [[ -n "${RT_PRUNE[$name]:-}" ]]; then
            printf '%s reclaimable via the safe verb (%s, %d bytes)\n' \
                "$name" "$(human_bytes "$reclaimable_bytes")" "$reclaimable_bytes"
            SAFE_RECLAIMABLE_BYTES=$((SAFE_RECLAIMABLE_BYTES + reclaimable_bytes))
            if [[ "$name" == docker ]]; then
                printf 'note: docker reclaimable is an upper bound (not pinned by an active build), not a guarantee of what a prune will free.\n'
            fi
        fi
    fi

    if [[ "$class" == report ]]; then
        printf 'note: no prune verb exists for %s yet; report-only -- these bytes count toward total footprint only, never a reclaimable tier.\n' "$name"
        return 0
    fi

    if [[ "$size_out" == unavailable ]]; then
        printf 'skip: %s size unavailable, skipping action for safety.\n' "$name"
        return 0
    fi

    if [[ "$MODE" == report ]]; then
        return 0
    fi

    # Election helpers prompt as a side effect (confirm()), so evaluation
    # order here *is* the behaviour, not just style -- see safe_elected/
    # purge_elected above and the pinned mode-matrix resolution (Decision 7,
    # plans/cache-prune-reclaim-effectiveness.md). Under --yes, a purge
    # election supersedes the safe verb for a dual-verb runtime and the safe
    # verb never runs -- its work is a strict subset, so running both would
    # waste time and muddy the freed-bytes accounting below. Interactively
    # each elected verb runs, safe first: interactive mode is confirm-driven,
    # so a user who accepts both prompts explicitly asked for both.
    #
    # `verb_failed` (not an immediate `return 1`) is WP-3's restructuring of
    # this block: a failed verb must still be measured (edge case 4, the
    # brief), so the failure is recorded and checked at the very end of this
    # function, after the post-action probe/delta section below runs -- not
    # here. A failed safe verb still short-circuits the purge election that
    # would otherwise follow it, exactly as the old `|| return 1` did (see
    # the `verb_failed == false` guard on the second `if` in the interactive
    # branch): the difference is only *when* process_runtime finally returns
    # 1, never *whether* the purge election is skipped after a safe-verb
    # failure.
    local acted=false
    local verb_failed=false

    if [[ "$MODE" == yes ]]; then
        if purge_elected "$name"; then
            acted=true
            run_verb "$name" "${RT_PURGE[$name]}" || verb_failed=true
        elif safe_elected "$name"; then
            acted=true
            run_verb "$name" "${RT_PRUNE[$name]}" || verb_failed=true
        fi
    else
        if safe_elected "$name"; then
            acted=true
            run_verb "$name" "${RT_PRUNE[$name]}" || verb_failed=true
        fi
        if [[ "$verb_failed" == false ]] && purge_elected "$name"; then
            acted=true
            run_verb "$name" "${RT_PURGE[$name]}" || verb_failed=true
        fi
    fi

    if [[ "$acted" == false ]]; then
        printf '%s: skipped.\n' "$name"
    else
        # Part A -- the observed footprint delta (WP-3, decision 3 of
        # plans/cache-prune-reclaim-effectiveness.md). One post-action probe
        # spans every verb that ran above: a dual-verb runtime gets exactly
        # one before-probe and one after-probe covering both, never a probe
        # between them. Runs whether or not a verb above reported failure --
        # a failed verb can still have done partial work (edge case 4), and
        # the destructive step already happened regardless of whether it can
        # be measured (edge case 3), so neither is a reason to skip
        # measuring.
        local after_out after_status
        after_status=0
        after_out=$("$size_fn" "$cache_dir") || after_status=$?

        if [[ "$name" == docker && -n "$DOCKER_SIZE_SOURCE_FILE" ]]; then
            docker_after_source=$(cat "$DOCKER_SIZE_SOURCE_FILE" 2>/dev/null || true)
        fi

        if ((after_status != 0)) || [[ "$after_out" == unavailable ]] || [[ ! "$after_out" =~ ^[0-9]+\ [0-9]+$ ]]; then
            # Edge case 3: the action itself already happened and the
            # user's caches are fine either way -- only the *measurement*
            # failed, so this does not set FAILED and this runtime is
            # excluded from DELTA_BYTES below (nothing is added to it).
            printf '%s: observed footprint change: unavailable (the post-action size probe failed)\n' "$name"
        elif [[ "$name" == docker && "$docker_before_source" != "$docker_after_source" ]]; then
            # Source-match invariant: a delta built from a system-df before
            # and a buildx-du after (or vice versa) is not a measurement of
            # anything -- premise (d) put the two sources' disagreement at
            # ~9 GB on the same cache. Never computed across sources;
            # excluded from DELTA_BYTES exactly like an unavailable probe.
            printf '%s: observed footprint change: unavailable (docker size source changed between probes: %s -> %s)\n' \
                "$name" "${docker_before_source:-none}" "${docker_after_source:-none}"
        else
            local after_total delta delta_note
            read -r after_total _ <<< "$after_out"
            delta=$((total_bytes - after_total))
            DELTA_BYTES=$((DELTA_BYTES + delta))

            delta_note=""
            if [[ "$verb_failed" == true ]]; then
                # Edge case 4: a failed verb may still have done partial
                # work. Reported, not suppressed -- and still summed into
                # DELTA_BYTES, since it is a genuine measurement, just of a
                # partial result.
                delta_note=" -- partial result: the action above reported failure"
            elif ((delta < 0)); then
                # Edge case 2: reported signed, as observed -- never
                # clamped to zero, never treated as a failure.
                delta_note=" -- negative: the cache grew between probes (a concurrent write can do this)"
            fi
            # Edge case 1: a zero delta prints "0.0B" here via the normal
            # path below, exactly like any other value -- never substituted
            # with the estimate, because this is always the freshly
            # computed real number, not a fallback.
            printf '%s: observed footprint change: %s (%d bytes)%s\n' \
                "$name" "$(human_bytes_signed "$delta")" "$delta" "$delta_note"
        fi
    fi

    if [[ "$verb_failed" == true ]]; then
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
    DOCKER_SIZE_SOURCE_FILE=""

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
