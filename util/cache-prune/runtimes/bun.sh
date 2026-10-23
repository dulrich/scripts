# shellcheck shell=bash
# shellcheck disable=SC2034  # RT_* entries and help arrays are read by util/cache-prune.sh
# cache-prune/runtimes/bun.sh: the `bun` runtime -- bun's install cache (purge verb only).
# A core runtime module: sourced by ../../cache-prune.sh, in its fixed order,
# after the registry arrays are declared and before any fleet module. It
# registers itself (its RUNTIME_ORDER slot, its RT_* entries, its help text)
# and holds its own adapters and verbs. Same contract as ../fleet/*.sh.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

### registration ##############################################################

register_runtime bun
# shellcheck disable=SC2154  # RT_DETECT is the associative array declared in ../../cache-prune.sh
RT_DETECT[bun]=rt_bun_detect
RT_ABSENT[bun]=rt_bun_absent
RT_CACHE_DIR[bun]=rt_bun_cache_dir
RT_SIZE[bun]=rt_generic_size
RT_PURGE[bun]=rt_bun_purge

CACHE_PRUNE_HELP_CORE_ENV_LEAD+=('  BUN_INSTALL   overrides bun'\''s install prefix (cache under install/cache)')

### bun (opt-in) ##############################################################

rt_bun_detect() {
    command -v bun >/dev/null 2>&1
}

rt_bun_absent() {
    printf 'no bun on host\n'
}

rt_bun_cache_dir() {
    printf '%s\n' "${BUN_INSTALL:-$HOME/.bun}/install/cache"
}

### verbs #####################################################################

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
