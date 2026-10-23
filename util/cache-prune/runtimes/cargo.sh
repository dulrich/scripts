# shellcheck shell=bash
# shellcheck disable=SC2034  # RT_* entries and help arrays are read by util/cache-prune.sh
# cache-prune/runtimes/cargo.sh: the `cargo` runtime -- cargo's unpacked registry sources (registry/src purge only).
# A core runtime module: sourced by ../../cache-prune.sh, in its fixed order,
# after the registry arrays are declared and before any fleet module. It
# registers itself (its RUNTIME_ORDER slot, its RT_* entries, its help text)
# and holds its own adapters and verbs. Same contract as ../fleet/*.sh.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

### registration ##############################################################

register_runtime cargo
# shellcheck disable=SC2154  # RT_DETECT is the associative array declared in ../../cache-prune.sh
RT_DETECT[cargo]=rt_cargo_detect
RT_ABSENT[cargo]=rt_cargo_absent
RT_CACHE_DIR[cargo]=rt_cargo_cache_dir
RT_SIZE[cargo]=rt_cargo_size
# No RT_PRUNE entry, by decision: cargo's only verb is the purge of
# registry/src (re-extraction from registry/cache is offline and cheap, so
# cache/, index/ and git/ are kept); cargo's own GC of registry files is left
# alone. Cargo build output (target/ dirs) is not this cache at all.
RT_PURGE[cargo]=rt_cargo_purge

CACHE_PRUNE_HELP_CORE_ENV_LEAD+=('  CARGO_HOME    overrides cargo'\''s home (the purge verb removes only the
                children of registry/src, the unpacked crate sources;
                registry/cache, registry/index and git/ are kept, and
                cargo re-extracts src from registry/cache offline)')

### cargo (opt-in, registry/src purge only) ###################################

rt_cargo_detect() {
    command -v cargo >/dev/null 2>&1
}

rt_cargo_absent() {
    printf 'no cargo on host\n'
}

rt_cargo_cache_dir() {
    printf '%s\n' "${CARGO_HOME:-$HOME/.cargo}/registry"
}

# rt_cargo_size: total is the whole registry/ dir (cache/, index/, src/);
# reclaimable is registry/src alone -- the only part the purge verb removes.
rt_cargo_size() {
    local pair total reclaimable src_pair

    pair=$(dir_census_bytes "$1")
    read -r total _ <<< "$pair"
    src_pair=$(dir_census_bytes "$1/src")
    read -r reclaimable _ <<< "$src_pair"

    if [[ ! "$total" =~ ^[0-9]+$ || ! "$reclaimable" =~ ^[0-9]+$ ]]; then
        probe_unavailable
        return 0
    fi

    probe_available "$total" "$reclaimable" "census"
}

### verbs #####################################################################

# rt_cargo_purge: removes only the children of $CARGO_HOME/registry/src (the
# unpacked crate sources). Cargo re-extracts them from registry/cache offline
# and cheaply, so cache/, index/ and git/ are never touched. This verb deletes
# files directly, so it is guarded: no symlinked registry/src component, and
# both cargo package-cache locks must be free (cargo takes them while it
# reads or extracts the registry). Every guarded skip warns and returns 0 --
# a skip is not a verb failure. Lock files are opened read-write (which
# creates them when absent) and are never removed.
rt_cargo_purge() {
    local home src real_home lock fd status
    local -a fds=()

    home="${CARGO_HOME:-$HOME/.cargo}"
    src="$home/registry/src"
    [[ -e "$src" || -L "$src" ]] || return 0

    real_home=$(realpath -e -- "$home" 2>/dev/null) || real_home=""
    if [[ -z "$real_home" || -L "$home/registry" || -L "$src" ||
        "$(realpath -e -- "$src" 2>/dev/null)" != "$real_home/registry/src" ]]; then
        warn "cargo: skipped $src (guard: symlinked or escapes CARGO_HOME)"
        return 0
    fi

    for lock in "$home/.package-cache" "$home/.package-cache-mutate"; do
        if ! { exec {fd}<>"$lock"; } 2>/dev/null; then
            for fd in "${fds[@]}"; do exec {fd}>&-; done
            warn "cargo: skipped $src (guard: a cargo package-cache lock is held)"
            return 0
        fi
        fds+=("$fd")
        if ! flock -n "$fd"; then
            for fd in "${fds[@]}"; do exec {fd}>&-; done
            warn "cargo: skipped $src (guard: a cargo package-cache lock is held)"
            return 0
        fi
    done

    status=0
    local child rc
    while IFS= read -r -d '' child; do
        rc=0
        guarded_remove "$real_home/registry/src" "$child" || rc=$?
        if ((rc != 0)); then
            status=1
            ((rc != 3)) || warn "cargo: failed to remove $child"
        fi
    done < <(find -P "$src" -mindepth 1 -maxdepth 1 -print0)

    for fd in "${fds[@]}"; do exec {fd}>&-; done
    return "$status"
}
