# shellcheck shell=bash
# shellcheck disable=SC2034  # RT_* entries and help arrays are read by util/cache-prune.sh
# cache-prune/runtimes/docker.sh: the `docker` runtime -- docker's build cache (safe verb only), plus its image/container residue.
# A core runtime module: sourced by ../../cache-prune.sh, in its fixed order,
# after the registry arrays are declared and before any fleet module. It
# registers itself (its RUNTIME_ORDER slot, its RT_* entries, its help text)
# and holds its own adapters and verbs. Same contract as ../fleet/*.sh.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

### registration ##############################################################

register_runtime docker
# shellcheck disable=SC2154  # RT_DETECT is the associative array declared in ../../cache-prune.sh
RT_DETECT[docker]=rt_docker_detect
RT_ABSENT[docker]=rt_docker_absent
# No RT_CACHE_DIR entry: docker's cache is daemon-owned, not a directory this
# account can resolve or `du`.
RT_SIZE[docker]=rt_docker_size
RT_PRUNE[docker]=rt_docker_prune
# No RT_PURGE entry: docker has no destructive verb at all (its safe prune is
# the only action).
# rt_docker_detail and rt_docker_residue live in ../docker-residue.sh.
RT_DETAIL[docker]=rt_docker_detail
RT_RESIDUE[docker]=rt_docker_residue
RT_SAFE_ESTIMATE_NOTE[docker]='note: docker reclaimable is an upper bound (not pinned by an active build), not a guarantee of what a prune will free.'

### docker ####################################################################

# Detection folds in the daemon preflight: a present CLI with a dead daemon
# (or no permission to talk to it) must be a graceful skip, not an error, so
# `docker info` succeeding is part of the detect predicate itself.
rt_docker_detect() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# rt_docker_absent: one reason per cause -- a missing CLI is `no docker on
# host`; a present CLI with a dead daemon (or no permission) is its own line.
rt_docker_absent() {
    if ! command -v docker >/dev/null 2>&1; then
        printf 'no docker on host\n'
    else
        printf 'docker daemon not reachable\n'
    fi
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
# during the reclaim-effectiveness work), system df's Build Cache
# RECLAIMABLE predicted the freed bytes exactly, while buildx du's
# Reclaimable overstated by the Shared slice it additionally counts. The
# two sources still measure different things and *will* disagree on the
# same machine: buildx's Reclaimable counts records shared with other build
# state, system df's excludes them. Both are legitimate upper bounds over
# what a real prune returns (measured during the cache-reporting fidelity work); this
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

### verbs #####################################################################

# Empty by default: the safe prune runs unfiltered. --docker-until (parsed
# and validated by set_docker_until) opts into an age window.
DOCKER_UNTIL=""

# Never `docker image prune`, never `docker system prune` -- only the
# build-cache prune. Unfiltered by default: the `until=168h` age filter
# this used to carry blocked most of what docker itself calls reclaimable,
# because the build-cache DAG retains an old parent record whenever it has
# a recent child, regardless of the parent's own age. Measured live
# during the reclaim-effectiveness work: an unfiltered
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
