# shellcheck shell=bash

# docker-residue.sh: read-only classifier for docker image / container /
# volume residue, reported under the docker runtime through the RT_DETAIL
# seam, plus the residue removal step (RT_RESIDUE seam, WP-2). Sourced by
# ../cache-prune.sh; not a util subcommand. Everything above the "removal"
# section is read-only (images/image inspect/ps/container inspect/system df/
# compose config); the only mutating calls in this file are the per-item
# `docker rm <name>` and `docker rmi <ref|id>` in docker_residue_remove --
# never -f, never any prune, never a volume
# (plans/cache-prune-docker-image-residue.md).
#
# Three layers, so the classifier stays a pure function of captured JSON:
#
#   docker_residue_dockerfile_bases <dockerfile> [<build-args-json>]
#       FROM refs of one Dockerfile, ARG defaults substituted (compose build
#       args override them), earlier `AS` stage names and `scratch` skipped.
#       Exit 1 if unreadable or a ref is left with an unresolved variable.
#   docker_residue_capture
#       Probes the daemon + compose files, prints ONE JSON document:
#         { images:     [{id, tags:[ref], created, size}],
#           containers: [{name, id, image_id, image_ref, state, created,
#                         project, service, size_rw}],   size_rw: bytes|null
#           compose:    [{project, services:[{name, image, build}]}],
#           base_refs:  [ref],
#           volumes:    [{name, size, links}],           size: bytes
#           image_error: null|"reason",  volume_error: null|"reason" }
#       Fail closed: any compose/Dockerfile/inspect failure sets image_error,
#       which the classifier turns into "unavailable" with no candidates.
#   docker_residue_classify  (stdin: the capture JSON)
#       THE STABLE OUTPUT SHAPE (consumed by WP-2's election), one TSV line
#       per row, first field the class:
#         superseded<TAB>ref<TAB>image_id<TAB>bytes<TAB>created<TAB>blockers
#         unreferenced<TAB>ref<TAB>image_id<TAB>bytes<TAB>created<TAB>blockers
#         stale<TAB>name<TAB>image_id<TAB>rw_bytes|unavailable<TAB>created<TAB>state<TAB>image_ref
#         volume<TAB>name<TAB>bytes<TAB>links<TAB>dangling|linked
#         unavailable<TAB>images|volumes<TAB>reason
#       blockers = comma-joined stale container names holding that image ID,
#       or "-". created = ISO-8601 as docker reports it. When images are
#       unavailable, no superseded/unreferenced/stale row is ever emitted.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

### Dockerfile base refs #######################################################

docker_residue_dockerfile_bases() {
    local dockerfile="$1"
    local args_json="${2:-null}"
    local line keyword rest name value ref stage
    local -A vars=()
    local -a stages=()

    [[ -r "$dockerfile" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        keyword="${line%%[[:space:]]*}"
        rest="${line#"$keyword"}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        case "${keyword^^}" in
            ARG)
                name="${rest%%=*}"
                name="${name%%[[:space:]]*}"
                [[ -n "$name" ]] || continue
                if [[ "$rest" == *=* ]]; then
                    value="${rest#*=}"
                    value="${value%%[[:space:]]*}"
                    value="${value#\"}"; value="${value%\"}"
                    # An ARG re-declared without a default inside a stage
                    # keeps the global value; only a default sets it.
                    # shellcheck disable=SC2034  # read via nameref in subst_args
                    vars[$name]="$value"
                fi
                ;;
            FROM)
                # Drop flags such as --platform=...
                while [[ "$rest" == --* ]]; do
                    rest="${rest#*[[:space:]]}"
                    rest="${rest#"${rest%%[![:space:]]*}"}"
                done
                ref="${rest%%[[:space:]]*}"
                stage=""
                if [[ "$rest" =~ [[:space:]][Aa][Ss][[:space:]]+([^[:space:]]+) ]]; then
                    stage="${BASH_REMATCH[1]}"
                fi
                ref=$(docker_residue_subst_args "$ref" "$args_json" vars) || return 1
                if [[ "$ref" != scratch ]] && ! docker_residue_in_list "$ref" "${stages[@]}"; then
                    printf '%s\n' "$ref"
                fi
                if [[ -n "$stage" ]]; then
                    stages+=("$stage")
                fi
                ;;
        esac
    done < "$dockerfile"
    return 0
}

