# shellcheck shell=bash
# shellcheck disable=SC2034  # RT_* entries and help arrays are read by util/cache-prune.sh
# cache-prune/runtimes/trash.sh: the `trash` runtime -- the user's home trash (purge verb only, interactive-only).
# A core runtime module: sourced by ../../cache-prune.sh, in its fixed order,
# after the registry arrays are declared and before any fleet module. It
# registers itself (its RUNTIME_ORDER slot, its RT_* entries, its help text)
# and holds its own adapters and verbs. Same contract as ../fleet/*.sh.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

### registration ##############################################################

register_runtime trash
# shellcheck disable=SC2154  # RT_DETECT is the associative array declared in ../../cache-prune.sh
RT_DETECT[trash]=rt_trash_detect
RT_ABSENT[trash]=rt_trash_absent
RT_SIZE[trash]=rt_trash_size
RT_PURGE[trash]=rt_trash_purge
RT_DETAIL[trash]=rt_trash_detail
RT_INTERACTIVE_ONLY[trash]='skipped: trash needs an interactive confirm (user-deleted data; never emptied under --yes)'
RT_PURGE_PROMPT[trash]=rt_trash_purge_prompt

# shellcheck disable=SC2016  # literal help text, printed verbatim
CACHE_PRUNE_HELP_CORE_RUNTIMES+=('The trash runtime reports the user'\''s home trash (files/, info/ and
expunged/ under ${XDG_DATA_HOME:-$HOME/.local/share}/Trash); detected only
when gio is installed and that dir exists. Purge tier, interactive-only:
it is user-deleted data, not a rebuildable cache, so it is NEVER emptied
under --yes (not even with --include-purge) -- only by one interactive
confirm, via `gio trash --empty` (never a direct rm). gio also empties
per-mount .Trash-$UID dirs, which are not sized here.
')
# shellcheck disable=SC2016  # literal help text, printed verbatim
CACHE_PRUNE_HELP_CORE_ENV+=('  CACHE_PRUNE_TRASH_DIR
                overrides the trash dir the trash runtime sizes (default
                ${XDG_DATA_HOME:-$HOME/.local/share}/Trash)' '  CACHE_PRUNE_GIO
                overrides the gio command the trash runtime detects and
                runs (default gio)')

### trash #####################################################################
#
# The user's home trash (freedesktop layout: files/, info/, expunged/).
# User-deleted data, not a rebuildable cache -- see RT_INTERACTIVE_ONLY in
# ../cache-prune.sh. Only the home trash is sized; gio also empties per-mount
# .Trash-$UID dirs, which are acknowledged in the detail line, not modelled.

rt_trash_dir() {
    printf '%s\n' "${CACHE_PRUNE_TRASH_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/Trash}"
}

rt_trash_gio() {
    printf '%s\n' "${CACHE_PRUNE_GIO:-gio}"
}

rt_trash_detect() {
    command -v "$(rt_trash_gio)" >/dev/null 2>&1 && [[ -d "$(rt_trash_dir)" ]]
}

rt_trash_absent() {
    local gio

    gio=$(rt_trash_gio)
    if ! command -v "$gio" >/dev/null 2>&1; then
        printf 'no %s on host\n' "${gio##*/}"
    else
        printf 'trash dir %s absent\n' "$(rt_trash_dir)"
    fi
}

# rt_trash_bytes: files/ + info/ (+ expunged/ when present); absent subdirs
# count as zero.
rt_trash_bytes() {
    local dir sub bytes total=0

    dir=$(rt_trash_dir)
    for sub in files info expunged; do
        [[ -e "$dir/$sub" ]] || continue
        bytes=$(path_du_bytes "$dir/$sub")
        total=$((total + bytes))
    done
    printf '%d\n' "$total"
}

# rt_trash_size: the probe. Everything in the trash is purge-tier
# reclaimable, so reclaimable == total.
rt_trash_size() {
    local bytes

    if ! rt_trash_detect; then
        probe_unavailable
        return 0
    fi

    bytes=$(rt_trash_bytes)
    probe_available "$bytes" "$bytes" "trash"
}

# rt_trash_detail: the RT_DETAIL seam -- item count plus the per-mount note.
rt_trash_detail() {
    local dir count=0 entry

    dir=$(rt_trash_dir)
    for entry in "$dir/files"/* "$dir/files"/.[!.]* "$dir/files"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] && count=$((count + 1))
    done
    printf 'trash: %d items in files/ -- purge tier, interactive confirm only\n' "$count"
    printf 'note: gio trash --empty also empties per-mount .Trash-<uid> dirs, which are not sized here.\n'
}

# rt_trash_purge_prompt: the RT_PURGE_PROMPT seam -- names the size and that
# this is user-deleted data.
rt_trash_purge_prompt() {
    local bytes

    bytes=$(rt_trash_bytes)
    printf 'Empty trash (%s, %d bytes of user-deleted data, not a cache)? (destructive, via gio trash --empty)' \
        "$(human_bytes "$bytes")" "$bytes"
}

### verbs #####################################################################

# rt_trash_purge: delegates to `gio trash --empty` (never a direct rm); a
# non-zero exit is a verb failure through run_verb.
rt_trash_purge() {
    "$(rt_trash_gio)" trash --empty
}
