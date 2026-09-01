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
RECLAIMABLE_BYTES=0

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
  --yes                  auto-confirm safe prunes (uv, npm, docker); the
                         opt-in purges (pip, bun) are skipped entirely and
                         never prompted
  --yes --include-purge  also auto-confirm the opt-in purges (pip, bun)

--include-purge only changes behaviour together with --yes: interactively
the opt-in purges already get their own confirm prompt.

Options:
  --docker-until <window>  age filter for docker builder prune (default: 168h)
  -h, --help               show this help and exit

Notes:
  Docker's reported reclaimable figure is an upper bound (Docker's own
  "not pinned by an active build" definition), not a guarantee of what a
  prune will actually free.

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

### docker ####################################################################

DOCKER_UNTIL="168h"

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
# can `du`). It no longer reads $DOCKER_UNTIL at all -- see
# docker_window_seconds above, which still validates the flag's format and
# still drives rt_docker_prune's filter, but no longer feeds this report.
#
# Source order: `docker buildx du`'s trailing labelled lines first (a far
# more stable parse than any table walk), plain `docker system df`'s Build
# Cache row second, "unavailable" if both fail -- never a partial pair.
# The two sources measure different things and *will* disagree on the same
# machine: buildx's Reclaimable counts records shared with other build
# state, system df's excludes them. Both are legitimate upper bounds over
# what a real prune returns (see plans/cache-reporting-fidelity.md); this
# function deliberately does not try to reconcile them, it just picks per
# the order above.
rt_docker_size() {
    local raw pair

    if raw=$(docker buildx du 2>/dev/null) && pair=$(docker_buildx_du_bytes "$raw"); then
        printf '%s\n' "$pair"
        return 0
    fi

    if raw=$(docker system df 2>/dev/null) && pair=$(docker_system_df_bytes "$raw"); then
        printf '%s\n' "$pair"
        return 0
    fi

    printf 'unavailable\n'
}

# Never `docker image prune`, never `docker system prune` -- only the
# build-cache prune, bounded by the same age window the report above used.
rt_docker_prune() {
    docker builder prune --filter "until=${DOCKER_UNTIL}" --force
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

rt_pip_prune() {
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
rt_bun_prune() {
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

# cargo intentionally has no entry here: report-only, no safe prune verb
# exists yet (cargo-cache is not installed). A future `command -v
# cargo-cache` check could add an entry (and flip cargo's class to safe)
# without restructuring anything else.
declare -A RT_PRUNE=(
    [uv]=rt_uv_prune
    [npm]=rt_npm_prune
    [docker]=rt_docker_prune
    [pip]=rt_pip_prune
    [bun]=rt_bun_prune
)

### mode matrix ###############################################################

MODE="interactive"
INCLUDE_PURGE=false

# should_act: decide, for one runtime's safety class, whether to act this
# run. This is the executable form of the mode matrix:
#
#   --report              -> never (report mode never mutates)
#   --yes, safe            -> always
#   --yes, optin            -> only with --include-purge (no prompt either way)
#   --yes --include-purge, optin -> always
#   interactive, safe/optin -> per-runtime confirm, default No
should_act() {
    local class="$1"
    local name="$2"

    case "$MODE:$class" in
        yes:safe)
            return 0
            ;;
        yes:optin)
            [[ "$INCLUDE_PURGE" == true ]]
            ;;
        interactive:safe)
            confirm "Prune $name cache?"
            ;;
        interactive:optin)
            confirm "Purge $name cache? (opt-in, destructive)"
            ;;
        *)
            return 1
            ;;
    esac
}

process_runtime() {
    local name="$1"
    local class="${RT_CLASS[$name]}"
    local detect_fn="${RT_DETECT[$name]}"
    local dir_fn="${RT_CACHE_DIR[$name]:-}"
    local size_fn="${RT_SIZE[$name]}"
    local prune_fn="${RT_PRUNE[$name]:-}"
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

    if ! size_out=$("$size_fn" "$cache_dir"); then
        warn "$name: failed to determine cache size"
        FAILED=1
        return 1
    fi

    # Seam-contract guard: a probe must return either "unavailable" or
    # exactly two non-negative decimal integers. Without this, a probe that
    # regresses to a single value would have `read -r total reclaimable`
    # leave reclaimable empty, and `$((RECLAIMABLE_BYTES + ))` would
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
        printf '%s cache size: %s total (%d bytes), %s reclaimable (%d bytes)\n' \
            "$name" "$(human_bytes "$total_bytes")" "$total_bytes" \
            "$(human_bytes "$reclaimable_bytes")" "$reclaimable_bytes"
        TOTAL_BYTES=$((TOTAL_BYTES + total_bytes))
        RECLAIMABLE_BYTES=$((RECLAIMABLE_BYTES + reclaimable_bytes))
        if [[ "$name" == docker ]]; then
            printf 'note: docker reclaimable is an upper bound (not pinned by an active build), not a guarantee of what a prune will free.\n'
        fi
    fi

    if [[ "$class" == report ]]; then
        printf 'note: no safe %s prune verb is available yet; report-only.\n' "$name"
        return 0
    fi

    if [[ "$size_out" == unavailable ]]; then
        printf 'skip: %s size unavailable, skipping action for safety.\n' "$name"
        return 0
    fi

    if [[ "$MODE" == report ]]; then
        return 0
    fi

    if should_act "$class" "$name"; then
        if ! "$prune_fn"; then
            warn "$name: prune failed"
            FAILED=1
            return 1
        fi
        printf '%s: prune complete.\n' "$name"
    else
        printf '%s: skipped.\n' "$name"
    fi
}

main() {
    MODE="interactive"
    INCLUDE_PURGE=false
    DOCKER_UNTIL="168h"
    FAILED=0
    TOTAL_BYTES=0
    RECLAIMABLE_BYTES=0

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
                DOCKER_UNTIL="$2"
                shift 2
                ;;
            --docker-until=*)
                DOCKER_UNTIL="${1#*=}"
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
    printf 'Total cache footprint seen: %s (%d bytes)\n' "$(human_bytes "$TOTAL_BYTES")" "$TOTAL_BYTES"
    printf 'Estimated reclaimable:      %s (%d bytes)\n' "$(human_bytes "$RECLAIMABLE_BYTES")" "$RECLAIMABLE_BYTES"
    printf 'Total counts bytes present; reclaimable counts what a prune would actually return.\n'

    if ((FAILED != 0)); then
        return 1
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
