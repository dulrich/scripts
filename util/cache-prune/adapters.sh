# shellcheck shell=bash

# adapters.sh: the size probes shared by cache-prune runtimes (directory
# census, path du). Per-runtime detection, cache-location resolution and size
# probes live in runtimes/<name>.sh. Sourced by ../cache-prune.sh; not a util
# subcommand.
#
# Every rt_*_size adapter here and in runtimes/ returns exactly one probe record (see
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
# real trees during the cache-reporting fidelity work, not just more accurate);
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

### path sizing ##############################################################
#
# path_du_bytes: `du -sb` one path, or 0 for anything that cannot be
# measured. Unlike the language-runtime caches this does not use
# dir_census_bytes: the residue runtimes that call it (codex, trash, and any
# fleet module) size trees with no hardlink-sharing question, and du -sb is
# the figure they report.
path_du_bytes() {
    local path="$1"
    local bytes

    bytes=$(du -sb -- "$path" 2>/dev/null | awk 'NR == 1 { print $1 }') || bytes=""
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0

    printf '%s\n' "$bytes"
}