docker_residue_in_list() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# docker_residue_subst_args: expand ${X}, ${X:-d} and $X in one FROM ref.
# Compose build args win over the Dockerfile's ARG default. Exit 1 if any
# variable is left unresolved -- an unknown base never becomes a guess.
docker_residue_subst_args() {
    local ref="$1" args_json="$2"
    local -n defaults="$3"
    local var fallback value

    while [[ "$ref" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*) ]]; do
        var="${BASH_REMATCH[1]:-${BASH_REMATCH[4]}}"
        fallback="${BASH_REMATCH[3]}"
        value=$(jq -r --arg k "$var" 'if type == "object" and (.[$k] | type) == "string" then .[$k] else empty end' <<< "$args_json" 2>/dev/null)
        if [[ -z "$value" ]]; then
            value="${defaults[$var]:-$fallback}"
        fi
        [[ -n "$value" ]] || return 1
        ref="${ref/"${BASH_REMATCH[0]}"/$value}"
    done
    printf '%s\n' "$ref"
}

### capture ####################################################################

docker_residue_repo_root() {
    printf '%s\n' "${CACHE_PRUNE_REPO_ROOT:-/home/_shared_code}"
}

# docker_residue_human_bytes_jq: jq def turning docker's decimal human sizes
# ("43.35MB", "24.6kB (virtual 300MB)", "0B") into integer bytes.
# shellcheck disable=SC2016  # jq program, not shell expansion
DOCKER_RESIDUE_JQ_BYTES='def hbytes: (tostring | split(" ")[0] | capture("^(?<n>[0-9.]+)(?<u>[A-Za-z]*)$")?) as $m
  | if $m == null then null
    else ($m.n | tonumber) * ({"": 1, "B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12}[$m.u] // 1) | floor
    end;'

docker_residue_capture() {
    local image_error="" volume_error=""
    local images='[]' containers='[]' compose='[]' bases='[]' volumes='[]'
    local ids out sizes file cfg dockerfile refs root

    if ! command -v jq >/dev/null 2>&1; then
        printf '{"images":[],"containers":[],"compose":[],"base_refs":[],"volumes":[],"image_error":"jq not found","volume_error":"jq not found"}\n'
        return 0
    fi

    # Volumes first: they report even when the image classes fail closed.
    if out=$(docker system df -v --format json 2>/dev/null) && [[ -n "$out" ]] \
        && volumes=$(jq -c "$DOCKER_RESIDUE_JQ_BYTES"' [.Volumes[]? | {name: .Name, size: (.Size | hbytes // 0), links: ((.Links // "0") | tonumber? // 0)}]' <<< "$out" 2>/dev/null); then
        :
    else
        volumes='[]'
        volume_error="docker system df -v failed"
    fi

    if ! docker compose version >/dev/null 2>&1; then
        image_error="docker compose not available"
    fi

    if [[ -z "$image_error" ]]; then
        ids=$(docker images -q --no-trunc 2>/dev/null | sort -u) || image_error="docker images failed"
        if [[ -z "$image_error" && -n "$ids" ]]; then
            # shellcheck disable=SC2086  # word-split the ID list on purpose
            out=$(docker image inspect $ids 2>/dev/null) \
                && images=$(jq -c '[.[] | {id: .Id, tags: (.RepoTags // []), created: .Created, size: .Size}]' <<< "$out" 2>/dev/null) \
                || image_error="docker image inspect failed"
        fi
    fi

    if [[ -z "$image_error" ]]; then
        ids=$(docker ps -aq --no-trunc 2>/dev/null) || image_error="docker ps failed"
        if [[ -z "$image_error" && -n "$ids" ]]; then
            sizes=$(docker ps -a --size --no-trunc --format '{"id":{{json .ID}},"size":{{json .Size}}}' 2>/dev/null \
                | jq -sc "$DOCKER_RESIDUE_JQ_BYTES"' map({(.id): (.size | hbytes)}) | add // {}' 2>/dev/null) || sizes='{}'
            [[ -n "$sizes" ]] || sizes='{}'
            # shellcheck disable=SC2086
            out=$(docker container inspect $ids 2>/dev/null) \
                && containers=$(jq -c --argjson sizes "$sizes" '[.[] | {
                        name: (.Name | ltrimstr("/")), id: .Id, image_id: .Image,
                        image_ref: .Config.Image, state: .State.Status, created: .Created,
                        project: (.Config.Labels["com.docker.compose.project"] // null),
                        service: (.Config.Labels["com.docker.compose.service"] // null),
                        size_rw: ($sizes[.Id] // null)}]' <<< "$out" 2>/dev/null) \
                || image_error="docker container inspect failed"
        fi
    fi

    if [[ -z "$image_error" ]]; then
        root=$(docker_residue_repo_root)
        local -a files=()
        if [[ -d "$root" ]]; then
            mapfile -t files < <(find "$root" -maxdepth 3 \( -name 'compose*.yml' -o -name 'compose*.yaml' \) -type f 2>/dev/null | sort)
        fi
        if ((${#files[@]} == 0)); then
            image_error="no compose files found under $root"
        fi
        for file in "${files[@]}"; do
            if ! cfg=$(docker compose -f "$file" --profile '*' config --format json 2>/dev/null) \
                || ! jq -e '.name and (.services | type == "object")' <<< "$cfg" >/dev/null 2>&1; then
                image_error="compose config failed: $file"
                break
            fi
            compose=$(jq -c --argjson cfg "$cfg" '. + [{project: $cfg.name, services: [$cfg.services | to_entries[] | {name: .key, image: (.value.image // null), build: (.value.build != null)}]}]' <<< "$compose")
            while IFS=$'\t' read -r dockerfile args; do
                [[ -n "$dockerfile" ]] || continue
                if ! refs=$(docker_residue_dockerfile_bases "$dockerfile" "$args"); then
                    image_error="Dockerfile unreadable or unresolved FROM: $dockerfile"
                    break 2
                fi
                bases=$(jq -c --arg r "$refs" '. + ($r | split("\n") | map(select(length > 0)))' <<< "$bases")
            done < <(jq -r '.services[] | .build | select(. != null)
                | [(if (.dockerfile // "Dockerfile") | startswith("/") then .dockerfile else (.context + "/" + (.dockerfile // "Dockerfile")) end),
                   ((.args // null) | tojson)] | @tsv' <<< "$cfg")
        done
    fi

    if [[ -n "$image_error" ]]; then
        images='[]' containers='[]' compose='[]' bases='[]'
    fi

    jq -nc --argjson images "$images" --argjson containers "$containers" \
        --argjson compose "$compose" --argjson bases "$bases" --argjson volumes "$volumes" \
        --arg ie "$image_error" --arg ve "$volume_error" \
        '{images: $images, containers: $containers, compose: $compose, base_refs: ($bases | unique),
          volumes: $volumes,
          image_error: (if $ie == "" then null else $ie end),
          volume_error: (if $ve == "" then null else $ve end)}'
}

### classifier #################################################################

# Pure jq over the capture JSON; see the header for the output shape.
# shellcheck disable=SC2016  # jq program, not shell expansion
DOCKER_RESIDUE_CLASSIFY_JQ='
def norm: sub("^docker\\.io/"; "") | sub("^library/"; "")
  | if test("@") then . elif (split("/") | last | test(":")) then . else . + ":latest" end;
def repo: if test("@") then split("@")[0] else sub(":[^:/]*$"; "") end;
# ts: ISO-8601 with optional fraction and Z or +-HH:MM offset -> epoch secs,
# or null when unparsable (a bare `capture(...)?` yields empty, which
# silently dropped the class field of the row). Fail safe: superseded needs both sides non-null
# (max ignores nulls unless every live time is null), so a malformed time
# can only ever make an image unreferenced, never safe-tier removable.
def ts: ([capture("^(?<d>[0-9-]+T[0-9:]{8})(?<f>\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$")?][0]) as $m
  | if $m == null then null
    else (($m.d + "Z") | fromdateiso8601)
      + (("0" + ($m.f // "")) | tonumber)
      - (if $m.z == "Z" then 0
         else ($m.z[0:1] + "1" | tonumber) * (($m.z[1:3] | tonumber) * 3600 + ($m.z[4:6] | tonumber) * 60) end)
    end;
def tsv: map(tostring) | join("\t");

( [ .volumes | sort_by(-.size, .name)[]? | ["volume", .name, .size, .links, (if .links == 0 then "dangling" else "linked" end)] | tsv ]
  + (if .volume_error then [["unavailable", "volumes", .volume_error] | tsv] else [] end) ) as $vol
| if .image_error then ([["unavailable", "images", .image_error] | tsv] + $vol)[]
  else
    . as $in
    | ([ .images[] | .id as $id | .tags[] | {key: norm, value: $id} ] | from_entries) as $byref
    | ([ .compose[] | .project as $p | .services[] | "\($p)/\(.name)" ]) as $svcs
    | ([ .compose[] | .project as $p | .services[]
         | (.image // (if .build then "\($p)-\(.name):latest" else empty end)) ]) as $crefs
    | [ .containers[] | select((.state == "created" or .state == "exited")
          and ((.project != null and .service != null and ("\(.project)/\(.service)" | IN($svcs[]))) | not)) ] as $stale
    | (([ .containers[] | select(.id | IN($stale[].id) | not) | .image_id ]
        + [ ($crefs + .base_refs)[] | norm | $byref[.] // empty ]) | unique) as $live
    | [ .images[] | select(.id | IN($live[])) | .created as $c | .tags[] | {repo: (norm | repo), t: ($c | ts)} ]
      | group_by(.repo) | map({key: .[0].repo, value: (map(.t) | max)}) | from_entries
      | . as $newest
    | ( [ $in.images[] | select(.id | IN($live[]) | not) | . as $img
          | ((.tags | if length == 0 then ["<none>"] else . end)[]) as $tag
          | ($newest[$tag | norm | repo] // null) as $n
          | [ (if $tag != "<none>" and $n != null and ($img.created | ts) != null and ($img.created | ts) <= $n then "superseded" else "unreferenced" end),
              $tag, $img.id, $img.size, $img.created,
              ([ $stale[] | select(.image_id == $img.id) | .name ] | if length == 0 then "-" else join(",") end) ] | tsv ] | sort
      + [ $stale[] | ["stale", .name, .image_id, (.size_rw // "unavailable"), .created, .state, (.image_ref // "-")] | tsv ]
      + $vol )[]
  end
'

docker_residue_classify() {
    jq -r "$DOCKER_RESIDUE_CLASSIFY_JQ"
}

### report (RT_DETAIL seam) ####################################################

docker_residue_short_id() {
    local id="${1#sha256:}"
    printf '%s\n' "${id:0:12}"
}

# docker_residue_report: render the classifier's TSV (stdin) as the docker
# detail block. Per-class byte sums count each image ID once (several tags of
# one ID free its bytes once) and are upper bounds: shared layers are counted
# in every image that carries them. Container writable-layer bytes are a
# separate figure and are never added to image bytes. Nothing here joins the
# runtime totals; the removal verbs are rt_docker_residue below, which
# re-captures at action time rather than reusing this report.
docker_residue_report() {
    local rows class a b c d e f
    local -A seen_sup=() seen_unref=()
    local sup_bytes=0 unref_bytes=0 stale_bytes=0 stale_unknown=false
    local sup_n=0 unref_n=0 stale_n=0 vol_n=0 vol_dangling=0 vol_dangling_bytes=0
    local images_unavailable="" volumes_unavailable=""
    local sup_lines="" unref_lines="" stale_lines="" vol_lines=""

    rows=$(cat)
    while IFS=$'\t' read -r class a b c d e f _; do
        case "$class" in
            superseded|unreferenced)
                local line
                line=$(printf '  %s  %s  %s  created %s%s' "$a" "$(docker_residue_short_id "$b")" \
                    "$(human_bytes "$c")" "${d%%T*}" "$([[ "$e" != - ]] && printf '  blocked by stale container(s): %s' "$e")")
                if [[ "$class" == superseded ]]; then
                    sup_lines+="$line"$'\n'; sup_n=$((sup_n + 1))
                    [[ -n "${seen_sup[$b]:-}" ]] || { seen_sup[$b]=1; sup_bytes=$((sup_bytes + c)); }
                else
                    unref_lines+="$line"$'\n'; unref_n=$((unref_n + 1))
                    [[ -n "${seen_unref[$b]:-}" ]] || { seen_unref[$b]=1; unref_bytes=$((unref_bytes + c)); }
                fi
                ;;
            stale)
                stale_n=$((stale_n + 1))
                if [[ "$c" =~ ^[0-9]+$ ]]; then
                    stale_bytes=$((stale_bytes + c))
                    c=$(human_bytes "$c")
                else
                    stale_unknown=true
                fi
                stale_lines+=$(printf '  %s  %s  image %s (%s)  writable layer %s  created %s' \
                    "$a" "$e" "$f" "$(docker_residue_short_id "$b")" "$c" "${d%%T*}")$'\n'
                ;;
            volume)
                vol_n=$((vol_n + 1))
                if [[ "$d" == dangling ]]; then
                    vol_dangling=$((vol_dangling + 1))
                    vol_dangling_bytes=$((vol_dangling_bytes + b))
                fi
                vol_lines+=$(printf '  %s  %s  links %s%s' "$a" "$(human_bytes "$b")" "$c" \
                    "$([[ "$d" == dangling ]] && printf '  [dangling]')")$'\n'
                ;;
            unavailable)
                if [[ "$a" == images ]]; then images_unavailable="$b"; else volumes_unavailable="$b"; fi
                ;;
        esac
    done <<< "$rows"

    if [[ -n "$images_unavailable" ]]; then
        printf 'docker superseded images: unavailable (%s)\n' "$images_unavailable"
        printf 'docker unreferenced images: unavailable (%s)\n' "$images_unavailable"
        printf 'docker stale containers: unavailable (%s)\n' "$images_unavailable"
    else
        printf 'docker superseded images: %s (%d bytes, %d tags) (safe tier, upper bound: shared layers)\n' \
            "$(human_bytes "$sup_bytes")" "$sup_bytes" "$sup_n"
        printf '%s' "$sup_lines"
        printf 'docker unreferenced images: %s (%d bytes, %d tags) (purge tier, per-image confirm, upper bound)\n' \
            "$(human_bytes "$unref_bytes")" "$unref_bytes" "$unref_n"
        printf '%s' "$unref_lines"
        if [[ "$stale_unknown" == true ]]; then
            printf 'docker stale containers: %d, writable layers unavailable (purge tier; container bytes are not image bytes)\n' "$stale_n"
        else
            printf 'docker stale containers: %d, writable layers %s (%d bytes) (purge tier; container bytes are not image bytes)\n' \
                "$stale_n" "$(human_bytes "$stale_bytes")" "$stale_bytes"
        fi
        printf '%s' "$stale_lines"
        printf 'note: docker image/container residue is not counted in the totals below; outside --report it is acted on after the build-cache prune (superseded under --yes, stale containers with --include-purge, unreferenced only per-image interactively).\n'
    fi

    if [[ -n "$volumes_unavailable" ]]; then
        printf 'docker volumes: unavailable (%s)\n' "$volumes_unavailable"
    else
        printf 'docker volumes: %d (%d dangling, %s / %d bytes) -- report-only, no verb: this tool never removes volumes\n' \
            "$vol_n" "$vol_dangling" "$(human_bytes "$vol_dangling_bytes")" "$vol_dangling_bytes"
        printf '%s' "$vol_lines"
    fi
}

# rt_docker_detail: the RT_DETAIL seam for docker. Captures once and prints;
# never part of the probe record, so docker's size line, safe-tier estimate
# and before/after delta are exactly what they were.
rt_docker_detail() {
    if ! command -v jq >/dev/null 2>&1; then
        printf 'docker image/container/volume residue: unavailable (jq not found)\n'
        return 0
    fi
    local capture rows

    capture=$(docker_residue_capture)
    # Fail closed: a classifier that errors (or prints nothing at all, which
    # a healthy run never does -- volumes or an unavailable row always
    # appear) must never read as "zero residue".
    if ! rows=$(docker_residue_classify <<< "$capture") || [[ -z "$rows" ]]; then
        printf 'docker image/container/volume residue: unavailable (classifier failed)\n'
        return 0
    fi
    docker_residue_report <<< "$rows"
}

### removal (RT_RESIDUE seam, WP-2) ############################################

# docker_residue_footprint: the image + container footprint docker reports
# (`docker system df --format json`, Images + Containers `Size`), in bytes.
# Exit 1 -- never a guess -- when the reading or either row is missing.
docker_residue_footprint() {
    local out
    out=$(docker system df --format json 2>/dev/null) && [[ -n "$out" ]] || return 1
    jq -rs "$DOCKER_RESIDUE_JQ_BYTES"' (map(select(.Type == "Images" or .Type == "Containers")) | map(.Size | hbytes)) as $s
        | if ($s | length) == 2 and all($s[]; . != null) then ($s | add) else error("incomplete") end' <<< "$out" 2>/dev/null
}

# docker_residue_remove: one item, never forced. A failure (an rmi conflict
# with a container, a vanished daemon) is a per-item warning; the caller
# counts it and carries on with the next item.
docker_residue_remove() {
    local kind="$1" target="$2"
    if [[ "$kind" == container ]]; then
        docker rm "$target" >/dev/null && return 0
    else
        docker rmi "$target" >/dev/null && return 0
    fi
    warn "docker: could not remove $kind $target (left in place)"
    return 1
}

# rt_docker_residue: the docker-only residue step, run by process_runtime
# after the build-cache verb and its delta line (never in --report, never
# when the size probe was unavailable). It is deliberately NOT an RT_PURGE
# entry: under --yes a purge election replaces the safe verb, which would
# stop `docker builder prune` from running.
#
# Classifies a FRESH capture taken now; images unavailable or a classifier
# error elects nothing. Elections: superseded -- --yes, or one interactive
# confirm; stale containers -- --include-purge (one interactive confirm);
# unreferenced -- never under --yes, one interactive confirm per image only
# with --include-purge. Execution order: stale containers (they block rmi),
# superseded, unreferenced. Per-item failures are warnings, never FAILED.
# Sets RUNTIME_RESIDUE_ACTED when any removal was attempted.
rt_docker_residue() {
    RUNTIME_RESIDUE_ACTED=false
    if ! command -v jq >/dev/null 2>&1; then
        printf 'docker residue: nothing elected (jq not found)\n'
        return 0
    fi

    local capture rows class a b c _rest reason
    local -a sup_refs=() stale_names=() unref_refs=() unref_targets=() unref_sizes=()
    local -A sup_seen=()
    local sup_bytes=0

    capture=$(docker_residue_capture)
    if ! rows=$(docker_residue_classify <<< "$capture") || [[ -z "$rows" ]]; then
        printf 'docker residue: nothing elected (classifier failed)\n'
        return 0
    fi
    reason=$(awk -F'\t' '$1 == "unavailable" && $2 == "images" { print $3; exit }' <<< "$rows")
    if [[ -n "$reason" ]]; then
        printf 'docker residue: nothing elected (images unavailable: %s)\n' "$reason"
        return 0
    fi

    while IFS=$'\t' read -r class a b c _rest; do
        case "$class" in
            superseded)
                sup_refs+=("$a")
                [[ -n "${sup_seen[$b]:-}" ]] || { sup_seen[$b]=1; sup_bytes=$((sup_bytes + c)); }
                ;;
            unreferenced)
                unref_refs+=("$a")
                if [[ "$a" == "<none>" ]]; then unref_targets+=("$b"); else unref_targets+=("$a"); fi
                unref_sizes+=("$(human_bytes "$c")")
                ;;
            stale)
                stale_names+=("$a")
                ;;
        esac
    done <<< "$rows"

    local do_sup=false do_stale=false
    if ((${#sup_refs[@]} > 0)); then
        case "$MODE" in
            yes) do_sup=true ;;
            interactive)
                confirm "Remove ${#sup_refs[@]} superseded docker image tags ($(human_bytes "$sup_bytes"))?" && do_sup=true
                ;;
        esac
    fi
    if ((${#stale_names[@]} > 0)) && [[ "$INCLUDE_PURGE" == true ]]; then
        case "$MODE" in
            yes) do_stale=true ;;
            interactive)
                confirm "Remove ${#stale_names[@]} stale docker containers (${stale_names[*]})? (purge tier)" && do_stale=true
                ;;
        esac
    fi

    local before="" after i ok_n fail_n summary=""
    if [[ "$do_sup" == true || "$do_stale" == true || ( "$MODE" == interactive && "$INCLUDE_PURGE" == true && ${#unref_refs[@]} -gt 0 ) ]]; then
        before=$(docker_residue_footprint) || before=""
    fi

    ok_n=0 fail_n=0
    if [[ "$do_stale" == true ]]; then
        RUNTIME_RESIDUE_ACTED=true
        for i in "${stale_names[@]}"; do
            if docker_residue_remove container "$i"; then ok_n=$((ok_n + 1)); else fail_n=$((fail_n + 1)); fi
        done
    fi
    summary+="stale containers removed $ok_n, failed $fail_n; "

    ok_n=0 fail_n=0
    if [[ "$do_sup" == true ]]; then
        RUNTIME_RESIDUE_ACTED=true
        for i in "${sup_refs[@]}"; do
            if docker_residue_remove image "$i"; then ok_n=$((ok_n + 1)); else fail_n=$((fail_n + 1)); fi
        done
    fi
    summary+="superseded tags removed $ok_n, failed $fail_n; "

    ok_n=0 fail_n=0
    if ((${#unref_refs[@]} > 0)); then
        if [[ "$MODE" == yes ]]; then
            printf 'skipped: %d unreferenced images need a per-image interactive confirm\n' "${#unref_refs[@]}"
        elif [[ "$MODE" == interactive && "$INCLUDE_PURGE" == true ]]; then
            for i in "${!unref_refs[@]}"; do
                confirm "Remove unreferenced docker image ${unref_refs[$i]} (${unref_sizes[$i]})? (purge tier)" || continue
                RUNTIME_RESIDUE_ACTED=true
                if docker_residue_remove image "${unref_targets[$i]}"; then ok_n=$((ok_n + 1)); else fail_n=$((fail_n + 1)); fi
            done
        fi
    fi
    summary+="unreferenced images removed $ok_n, failed $fail_n"

    if [[ "$RUNTIME_RESIDUE_ACTED" == false ]]; then
        printf 'docker residue: nothing removed\n'
        return 0
    fi
    printf 'docker residue: %s\n' "$summary"
    if [[ -n "$before" ]] && after=$(docker_residue_footprint); then
        printf 'docker images/containers: observed footprint change %s (%d bytes)\n' \
            "$(human_bytes_signed "$((after - before))")" "$((after - before))"
    else
        printf 'docker images/containers: observed footprint change unavailable (docker system df --format json reading failed)\n'
    fi
}
