# shellcheck shell=bash

# docker-residue.sh: read-only classifier for docker image / container /
# volume residue, reported under the docker runtime through the RT_DETAIL
# seam, plus the residue removal step (RT_RESIDUE seam). Sourced by
# ../cache-prune.sh; not a util subcommand. Everything above the "removal"
# section is read-only (images/image inspect/ps/container inspect/system df/
# compose config); the only mutating calls in this file are the per-item
# `docker rm <name>`, `docker rmi <ref|id>` and `docker volume rm <name>` in
# docker_residue_remove -- the last only on anonymous volumes (label key
# com.docker.volume.anonymous) that were already dangling before this run's
# removals. Never -f, never any prune; named volumes are never removed
# (they may hold user data; only anonymous volumes are disposable).
#
# Two layers, so the classifier stays a pure function of captured JSON:
#
#   docker_residue_capture
#       Probes the daemon + compose files (all in docker-residue.pl's
#       `capture` mode, including the Dockerfile FROM parser: ARG defaults
#       substituted, compose build args overriding them, earlier `AS` stage
#       names and `scratch` skipped, an unreadable file or unresolved variable
#       failing closed), prints ONE JSON document:
#         { images:     [{id, tags:[ref], created, size}],
#           containers: [{name, id, image_id, image_ref, state, created,
#                         project, service, size_rw}],   size_rw: bytes|null
#           compose:    [{project, services:[{name, image, build}]}],
#           base_refs:  [ref],
#           volumes:    [{name, size, links, anonymous}], size: bytes,
#                         anonymous: true iff Labels carries the key
#                         com.docker.volume.anonymous
#           image_error: null|"reason",  volume_error: null|"reason" }
#       Fail closed: any compose/Dockerfile/inspect failure sets image_error,
#       which the classifier turns into "unavailable" with no candidates.
#   docker_residue_classify  (stdin: the capture JSON)
#       THE STABLE OUTPUT SHAPE (consumed by the residue election), one TSV line
#       per row, first field the class:
#         superseded<TAB>ref<TAB>image_id<TAB>bytes<TAB>created<TAB>blockers
#         unreferenced<TAB>ref<TAB>image_id<TAB>bytes<TAB>created<TAB>blockers
#         stale<TAB>name<TAB>image_id<TAB>rw_bytes|unavailable<TAB>created<TAB>state<TAB>image_ref
#         volume<TAB>name<TAB>bytes<TAB>links<TAB>dangling|linked
#         anonvolume<TAB>name<TAB>bytes
#         unavailable<TAB>images|volumes<TAB>reason
#       blockers = comma-joined stale container names holding that image ID,
#       or "-". created = ISO-8601 as docker reports it. When images are
#       unavailable, no superseded/unreferenced/stale row is ever emitted.
#       Every volume gets a `volume` row; an anonymous dangling one also gets
#       an `anonvolume` row (the removal step's candidate set). When volumes
#       are unavailable, neither row is emitted.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

### capture ####################################################################

docker_residue_repo_root() {
    printf '%s\n' "${CACHE_PRUNE_REPO_ROOT:-/home/_shared_code}"
}

# The JSON half of this module (capture shaping, classifier, footprint sum)
# lives in the sibling perl + JSON::PP helper, so cache-prune needs no jq.
DOCKER_RESIDUE_PL="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/docker-residue.pl"

# docker_residue_perl_reason: empty when perl and JSON::PP are usable, else
# the `no <tool> on host` reason the three entry points report.
docker_residue_perl_reason() {
    if ! command -v perl >/dev/null 2>&1; then
        printf 'no perl on host'
    elif ! perl -MJSON::PP -e 1 >/dev/null 2>&1; then
        printf 'no JSON::PP on host'
    fi
}

# The docker/compose subprocesses, the Dockerfile FROM parser and the document
# shaping all run inside one perl process (mode `capture`): only the repo root
# crosses argv, never JSON, so the document size has no argv limit.
docker_residue_capture() {
    local reason

    reason=$(docker_residue_perl_reason)
    if [[ -n "$reason" ]]; then
        printf '{"images":[],"containers":[],"compose":[],"base_refs":[],"volumes":[],"image_error":"%s","volume_error":"%s"}\n' "$reason" "$reason"
        return 0
    fi

    perl "$DOCKER_RESIDUE_PL" capture "$(docker_residue_repo_root)"
}

### classifier #################################################################

