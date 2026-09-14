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

### repo (opt-in) #############################################################
#
# The repo runtime is the one entry in the registry that is not a package
# manager's cache. It measures *rebuildable repository residue* across the
# fleet root (CACHE_PRUNE_REPO_ROOT, default /home/_shared_code), in three
# buckets that are deliberately never summed into one reported figure:
#
#   (a) orphaned worktrees  <repo>/.claude/worktrees/<d> that `git worktree
#                           list` no longer knows about -- purge tier
#   (b) spike scratch       <repo>/runs/spike/* -- purge tier
#   (c) implemented         the dispatch records of IMPLEMENTED plans, as
#       dispatch records    reported by runs-closeout.mjs --report-json --
#                           counted toward total footprint only. They are
#                           archived, never deleted, and nothing here ever
#                           touches them: (c) exists so the footprint is
#                           honest, not so it can be reclaimed by this tool.
#
# Only (a)+(b) are reclaimable; the probe record's reclaimable field is their
# sum, and the total is (a)+(b)+(c). Bucket (c) can be unavailable on its own
# (no runs-closeout.mjs, or it failed) without making the whole measurement
# unavailable -- (a) and (b) were still measured. Only a missing fleet root
# yields an unavailable record.
#
# A repository is a *direct child directory of the root containing a `.git`*
# (file or directory), matching verify-core.discoverDefaultRoots. The
# enumeration is deliberately not recursive: a linked worktree or a nested
# repository is residue inside its parent repo, not a fleet repo of its own,
# and counting it as one would double-count its bytes and invite a purge
# candidate to be enumerated under two different repository roots.

CACHE_PRUNE_REPO_ROOT_DEFAULT=/home/_shared_code
# Composed from the root above rather than written out as one literal: the
# public-contract gate (tests/public-contract-smoke.sh) refuses a literal
# /home/<user>/<path> in any active file under util/, and composing it also
# keeps the two defaults from drifting apart. The default is not re-derived
# from CACHE_PRUNE_REPO_ROOT: overriding the fleet root (a test fixture
# does exactly that) must not silently re-point the closeout script too.
CACHE_PRUNE_RUNS_CLOSEOUT_DEFAULT="$CACHE_PRUNE_REPO_ROOT_DEFAULT/context-control/scripts/runs-closeout.mjs"

# The scan results. These are globals rather than a return value because the
# three consumers (size probe, detail seam, purge verb) each need a different
# slice of the same walk. They are *not* a cache shared between those
# consumers: rt_repo_size runs inside the command substitution in
# measure_runtime, so every assignment it makes dies with that subshell (the
# hazard measurement.sh's header documents at length). Each consumer
# therefore re-runs rt_repo_scan itself. For the purge verb that is a feature,
# not a cost -- the list it deletes from is re-derived immediately before the
# deletion, never inherited from an older walk.
REPO_ORPHAN_BYTES=0
REPO_SPIKE_BYTES=0
REPO_DISPATCH_BYTES=0
REPO_DISPATCH_STATUS=unavailable
REPO_ORPHAN_COUNT=0
# Tab-separated "<repo>\t<path>" lines: the purge guards need to know which
# repository to ask about a path, and a path alone cannot answer that once
# the enumeration is over.
REPO_ORPHAN_PATHS=""
REPO_SPIKE_PATHS=""

# The stdin-reading JSON sum for bucket (c). node is a hard dependency of
# runs-closeout.mjs itself, so a `node -e` parse adds no new requirement,
# while `jq` would (it is not installed everywhere on this fleet) -- hence no
# `command -v jq` branch: one parser, always the same one, no divergence
# between two implementations of the same sum. Only the three closed classes
# below are counted; `unclassified` rows are reported by the closeout script
# precisely because it does not know what they are, and counting bytes this
# tool cannot name would be exactly the conflation the bucket split exists to
# prevent.
REPO_DISPATCH_SUM_JS='
let raw = "";
process.stdin.on("data", (chunk) => { raw += chunk; });
process.stdin.on("end", () => {
  try {
    const doc = JSON.parse(raw);
    const counted = new Set(["archive-md", "archive-txt", "delete-only"]);
    let total = 0;
    for (const file of doc.files || []) {
      if (counted.has(file.class)) { total += Number(file.bytes) || 0; }
    }
    process.stdout.write(String(total) + "\n");
  } catch (err) {
    process.exit(1);
  }
});
'

