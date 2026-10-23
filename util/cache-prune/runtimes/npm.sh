# shellcheck shell=bash
# shellcheck disable=SC2034  # RT_* entries and help arrays are read by util/cache-prune.sh
# cache-prune/runtimes/npm.sh: the `npm` runtime -- npm's package cache (safe verb npm cache verify, purge verb npm cache clean --force).
# A core runtime module: sourced by ../../cache-prune.sh, in its fixed order,
# after the registry arrays are declared and before any fleet module. It
# registers itself (its RUNTIME_ORDER slot, its RT_* entries, its help text)
# and holds its own adapters and verbs. Same contract as ../fleet/*.sh.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

### registration ##############################################################

register_runtime npm
# shellcheck disable=SC2154  # RT_DETECT is the associative array declared in ../../cache-prune.sh
RT_DETECT[npm]=rt_npm_detect
RT_ABSENT[npm]=rt_npm_absent
RT_CACHE_DIR[npm]=rt_npm_cache_dir
RT_SIZE[npm]=rt_generic_size
RT_PRUNE[npm]=rt_npm_prune
RT_PURGE[npm]=rt_npm_purge

### npm #######################################################################

rt_npm_detect() {
    command -v npm >/dev/null 2>&1
}

rt_npm_absent() {
    printf 'no npm on host\n'
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

### verbs #####################################################################

rt_npm_prune() {
    npm cache verify
}

# rt_uv_purge / rt_npm_purge: the destructive purge verbs (RT_PURGE). Each
# clears the whole cache and forces a re-download on next use -- see the
# near-no-op behaviour of their safe counterparts above (premise (c),
# measured during the reclaim-effectiveness work) for why this is the verb that
# actually reaches the reported reclaimable bytes.
rt_npm_purge() {
    npm cache clean --force
}
