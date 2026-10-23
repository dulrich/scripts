# shellcheck shell=bash
# shellcheck disable=SC2034  # RT_* entries and help arrays are read by util/cache-prune.sh
# cache-prune/runtimes/pip.sh: the `pip` runtime -- pip's http/wheel cache (purge verb only).
# A core runtime module: sourced by ../../cache-prune.sh, in its fixed order,
# after the registry arrays are declared and before any fleet module. It
# registers itself (its RUNTIME_ORDER slot, its RT_* entries, its help text)
# and holds its own adapters and verbs. Same contract as ../fleet/*.sh.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

### registration ##############################################################

register_runtime pip
# shellcheck disable=SC2154  # RT_DETECT is the associative array declared in ../../cache-prune.sh
RT_DETECT[pip]=rt_pip_detect
RT_ABSENT[pip]=rt_pip_absent
RT_CACHE_DIR[pip]=rt_pip_cache_dir
RT_SIZE[pip]=rt_generic_size
RT_PURGE[pip]=rt_pip_purge

### pip (opt-in) ##############################################################

rt_pip_detect() {
    command -v pip >/dev/null 2>&1
}

rt_pip_absent() {
    printf 'no pip on host\n'
}

rt_pip_cache_dir() {
    local dir

    dir=$(pip cache dir) || return 1
    [[ "$dir" == /* ]] || return 2
    printf '%s\n' "$dir"
}

### verbs #####################################################################

rt_pip_purge() {
    pip cache purge
}
