# shellcheck shell=bash
# shellcheck disable=SC2034  # RT_* entries and help arrays are read by util/cache-prune.sh
# cache-prune/runtimes/codex.sh: the `codex` runtime -- leaked Codex CLI marketplace staging copies (purge verb only).
# A core runtime module: sourced by ../../cache-prune.sh, in its fixed order,
# after the registry arrays are declared and before any fleet module. It
# registers itself (its RUNTIME_ORDER slot, its RT_* entries, its help text)
# and holds its own adapters and verbs. Same contract as ../fleet/*.sh.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

### registration ##############################################################

register_runtime codex
# shellcheck disable=SC2154  # RT_DETECT is the associative array declared in ../../cache-prune.sh
RT_DETECT[codex]=rt_codex_detect
RT_SIZE[codex]=rt_codex_size
# A verb that deletes files directly: every path passes codex_purge_path.
RT_PURGE[codex]=rt_codex_purge
RT_DETAIL[codex]=rt_codex_detail

# shellcheck disable=SC2016  # literal help text, printed verbatim
CACHE_PRUNE_HELP_CORE_RUNTIMES+=('The codex runtime reports leaked Codex CLI marketplace staging copies:
<home>/.tmp/marketplaces/.staging/marketplace-upgrade-* (direct children
only) for every home $HOME/.codex and $HOME/.codex-* (root overridable via
CACHE_PRUNE_CODEX_HOME_ROOT). All entries count toward total; only those
older than 24 h are reclaimable. Purge tier (optin): removed only by
--yes --include-purge, or one confirm interactively. Its purge refuses a
symlinked entry, a symlinked home/.tmp/marketplaces/.staging component, and
any entry whose realpath is not inside .staging. Nothing else under a Codex
home is touched.
')
# shellcheck disable=SC2016  # literal help text, printed verbatim
CACHE_PRUNE_HELP_CORE_ENV+=('  CACHE_PRUNE_CODEX_HOME_ROOT
                overrides the directory whose .codex and .codex-* children
                the codex runtime scans (default $HOME)')

### codex ######################################################################
#
# The codex runtime: leaked Codex CLI marketplace staging copies. Codex
# 0.162.x leaves a full marketplace copy (~46 MB) at
# <home>/.tmp/marketplaces/.staging/marketplace-upgrade-<rand>/ on every
# marketplace upgrade and never removes it. Homes are $ROOT/.codex and
# $ROOT/.codex-* (direct children of the root, directories only), where ROOT
# is CACHE_PRUNE_CODEX_HOME_ROOT (default $HOME -- the override exists so the
# test harness can point every suite at a sandbox; see
# util/tests/cache-prune.sh). Candidates are direct children named
# marketplace-upgrade-* of each .staging dir; only those whose mtime is older
# than CODEX_STAGING_MIN_AGE_SECONDS (24 h) are reclaimable -- a copy in use
# by an in-flight upgrade is minutes old. Nothing else under a Codex home is
# ever enumerated (the .staging siblings context-mode/ and
# marketplace-backup-* are live).

CODEX_STAGING_MIN_AGE_SECONDS=86400

# Scan globals. The size probe runs in the current shell (measure_runtime),
# so rt_codex_detail reads the probe's scan as-is; rt_codex_purge re-scans
# immediately before deleting.
CODEX_TOTAL_BYTES=0
CODEX_RECLAIM_BYTES=0
# One "<home>\t<count>\t<bytes>\t<young>" line per home with a .staging dir.
CODEX_HOME_LINES=""
# One "<home>\t<path>" line per reclaimable candidate.
CODEX_OLD_PATHS=""

rt_codex_root() {
    printf '%s\n' "${CACHE_PRUNE_CODEX_HOME_ROOT:-$HOME}"
}

# rt_codex_homes: Codex homes that carry a staging dir, one per line.
rt_codex_homes() {
    local root home

    root=$(rt_codex_root)
    for home in "$root/.codex" "$root"/.codex-*; do
        [[ -d "$home" ]] || continue
        [[ -d "$home/.tmp/marketplaces/.staging" ]] || continue
        printf '%s\n' "$home"
    done
}

rt_codex_detect() {
    [[ -n "$(rt_codex_homes)" ]]
}

# codex_entry_is_old: mtime of the entry itself (not followed) older than the
# floor.
codex_entry_is_old() {
    local path="$1"
    local mtime now

    mtime=$(stat -c %Y -- "$path" 2>/dev/null) || return 1
    [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
    now=$(date +%s)
    ((now - mtime > CODEX_STAGING_MIN_AGE_SECONDS))
}

rt_codex_scan() {
    local home entry bytes count home_bytes young component linked_ancestor

    CODEX_TOTAL_BYTES=0
    CODEX_RECLAIM_BYTES=0
    CODEX_HOME_LINES=""
    CODEX_OLD_PATHS=""

    while IFS= read -r home; do
        [[ -n "$home" ]] || continue
        count=0
        home_bytes=0
        young=0
        # Mirror codex_purge_path's ancestor guard: under a symlinked
        # home/.tmp/marketplaces/.staging nothing is reclaimable, because the
        # purge refuses it -- the estimate must match what the verb frees.
        linked_ancestor=false
        for component in "$home" "$home/.tmp" "$home/.tmp/marketplaces" \
            "$home/.tmp/marketplaces/.staging"; do
            [[ -L "$component" ]] && linked_ancestor=true
        done
        for entry in "$home/.tmp/marketplaces/.staging"/marketplace-upgrade-*; do
            [[ -e "$entry" || -L "$entry" ]] || continue
            bytes=$(path_du_bytes "$entry")
            count=$((count + 1))
            home_bytes=$((home_bytes + bytes))
            # A symlinked candidate, or one under a symlinked ancestor, is
            # counted toward total but is never reclaimable: the purge guard
            # refuses it.
            if [[ "$linked_ancestor" == false && ! -L "$entry" ]] && codex_entry_is_old "$entry"; then
                CODEX_RECLAIM_BYTES=$((CODEX_RECLAIM_BYTES + bytes))
                CODEX_OLD_PATHS+="$home"$'\t'"$entry"$'\n'
            else
                young=$((young + 1))
            fi
        done
        CODEX_TOTAL_BYTES=$((CODEX_TOTAL_BYTES + home_bytes))
        CODEX_HOME_LINES+="$home"$'\t'"$count"$'\t'"$home_bytes"$'\t'"$young"$'\n'
    done < <(rt_codex_homes)
}

# rt_codex_size: the probe. Unavailable when no home has a .staging dir; an
# empty .staging is an available 0/0 measurement.
rt_codex_size() {
    if ! rt_codex_detect; then
        probe_unavailable
        return 0
    fi

    rt_codex_scan
    probe_available "$CODEX_TOTAL_BYTES" "$CODEX_RECLAIM_BYTES" "codex"
}

# rt_codex_detail: the RT_DETAIL seam -- one line per Codex home.
rt_codex_detail() {
    local home count bytes young

    while IFS=$'\t' read -r home count bytes young; do
        [[ -n "$home" ]] || continue
        printf 'codex %s staging: %d entries, %s (%d bytes); %d not reclaimable (under 24h old or a symlink) -- purge tier\n' \
            "${home##*/}" "$count" "$(human_bytes "$bytes")" "$bytes" "$young"
    done <<< "$CODEX_HOME_LINES"
}

### verbs #####################################################################

# rt_codex_purge: re-scans immediately before deleting (the list it deletes
# from is never inherited from an older walk) and hands each reclaimable
# candidate to codex_purge_path.
rt_codex_purge() {
    local home path

    rt_codex_scan

    while IFS=$'\t' read -r home path; do
        [[ -n "$path" ]] || continue
        codex_purge_path "$home" "$path"
    done <<< "$CODEX_OLD_PATHS"

    return 0
}

# codex_purge_path: the guards, then the deletion. This
# refuses symlinks outright: a symlinked candidate, a symlinked
# home/.tmp/marketplaces/.staging component, or a candidate whose realpath is
# not strictly inside the realpath of .staging is skipped with a note.
codex_purge_path() {
    local home="$1"
    local path="$2"
    local staging="$home/.tmp/marketplaces/.staging"
    local component staging_real path_real

    if [[ -L "$path" ]]; then
        printf 'note: skipped %s (guard: candidate is a symlink)\n' "$path"
        return 0
    fi

    for component in "$home" "$home/.tmp" "$home/.tmp/marketplaces" "$staging"; do
        if [[ -L "$component" ]]; then
            printf 'note: skipped %s (guard: %s is a symlink)\n' "$path" "$component"
            return 0
        fi
    done

    staging_real=$(realpath "$staging" 2>/dev/null) || staging_real=""
    path_real=$(realpath "$path" 2>/dev/null) || path_real=""

    if [[ -z "$staging_real" || -z "$path_real" ]]; then
        printf 'note: skipped %s (guard: path could not be resolved)\n' "$path"
        return 0
    fi

    if [[ "$path_real" != "$staging_real"/* ]]; then
        printf 'note: skipped %s (guard: realpath %s is outside %s)\n' \
            "$path" "$path_real" "$staging_real"
        return 0
    fi

    guarded_remove "$staging_real" "$path_real" ||
        printf 'note: skipped %s (guard: rm failed or path vanished)\n' "$path"
    return 0
}