rt_repo_root() {
    printf '%s\n' "${CACHE_PRUNE_REPO_ROOT:-$CACHE_PRUNE_REPO_ROOT_DEFAULT}"
}

rt_repo_detect() {
    local root

    root=$(rt_repo_root)
    [[ -d "$root" ]]
}

# rt_repo_roots: the fleet's repositories, one absolute path per line. Direct
# children only (see the header); a root with no repositories prints nothing
# and succeeds, which is not an error condition.
rt_repo_roots() {
    local root entry

    root=$(rt_repo_root)
    [[ -d "$root" ]] || return 0

    for entry in "$root"/*; do
        [[ -d "$entry" ]] || continue
        [[ -e "$entry/.git" ]] || continue
        printf '%s\n' "$entry"
    done
}

# repo_path_bytes: `du -sb` one path, or 0 for anything that cannot be
# measured. Unlike the language-runtime caches this does not use
# dir_census_bytes: there is no hardlink-sharing question here (a worktree or
# a scratch tree is not shared with a venv), and the plan pins du -sb as the
# figure these buckets report.
repo_path_bytes() {
    local path="$1"
    local bytes

    bytes=$(du -sb -- "$path" 2>/dev/null | awk 'NR == 1 { print $1 }') || bytes=""
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0

    printf '%s\n' "$bytes"
}

# rt_repo_live_worktrees: the realpaths git itself still lists for a
# repository -- the main worktree included. Resolved on both sides of the
# later comparison because git records the path it was given and the fleet
# root may be reached through a symlink.
rt_repo_live_worktrees() {
    local repo="$1"
    local listed line resolved

    listed=$(git -C "$repo" worktree list --porcelain 2>/dev/null |
        sed -n 's/^worktree //p') || return 0

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        resolved=$(realpath "$line" 2>/dev/null) || resolved="$line"
        printf '%s\n' "$resolved"
    done <<< "$listed"
}

# rt_repo_orphan_worktrees: bucket (a) candidates for one repository -- the
# directories under .claude/worktrees that git no longer lists. A live
# worktree is never a candidate, which is why the check is against git's own
# list rather than against, say, mtime.
rt_repo_orphan_worktrees() {
    local repo="$1"
    local wt_dir="$repo/.claude/worktrees"
    local live entry resolved

    [[ -d "$wt_dir" ]] || return 0
    live=$(rt_repo_live_worktrees "$repo")

    for entry in "$wt_dir"/*; do
        [[ -d "$entry" ]] || continue
        resolved=$(realpath "$entry" 2>/dev/null) || resolved="$entry"
        if ! printf '%s\n' "$live" | grep -qxF -- "$resolved"; then
            printf '%s\n' "$entry"
        fi
    done
}

# rt_repo_spike_entries: bucket (b) candidates -- the top-level entries of
# <repo>/runs/spike. Entries, not the directory itself: runs/spike is the
# durable container, its contents are the scratch.
rt_repo_spike_entries() {
    local repo="$1"
    local spike_dir="$repo/runs/spike"
    local entry

    [[ -d "$spike_dir" ]] || return 0

    for entry in "$spike_dir"/*; do
        [[ -e "$entry" ]] || continue
        printf '%s\n' "$entry"
    done
}

# rt_repo_dispatch_dirs: every runs/dispatch directory in a repository. This
# one *is* recursive -- a repo holds one per tool subfolder -- but skips
# node_modules and every dot-directory, so a dispatch dir inside a linked
# worktree under .claude/ is not visited twice.
rt_repo_dispatch_dirs() {
    local repo="$1"

    find "$repo" \
        -path '*/node_modules' -prune -o \
        -path '*/.*' -prune -o \
        -type d -path '*/runs/dispatch' -print 2>/dev/null || true
}

# repo_dispatch_bytes: bucket (c) for one dispatch directory, via
# runs-closeout.mjs --report-json (read-only). Exits nonzero -- never prints
# a partial number -- when the script is absent, node is absent, the script
# fails, or its output does not parse: the caller turns any of those into
# "unavailable" for the whole bucket rather than reporting an undercount as
# if it were a measurement.
repo_dispatch_bytes() {
    local dir="$1"
    local script json

    script="${CACHE_PRUNE_RUNS_CLOSEOUT:-$CACHE_PRUNE_RUNS_CLOSEOUT_DEFAULT}"

    [[ -f "$script" ]] || return 1
    command -v node >/dev/null 2>&1 || return 1

    json=$(node "$script" --report-json --dispatch-dir "$dir" 2>/dev/null) || return 1
    printf '%s' "$json" | node -e "$REPO_DISPATCH_SUM_JS"
}