# Pure function of the capture JSON (perl helper, mode `classify`); see the
# header for the output shape.
docker_residue_classify() {
    perl "$DOCKER_RESIDUE_PL" classify
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
    local anon_n=0 anon_bytes=0
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
            anonvolume)
                anon_n=$((anon_n + 1))
                anon_bytes=$((anon_bytes + b))
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
        printf 'docker anonymous volumes: unavailable (%s)\n' "$volumes_unavailable"
    else
        printf 'docker volumes: %d (%d dangling, %s / %d bytes) -- %d named dangling: report-only, no verb (named volumes are never removed)\n' \
            "$vol_n" "$vol_dangling" "$(human_bytes "$vol_dangling_bytes")" "$vol_dangling_bytes" "$((vol_dangling - anon_n))"
        printf '%s' "$vol_lines"
        printf 'docker anonymous volumes: %d dangling, %s (%d bytes) (purge tier, removed by name)\n' \
            "$anon_n" "$(human_bytes "$anon_bytes")" "$anon_bytes"
    fi
}

# rt_docker_detail: the RT_DETAIL seam for docker. Captures once and prints;
# never part of the probe record, so docker's size line, safe-tier estimate
# and before/after delta are exactly what they were.
rt_docker_detail() {
    local capture rows reason
    reason=$(docker_residue_perl_reason)
    if [[ -n "$reason" ]]; then
        printf 'docker image/container/volume residue: unavailable (%s)\n' "$reason"
        return 0
    fi

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

### removal (RT_RESIDUE seam) ############################################

# docker_residue_footprint: the image + container + volume footprint docker
# reports (`docker system df --format json`, Images + Containers + Local
# Volumes `Size`), in bytes. Exit 1 -- never a guess -- when the reading or
# any of the three rows is missing.
docker_residue_footprint() {
    local out
    out=$(docker system df --format json 2>/dev/null) && [[ -n "$out" ]] || return 1
    perl "$DOCKER_RESIDUE_PL" footprint <<< "$out" 2>/dev/null
}

# docker_residue_probe: docker_residue_footprint as a probe record, left in
# PROBE_RECORD (measurement.sh), so the residue delta goes through probe_compare like
# every other delta -- before minus after, freed bytes positive.
docker_residue_probe() {
    local bytes
    if bytes=$(docker_residue_footprint) && [[ "$bytes" =~ ^[0-9]+$ ]]; then
        probe_available "$bytes" 0 docker-system-df
    else
        probe_unavailable
    fi
}

# docker_residue_remove: one item, never forced. A failure (an rmi conflict
# with a container, a vanished daemon) is a per-item warning; the caller
# counts it and carries on with the next item.
docker_residue_remove() {
    local kind="$1" target="$2"
    if [[ "$kind" == container ]]; then
        docker rm "$target" >/dev/null && return 0
    elif [[ "$kind" == volume ]]; then
        docker volume rm "$target" >/dev/null && return 0
    else
        docker rmi "$target" >/dev/null && return 0
    fi
    warn "docker: could not remove $kind $target (left in place)"
    return 1
}

# rt_docker_residue: the docker-only residue step, run by process_runtime
# after the build-cache verb and its delta line (never in --report, never
# when the size probe was unavailable). It is deliberately NOT an RT_PURGE
# entry: under --yes a purge election replaces the safe verb, so the residue
# step is registered separately and runs after whichever build-cache verb
# (safe or purge) was elected.
#
# Classifies a FRESH capture taken now; images unavailable or a classifier
# error elects nothing. Elections: superseded -- --yes, or one interactive
# confirm; stale containers -- --include-purge (one interactive confirm);
# unreferenced -- never under --yes, one interactive confirm per image only
# with --include-purge; anonymous dangling volumes -- same tier as stale
# containers (one interactive confirm naming count and size). Execution
# order: stale containers (they block rmi), anonymous volumes, superseded,
# unreferenced. Volume election: names that were anonymous and dangling in
# the capture above (before any removal) AND still are in a fresh capture
# taken after the stale-container step -- a volume orphaned by this run's
# `docker rm` waits for the next run. Per-item failures are warnings.
# Elections go through tier_elected (actions.sh). Sets RUNTIME_ACTED when
# any removal was attempted.
rt_docker_residue() {
    local acted=false
    local capture rows class a b c _rest reason
    reason=$(docker_residue_perl_reason)
    if [[ -n "$reason" ]]; then
        printf 'docker residue: nothing elected (%s)\n' "$reason"
        return 0
    fi
    local -a sup_refs=() stale_names=() unref_refs=() unref_targets=() unref_sizes=()
    local -A sup_seen=() anon_before=()
    local sup_bytes=0 anon_bytes=0

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
            anonvolume)
                anon_before[$a]=1
                anon_bytes=$((anon_bytes + b))
                ;;
        esac
    done <<< "$rows"

    local do_sup=false do_stale=false do_vol=false
    if ((${#sup_refs[@]} > 0)) \
        && tier_elected safe "Remove ${#sup_refs[@]} superseded docker image tags ($(human_bytes "$sup_bytes"))?"; then
        do_sup=true
    fi
    if ((${#stale_names[@]} > 0)) \
        && tier_elected purge "Remove ${#stale_names[@]} stale docker containers (${stale_names[*]})? (purge tier)"; then
        do_stale=true
    fi
    if ((${#anon_before[@]} > 0)) \
        && tier_elected purge "Remove ${#anon_before[@]} anonymous dangling docker volumes ($(human_bytes "$anon_bytes"))? (purge tier)"; then
        do_vol=true
    fi

    local before after i ok_n fail_n summary="" cmp delta
    probe_unavailable
    before="$PROBE_RECORD"
    if [[ "$do_sup" == true || "$do_stale" == true || "$do_vol" == true || ( "$MODE" == interactive && "$INCLUDE_PURGE" == true && ${#unref_refs[@]} -gt 0 ) ]]; then
        docker_residue_probe
        before="$PROBE_RECORD"
    fi

    ok_n=0 fail_n=0
    if [[ "$do_stale" == true ]]; then
        acted=true
        for i in "${stale_names[@]}"; do
            if docker_residue_remove container "$i"; then ok_n=$((ok_n + 1)); else fail_n=$((fail_n + 1)); fi
        done
    fi
    summary+="stale containers removed $ok_n, failed $fail_n; "

    ok_n=0 fail_n=0
    if [[ "$do_vol" == true ]]; then
        local fresh vrows
        local -a vol_names=()
        fresh=$(docker_residue_capture)
        if vrows=$(docker_residue_classify <<< "$fresh") && [[ -n "$vrows" ]] \
            && ! awk -F'\t' '$1 == "unavailable" && $2 == "volumes" { found = 1 } END { exit !found }' <<< "$vrows"; then
            while IFS=$'\t' read -r class a _rest; do
                [[ "$class" == anonvolume && -n "${anon_before[$a]:-}" ]] && vol_names+=("$a")
            done <<< "$vrows"
        else
            printf 'docker anonymous volumes: nothing elected (fresh volume capture unavailable)\n'
        fi
        for i in "${vol_names[@]}"; do
            acted=true
            if docker_residue_remove volume "$i"; then ok_n=$((ok_n + 1)); else fail_n=$((fail_n + 1)); fi
        done
    fi
    summary+="anonymous volumes removed $ok_n, failed $fail_n; "

    ok_n=0 fail_n=0
    if [[ "$do_sup" == true ]]; then
        acted=true
        for i in "${sup_refs[@]}"; do
            if docker_residue_remove image "$i"; then ok_n=$((ok_n + 1)); else fail_n=$((fail_n + 1)); fi
        done
    fi
    summary+="superseded tags removed $ok_n, failed $fail_n; "

    ok_n=0 fail_n=0
    if ((${#unref_refs[@]} > 0)); then
        if [[ "$MODE" == yes ]]; then
            printf 'skipped: %d unreferenced images need a per-image interactive confirm\n' "${#unref_refs[@]}"
        else
            for i in "${!unref_refs[@]}"; do
                tier_elected item "Remove unreferenced docker image ${unref_refs[$i]} (${unref_sizes[$i]})? (purge tier)" || continue
                acted=true
                if docker_residue_remove image "${unref_targets[$i]}"; then ok_n=$((ok_n + 1)); else fail_n=$((fail_n + 1)); fi
            done
        fi
    fi
    summary+="unreferenced images removed $ok_n, failed $fail_n"

    if [[ "$acted" == false ]]; then
        printf 'docker residue: nothing removed\n'
        return 0
    fi
    # shellcheck disable=SC2034  # lifecycle state, read by process_runtime
    RUNTIME_ACTED=true
    printf 'docker residue: %s\n' "$summary"
    probe_unavailable
    after="$PROBE_RECORD"
    if probe_is_available "$before"; then
        docker_residue_probe
        after="$PROBE_RECORD"
    fi
    cmp=$(probe_compare docker-residue "$before" "$after")
    if [[ "$cmp" == available\ * ]]; then
        delta="${cmp#available }"
        printf 'docker images/containers/volumes: observed footprint change %s (%d bytes)\n' \
            "$(human_bytes_signed "$delta")" "$delta"
    else
        printf 'docker images/containers/volumes: observed footprint change unavailable (docker system df --format json reading failed)\n'
    fi
}
