# shellcheck shell=bash
# shellcheck disable=SC2034  # RT_* entries and help arrays are read by util/cache-prune.sh
# cache-prune/runtimes/uv.sh: the `uv` runtime -- uv's package cache (safe verb uv cache prune, purge verb uv cache clean).
# A core runtime module: sourced by ../../cache-prune.sh, in its fixed order,
# after the registry arrays are declared and before any fleet module. It
# registers itself (its RUNTIME_ORDER slot, its RT_* entries, its help text)
# and holds its own adapters and verbs. Same contract as ../fleet/*.sh.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

### registration ##############################################################

register_runtime uv
# shellcheck disable=SC2154  # RT_DETECT is the associative array declared in ../../cache-prune.sh
RT_DETECT[uv]=rt_uv_detect
RT_ABSENT[uv]=rt_uv_absent
RT_CACHE_DIR[uv]=rt_uv_cache_dir
RT_SIZE[uv]=rt_generic_size
RT_PRUNE[uv]=rt_uv_prune
RT_PURGE[uv]=rt_uv_purge

### uv ########################################################################

rt_uv_detect() {
    command -v uv >/dev/null 2>&1
}

rt_uv_absent() {
    printf 'no uv on host\n'
}

rt_uv_cache_dir() {
    local dir

    dir=$(uv cache dir) || return 1
    [[ "$dir" == /* ]] || return 2
    printf '%s\n' "$dir"
}

### verbs #####################################################################

rt_uv_prune() {
    uv cache prune
}

# rt_uv_purge / rt_npm_purge: the destructive purge verbs (RT_PURGE). Each
# clears the whole cache and forces a re-download on next use -- see the
# near-no-op behaviour of their safe counterparts above (measured) for why
# this is the verb that actually reaches the reported reclaimable bytes.
rt_uv_purge() {
    uv cache clean
}