# rt_repo_scan: the one walk, filling the globals above. Prints nothing.
rt_repo_scan() {
    local repo entry dispatch_dir bytes

    REPO_ORPHAN_BYTES=0
    REPO_SPIKE_BYTES=0
    REPO_DISPATCH_BYTES=0
    REPO_ORPHAN_COUNT=0
    REPO_ORPHAN_PATHS=""
    REPO_SPIKE_PATHS=""
    REPO_DISPATCH_STATUS=available

    # Process substitution, not a pipe: a `... | while read` loop runs in a
    # subshell and every global it sets here would be lost, the same trap the
    # size probe itself falls into (see the globals' comment above).
    while IFS= read -r repo; do
        [[ -n "$repo" ]] || continue

        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            REPO_ORPHAN_PATHS+="$repo"$'\t'"$entry"$'\n'
            REPO_ORPHAN_COUNT=$((REPO_ORPHAN_COUNT + 1))
            bytes=$(repo_path_bytes "$entry")
            REPO_ORPHAN_BYTES=$((REPO_ORPHAN_BYTES + bytes))
        done < <(rt_repo_orphan_worktrees "$repo")

        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            REPO_SPIKE_PATHS+="$repo"$'\t'"$entry"$'\n'
            bytes=$(repo_path_bytes "$entry")
            REPO_SPIKE_BYTES=$((REPO_SPIKE_BYTES + bytes))
        done < <(rt_repo_spike_entries "$repo")

        while IFS= read -r dispatch_dir; do
            [[ -n "$dispatch_dir" ]] || continue
            if bytes=$(repo_dispatch_bytes "$dispatch_dir") &&
                [[ "$bytes" =~ ^[0-9]+$ ]]; then
                REPO_DISPATCH_BYTES=$((REPO_DISPATCH_BYTES + bytes))
            else
                REPO_DISPATCH_STATUS=unavailable
            fi
        done < <(rt_repo_dispatch_dirs "$repo")
    done < <(rt_repo_roots)
}

# rt_repo_size: the probe. Ignores its positional argument (repo has no
# cache-dir resolver -- its residue is many directories in many
# repositories), returns exactly one record, prints nothing else. The
# per-bucket breakdown a reader needs is printed by rt_repo_detail, from the
# report layer, because an adapter that printed it here would be a probe with
# a side effect on the report -- the seam this file's header forbids.
rt_repo_size() {
    local root reclaimable total

    root=$(rt_repo_root)
    if [[ ! -d "$root" ]]; then
        probe_unavailable
        return 0
    fi

    rt_repo_scan

    reclaimable=$((REPO_ORPHAN_BYTES + REPO_SPIKE_BYTES))
    total="$reclaimable"
    if [[ "$REPO_DISPATCH_STATUS" == available ]]; then
        total=$((total + REPO_DISPATCH_BYTES))
    fi

    probe_available "$total" "$reclaimable" "repo"
}

# rt_repo_detail: the RT_DETAIL seam -- the three bucket lines, printed by
# the report layer right under repo's size line. Not a probe: it prints
# user-facing text and returns nothing on stdout that any caller parses.
# Bucket (c) names the verb that actually reclaims it (runs-closeout.mjs),
# and says outright that this tool never deletes it, so that the one figure
# in the total that no --include-purge can reach is not mistaken for one that
# can.
rt_repo_detail() {
    rt_repo_scan

    printf 'repo orphaned worktrees: %s (%d bytes, %d dirs) -- purge tier\n' \
        "$(human_bytes "$REPO_ORPHAN_BYTES")" "$REPO_ORPHAN_BYTES" "$REPO_ORPHAN_COUNT"
    printf 'repo spike scratch: %s (%d bytes) -- purge tier\n' \
        "$(human_bytes "$REPO_SPIKE_BYTES")" "$REPO_SPIKE_BYTES"

    if [[ "$REPO_DISPATCH_STATUS" == available ]]; then
        printf 'repo implemented dispatch records: %s (%d bytes) -- archive with runs-closeout.mjs --slug <s> --dispatch-dir <d> --apply; never deleted here\n' \
            "$(human_bytes "$REPO_DISPATCH_BYTES")" "$REPO_DISPATCH_BYTES"
    else
        printf 'repo implemented dispatch records: unavailable (runs-closeout.mjs missing or failed)\n'
    fi
}
