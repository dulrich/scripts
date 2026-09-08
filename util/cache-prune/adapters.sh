# shellcheck shell=bash

# adapters.sh: per-runtime detection, cache-location resolution and size
# probes for cache-prune. Sourced by ../cache-prune.sh; not a util subcommand.
#
# Every rt_*_size adapter here returns exactly one probe record (see
# measurement.sh for the format) and prints no user-facing text: what a
# measurement means, and whether it can be compared with another one, belongs
# to the lifecycle/report layer in ../cache-prune.sh, not here.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

### directory-backed census ###################################################

# dir_census_bytes: the raw inode census shared by every directory-backed
# runtime, emitting "<total_bytes> <reclaimable_bytes>" from a single find
# pass, keyed by inode: an inode is reclaimable only when every link to it
# lives inside this tree (the count of links *seen* while walking equals the
# inode's own st_nlink) -- if something outside the tree (a venv) also holds
# it, freeing the cache copy returns nothing. Keying by inode also fixes the
# total itself: a file hardlinked twice within the cache counts once,
# matching what a prune would actually observe, not twice as a naive
# per-file sum would. This replaced `du -sb` outright (measured faster on
# real trees, not just more accurate -- see plans/cache-reporting-fidelity.md);
# note totals will shift slightly versus `du -sb`, which also counted
# directory inodes, while this sums regular files only -- expected, not a
# regression. `|| true` on the pipeline keeps a `find` failure (e.g. a
# permission-denied subdirectory) from taking the whole script down under
# `set -e`: the awk END block still emits a well-formed pair (partial or
# "0 0") even when find's own exit status is non-zero.
#
# A missing or unreadable cache directory censuses as "0 0", never an error.
dir_census_bytes() {
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

# rt_generic_size: the RT_SIZE adapter every directory-backed runtime uses.
# Wraps dir_census_bytes' pair into a probe record whose source identity is
# the census itself -- one source, so a before/after pair from it is always
# comparable, exactly like docker's when its source does not change.
rt_generic_size() {
    local pair total reclaimable

    pair=$(dir_census_bytes "$1")
    read -r total reclaimable <<< "$pair"

    if [[ ! "$total" =~ ^[0-9]+$ || ! "$reclaimable" =~ ^[0-9]+$ ]]; then
        probe_unavailable
        return 0
    fi

    probe_available "$total" "$reclaimable" "census"
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

### docker ####################################################################

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
# human-size rendering is decimal (1000-based).
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
# can `du`). It does not read $DOCKER_UNTIL either: the window is validated
# at parse time by set_docker_until and drives only rt_docker_prune's
# filter, never this report. Age cannot predict reclaim here -- see the DAG
# note on rt_docker_prune.
#
# Source order: plain `docker system df`'s Build Cache row first, `docker
# buildx du`'s trailing labelled lines second as a fallback, unavailable if
# both fail -- never a partial pair. The order tracks correspondence with
# the verb rt_docker_prune actually runs, not parse stability: measured live
# against an unfiltered prune (premise (a),
# plans/cache-prune-reclaim-effectiveness.md), system df's Build Cache
# RECLAIMABLE predicted the freed bytes exactly, while buildx du's
# Reclaimable overstated by the Shared slice it additionally counts. The
# two sources still measure different things and *will* disagree on the
# same machine: buildx's Reclaimable counts records shared with other build
# state, system df's excludes them. Both are legitimate upper bounds over
# what a real prune returns (see plans/cache-reporting-fidelity.md); this
# function deliberately does not try to reconcile them, it just picks per
# the order above -- and names the source it picked *inside the record it
# returns*, so the comparison in measurement.sh can refuse a delta built
# across the two.
rt_docker_size() {
    local raw pair total reclaimable

    if raw=$(docker system df 2>/dev/null) && pair=$(docker_system_df_bytes "$raw"); then
        read -r total reclaimable <<< "$pair"
        probe_available "$total" "$reclaimable" "system-df"
        return 0
    fi

    if raw=$(docker buildx du 2>/dev/null) && pair=$(docker_buildx_du_bytes "$raw"); then
        read -r total reclaimable <<< "$pair"
        probe_available "$total" "$reclaimable" "buildx-du"
        return 0
    fi

    probe_unavailable
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

### bun (opt-in) ##############################################################

rt_bun_detect() {
    command -v bun >/dev/null 2>&1
}

rt_bun_cache_dir() {
    printf '%s\n' "${BUN_INSTALL:-$HOME/.bun}/install/cache"
}

### cargo (report-only) #######################################################

rt_cargo_detect() {
    command -v cargo >/dev/null 2>&1
}

rt_cargo_cache_dir() {
    printf '%s\n' "${CARGO_HOME:-$HOME/.cargo}/registry"
}
