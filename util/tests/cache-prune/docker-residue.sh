# shellcheck shell=bash
#
# Docker residue suite: the read-only image/container/volume classifier
# (../../cache-prune/docker-residue.sh) and its RT_DETAIL report under the
# docker runtime.
#
# Sourced by ../cache-prune.sh, the canonical test entry point, which owns
# the harness, the sandbox and the command doubles. Not runnable on its own.
# The classifier is fed fixture JSON directly (no daemon); the capture path
# runs against a docker double that serves the fixtures below and records
# every call, so the mutate log can prove --report never mutates.
# shellcheck disable=SC1091,SC2317,SC2034

DR_FIX="$HERE/cache-prune/fixtures/docker-residue"

echo "[docker-residue] classifier over captured JSON"
dr_rows=$(docker_residue_classify < "$DR_FIX/classify-input.json")
dr_class_of() { awk -F'\t' -v ref="$1" '$2 == ref { print $1 }' <<< "$dr_rows"; }

assert_eq "superseded" "$(dr_class_of homelab-cameras:wp2)" "an older work tag of a live repository (offset timestamps) is superseded"
assert_eq "superseded" "$(dr_class_of llama-vulkan:b10121)" "an older tag of the compose-pinned llama repository is superseded"
assert_eq "unreferenced" "$(dr_class_of llama-vulkan:b11429-swap243)" "a tag newer than its live sibling is unreferenced, never superseded"
assert_eq "" "$(dr_class_of llama-vulkan:b10534-swap243)" "the compose-pinned tag is live"
assert_eq "" "$(dr_class_of homelab-cameras:latest)" "the implied <project>-<service>:latest of a build-only service is live"
assert_eq "" "$(dr_class_of searxng/searxng:2026.8.22-9fea41204)" "a docker.io/-prefixed compose ref matches the unprefixed local tag"
assert_eq "" "$(dr_class_of ghcr.io/example/homehub:2026.9.4)" "a profiled service's image is live"
assert_eq "" "$(dr_class_of ghcr.io/example/webapp:v0.11.4-slim)$(dr_class_of alpine:latest)" "Dockerfile base refs (incl. implicit :latest) protect their images"
assert_eq "" "$(awk -F'\t' '$1 == "stale" && $2 == "engine-svc-tts"' <<< "$dr_rows")" "an exited container of a live compose service is not stale"
assert_eq "" "$(dr_class_of engine-svc-tts:torch2.11-rocm7.2)" "the image of a live service's exited container is live"
assert_contains "$dr_rows" $'stale\tlegacy_project-old-1\tsha256:prerename0000\t1000\t' "a pre-rename project's exited container is stale, with its writable-layer bytes"
assert_contains "$dr_rows" $'unreferenced\tlegacy_project-legacy-project:latest\tsha256:prerename0000\t384300000\t2026-07-09T00:00:00Z\tlegacy_project-old-1' "an image held only by a stale container is a candidate naming its blocker"
assert_contains "$dr_rows" $'volume\thomelab_radar-data\t4300000000\t0\tdangling' "a zero-link volume is flagged dangling"

# --- capture path, against a fixture-serving docker PATH shim ---------------
#
# The capture runs inside a perl subprocess, which cannot see a bash docker()
# function. So the capture is served by an executable `docker` shim in a
# sandbox bin dir (generated here, no tracked file) that answers from
# file-backed fixtures keyed on its argv and appends each call to the same
# ALL_LOG_FILE the function double uses. dr_sync writes the DR_* variables
# below to those files; the capture wrapper further down calls it, then runs
# the real docker_residue_capture with the shim first on PATH. Removal verbs,
# `builder prune` and the footprint `system df` stay on the function double.
DR_BIN="$SANDBOX/dr-bin"
DR_FIXD="$SANDBOX/dr-fixtures"
mkdir -p "$DR_BIN" "$DR_FIXD"
cat > "$DR_BIN/docker" <<'DR_SHIM'
#!/usr/bin/env bash
fix=@FIXD@
log=@LOG@
printf 'docker %s|' "$*" >> "$log"
ids() { perl -MJSON::PP -e 'print "$_->{Id}\n" for @{decode_json(join "", <STDIN>)}' < "$1"; }
case "$*" in
    "system df -v --format json")
        [[ ! -e "$fix/volumes-fail" ]] || exit 1
        # Once a `docker rm` has run since the last reset, serve the
        # post-stale-removal volume list the election re-reads.
        if [[ -s "$fix/volumes-after-rm.json" ]] && grep -q 'docker rm ' "$log"; then
            printf '{"Volumes":%s}\n' "$(cat "$fix/volumes-after-rm.json")"
        else
            printf '{"Volumes":%s}\n' "$(cat "$fix/volumes.json")"
        fi
        ;;
    "compose version") ;;
    compose\ -f\ *)
        [[ ! -e "$fix/compose-fail" ]] || exit 1
        cat "$fix/compose.json"
        ;;
    "images -q --no-trunc") ids "$fix/images.json" ;;
    image\ inspect*) cat "$fix/images.json" ;;
    "ps -aq --no-trunc") ids "$fix/containers.json" ;;
    ps\ -a\ --size*)
        perl -MJSON::PP -e 'print JSON::PP->new->canonical->encode({id => $_->{Id}, size => "1kB"}), "\n" for @{decode_json(join "", <STDIN>)}' < "$fix/containers.json"
        ;;
    container\ inspect*) cat "$fix/containers.json" ;;
    *) exit 1 ;;
esac
DR_SHIM
sed -i "s|@FIXD@|$DR_FIXD|; s|@LOG@|$ALL_LOG_FILE|" "$DR_BIN/docker"
chmod +x "$DR_BIN/docker"
dr_sync() {
    printf '%s\n' "$DR_IMAGES_JSON" > "$DR_FIXD/images.json"
    printf '%s\n' "$DR_CONTAINERS_JSON" > "$DR_FIXD/containers.json"
    printf '%s' "$DR_VOLUMES_JSON" > "$DR_FIXD/volumes.json"
    printf '%s' "$DR_VOLUMES_AFTER_RM_JSON" > "$DR_FIXD/volumes-after-rm.json"
    printf '%s\n' "$DR_COMPOSE_JSON" > "$DR_FIXD/compose.json"
    rm -f "$DR_FIXD/volumes-fail" "$DR_FIXD/compose-fail"
    if ((DR_VOLUMES_FAIL != 0)); then : > "$DR_FIXD/volumes-fail"; fi
    if ((DR_COMPOSE_RESULT != 0)); then : > "$DR_FIXD/compose-fail"; fi
}
DR_ORIGINAL_CAPTURE="$(declare -f docker_residue_capture)"
eval "dr_prod_$DR_ORIGINAL_CAPTURE"
docker_residue_capture() {
    dr_sync
    PATH="$DR_BIN:$PATH" dr_prod_docker_residue_capture
}

DR_ROOT="$SANDBOX/docker-residue-root"
mkdir -p "$DR_ROOT/homelab"
: > "$DR_ROOT/homelab/compose.yml"
DR_COMPOSE_JSON=$(sed "s|@FIXTURES@|$DR_FIX|g" "$DR_FIX/compose-config.json")
DR_COMPOSE_RESULT=0
DR_IMAGES_JSON='[{"Id":"sha256:old","RepoTags":["webapp-overlay:v0.11.3"],"Created":"2026-01-01T00:00:00Z","Size":5},{"Id":"sha256:overlay","RepoTags":["webapp-overlay:v0.11.4"],"Created":"2026-09-01T00:00:00Z","Size":7}]'
DR_CONTAINERS_JSON='[]'
DR_DF_JSON=""
DR_VOLUMES_JSON='[{"Name":"orphan-vol","Size":"43.35MB","Links":"0"}]'
# Served instead of DR_VOLUMES_JSON once a `docker rm` has run in this
# shell: the post-stale-removal capture the volume election re-reads.
DR_VOLUMES_AFTER_RM_JSON=""
DR_VOLUMES_FAIL=0
DR_ORIGINAL_DOCKER="$(declare -f docker)"
eval "dr_harness_$(declare -f docker)"
docker() {
    case "$*" in
        volume\ rm\ *)
            printf 'docker %s|' "$*" >> "$ALL_LOG_FILE"
            MUTATE_LOG+="docker $*|"
            if [[ -n "$DOCKER_RM_FAIL_TARGET" && "${*: -1}" == "$DOCKER_RM_FAIL_TARGET" ]]; then
                printf 'Error response from daemon: remove %s: volume is in use\n' "$DOCKER_RM_FAIL_TARGET" >&2
                return 1
            fi
            ;;
        "system df --format json")
            printf 'docker %s|' "$*" >> "$ALL_LOG_FILE"
            [[ -n "$DR_DF_JSON" ]] || return 1
            printf '%s\n' "$DR_DF_JSON"
            ;;
        *)
            dr_harness_docker "$@"
            ;;
    esac
}

echo "[docker-residue] Dockerfile base-ref resolution (the perl FROM parser, through capture)"
# One compose service building <dockerfile> with build args <args-json>; no
# images or containers, so the document's base_refs/image_error are the parse.
dr_capture_build() {
    (
        CACHE_PRUNE_REPO_ROOT="$DR_ROOT"
        DR_IMAGES_JSON='[]'
        DR_CONTAINERS_JSON='[]'
        DR_COMPOSE_RESULT=0
        DR_COMPOSE_JSON=$(printf '{"name":"p","services":{"s":{"build":{"context":"%s","dockerfile":"%s","args":%s}}}}' "$DR_FIX" "$1" "${2:-null}")
        docker_residue_capture
    )
}
dr_capture_field() {
    perl -MJSON::PP -e '$d = decode_json(join "", <STDIN>); $v = $d->{$ARGV[0]}; print ref $v ? join("\n", @$v) : defined $v ? $v : "null", "\n"' "$1"
}
# base_refs come back sorted and de-duplicated (the capture document's shape),
# so the multistage expectation is in that order.
assert_eq "ghcr.io/example/webapp:v0.11.4-slim" "$(dr_capture_build Dockerfile.overlay | dr_capture_field base_refs)" "ARG default feeds FROM \${ARG}"
assert_eq "example/upstream:9" "$(dr_capture_build Dockerfile.overlay '{"UPSTREAM":"example/upstream:9"}' | dr_capture_field base_refs)" "a compose build arg overrides the ARG default"
assert_eq $'alpine:latest\ngolang:1.26.7-trixie' "$(dr_capture_build Dockerfile.multistage | dr_capture_field base_refs)" "stage names and scratch are never image refs; --platform is skipped"
assert_eq "Dockerfile unreadable or unresolved FROM: $DR_FIX/Dockerfile.unresolved" "$(dr_capture_build Dockerfile.unresolved | dr_capture_field image_error)" "an unresolvable FROM variable fails closed"
assert_eq "Dockerfile unreadable or unresolved FROM: $DR_FIX/Dockerfile.absent" "$(dr_capture_build Dockerfile.absent | dr_capture_field image_error)" "an unreadable Dockerfile fails closed"

echo "[docker-residue] capture: compose resolved with every profile, fail closed on error"
CACHE_PRUNE_REPO_ROOT="$DR_ROOT"
reset_logs
dr_rows=$(docker_residue_capture | docker_residue_classify)
assert_contains "$(all_log)" "--profile * config --format json" "compose is resolved with --profile '*'"
assert_eq $'superseded\twebapp-overlay:v0.11.3\tsha256:old\t5\t2026-01-01T00:00:00Z\t-' "$(grep -v '^volume' <<< "$dr_rows")" "captured compose + Dockerfiles classify end to end"

reset_logs
DR_COMPOSE_RESULT=1
dr_rows=$(docker_residue_capture | docker_residue_classify)
assert_contains "$dr_rows" $'unavailable\timages\tcompose config failed: ' "a compose-config failure reports the image classes unavailable"
assert_eq "" "$(grep -E '^(superseded|unreferenced|stale)' <<< "$dr_rows")" "a compose-config failure yields no candidates"
assert_contains "$dr_rows" $'volume\torphan-vol\t43350000\t0\tdangling' "volumes still report when the image classes fail closed"

echo "[docker-residue] --report under the docker runtime never mutates"
reset_logs
all_present
MODE="report"
INCLUDE_PURGE=false
DR_COMPOSE_RESULT=0
dr_out=$(process_runtime docker 2>&1)
assert_contains "$dr_out" "docker superseded images: 5.0B (5 bytes, 1 tags) (safe tier, upper bound: shared layers)" "--report prints the superseded class under docker"
assert_contains "$dr_out" "docker volumes: 1 (1 dangling" "--report prints the volumes section"
assert_contains "$dr_out" "report-only, no verb" "volumes say they have no verb"
assert_eq "" "$MUTATE_LOG" "--report issues no mutating docker command"


echo "[docker-residue] an unparsable created time fails safe (never superseded)"
dr_bad=$(perl -MJSON::PP -e '$d = decode_json(join "", <STDIN>); push @{$d->{images}}, {id => "sha256:badts", tags => ["webapp-overlay:v0.0.1"], created => "not-a-date", size => 3}; print encode_json($d), "\n"' <<< '{"images":[{"id":"sha256:live","tags":["webapp-overlay:v0.11.4"],"created":"2026-09-01T00:00:00Z","size":7},{"id":"sha256:old2","tags":["dead:1"],"created":"2026-01-01T00:00:00Z","size":1},{"id":"sha256:liveb","tags":["dead:2"],"created":"garbage","size":1}],"containers":[],"compose":[{"project":"p","services":[{"name":"a","image":"webapp-overlay:v0.11.4","build":false},{"name":"b","image":"dead:2","build":false}]}],"base_refs":[],"volumes":[],"image_error":null,"volume_error":null}' | docker_residue_classify)
assert_eq "unreferenced" "$(awk -F'\t' '$2 == "webapp-overlay:v0.0.1" { print $1 }' <<< "$dr_bad")" "a candidate with an unparsable created time is unreferenced"
assert_eq "unreferenced" "$(awk -F'\t' '$2 == "dead:1" { print $1 }' <<< "$dr_bad")" "a candidate whose live sibling's time is unparsable is unreferenced"

# --- WP-2: residue verbs and election ---------------------------------------

DR_IMAGES_JSON='[{"Id":"sha256:old","RepoTags":["webapp-overlay:v0.11.3"],"Created":"2026-01-01T00:00:00Z","Size":5},{"Id":"sha256:old1","RepoTags":["webapp-overlay:v0.11.1"],"Created":"2025-12-01T00:00:00Z","Size":4},{"Id":"sha256:overlay","RepoTags":["webapp-overlay:v0.11.4"],"Created":"2026-09-01T00:00:00Z","Size":7},{"Id":"sha256:ua","RepoTags":["orphan-a:1"],"Created":"2026-02-01T00:00:00Z","Size":11},{"Id":"sha256:ub","RepoTags":["orphan-b:1"],"Created":"2026-02-01T00:00:00Z","Size":13}]'
DR_CONTAINERS_JSON='[{"Name":"/gone-x-1","Id":"c1","Image":"sha256:ua","Config":{"Image":"orphan-a:1","Labels":{"com.docker.compose.project":"gone","com.docker.compose.service":"x"}},"State":{"Status":"exited"},"Created":"2026-02-02T00:00:00Z"}]'
DR_DF_JSON=$'{"Type":"Images","Size":"40B"}\n{"Type":"Containers","Size":"1kB"}\n{"Type":"Local Volumes","Size":"5MB"}'
CACHE_PRUNE_REPO_ROOT="$DR_ROOT"
all_present
dr_banned_log=""
dr_run() {
    reset_logs
    MODE="$1"
    INCLUDE_PURGE="$2"
    DOCKER_UNTIL=""
    dr_out=$(process_runtime docker 2>&1; printf '\nMUTATE=%s\nCONFIRM=%s' "$MUTATE_LOG" "$CONFIRM_LOG")
    dr_mut="${dr_out##*MUTATE=}"; dr_mut="${dr_mut%%$'\n'CONFIRM=*}"
    dr_conf="${dr_out##*CONFIRM=}"
    dr_banned_log+="$dr_mut"
}
DR_ORIGINAL_CONFIRM="$(declare -f confirm)"
DR_CONFIRM_YES=""
confirm() {
    CONFIRM_LOG+="$1|"
    [[ -n "$DR_CONFIRM_YES" && "$1" == *"$DR_CONFIRM_YES"* ]]
}

echo "[docker-residue] --report still mutates nothing"
dr_run report false
assert_eq "" "$dr_mut" "--report issues no rm/rmi"

echo "[docker-residue] --yes removes superseded tags only"
dr_run yes false
assert_contains "$dr_mut" "docker builder prune" "--yes still runs docker builder prune"
assert_contains "$dr_mut" "docker rmi webapp-overlay:v0.11.1|docker rmi webapp-overlay:v0.11.3|" "--yes untags each superseded tag by ref"
assert_not_contains "$dr_mut" "docker rm " "--yes removes no container"
assert_not_contains "$dr_mut" "orphan-" "--yes removes no unreferenced image"
assert_contains "$dr_out" "skipped: 2 unreferenced images need a per-image interactive confirm" "--yes says why unreferenced images are skipped"
assert_contains "$dr_out" "docker images/containers/volumes: observed footprint change 0.0B" "the residue step prints its own measured footprint line"

echo "[docker-residue] --yes --include-purge: stale containers first"
dr_run yes true
assert_contains "$dr_mut" "docker builder prune -a --force|docker rm gone-x-1|docker rmi webapp-overlay:v0.11.1|docker rmi webapp-overlay:v0.11.3|" "builder prune, then stale rm, then superseded rmi"
assert_not_contains "$dr_mut" "orphan-" "--yes --include-purge still removes no unreferenced image"

echo "[docker-residue] interactive --include-purge: one confirm per unreferenced image"
DR_CONFIRM_YES="orphan-b:1"
dr_run interactive true
assert_contains "$dr_conf" "Remove 2 superseded docker image tags (9.0B)?|Remove 1 stale docker containers (gone-x-1)? (purge tier)|Remove unreferenced docker image orphan-a:1 (11.0B)? (purge tier)|Remove unreferenced docker image orphan-b:1 (13.0B)? (purge tier)|" "superseded, stale, then per-image confirms"
assert_eq "docker rmi orphan-b:1|" "$dr_mut" "a yes on one image and no on another removes exactly that one"
assert_not_contains "$dr_out" "docker: skipped." "an acted residue step suppresses the skipped line"

echo "[docker-residue] plain interactive never prompts for stale or unreferenced"
DR_CONFIRM_YES=""
dr_run interactive false
assert_not_contains "$dr_conf" "stale" "no stale-container prompt without --include-purge"
assert_not_contains "$dr_conf" "unreferenced" "no unreferenced prompt without --include-purge"
assert_contains "$dr_conf" "Remove 2 superseded docker image tags" "plain interactive offers the superseded class"
assert_contains "$dr_out" "docker: skipped." "declining everything still reports skipped"

echo "[docker-residue] a per-item conflict warns and the next item still runs"
dr_run yes false
DOCKER_RM_FAIL_TARGET="webapp-overlay:v0.11.1"
dr_out=$(process_runtime docker 2>&1; printf '\nMUTATE=%s' "$MUTATE_LOG")
assert_contains "$dr_out" "could not remove image webapp-overlay:v0.11.1" "the conflicting item is warned about"
assert_contains "$dr_out" "docker rmi webapp-overlay:v0.11.3|" "the next superseded tag is still removed"
assert_contains "$dr_out" "superseded tags removed 1, failed 1" "the summary counts removed and failed"
dr_banned_log+="${dr_out##*MUTATE=}"
DOCKER_RM_FAIL_TARGET=""

echo "[docker-residue] an images-unavailable capture elects nothing"
DR_COMPOSE_RESULT=1
dr_run yes true
assert_eq "docker builder prune -a --force|" "$dr_mut" "only the build-cache purge verb runs when images are unavailable"
assert_contains "$dr_out" "docker residue: nothing elected (images unavailable: compose config failed" "says why nothing was elected"
DR_COMPOSE_RESULT=0

# --- anonymous dangling volumes -------------------------------------------

echo "[docker-residue] anonymous volumes: capture and classification"
DR_VOLUMES_JSON='[{"Name":"anon-a","Size":"2MB","Links":"0","Labels":"com.docker.volume.anonymous="},{"Name":"anon-b","Size":"3MB","Links":"0","Labels":"com.example.x=1,com.docker.volume.anonymous="},{"Name":"anon-linked","Size":"1MB","Links":"1","Labels":"com.docker.volume.anonymous="},{"Name":"named-d","Size":"5MB","Links":"0","Labels":"com.docker.compose.project=p"},{"Name":"lookalike","Size":"1kB","Links":"0","Labels":"com.docker.volume.anonymous.not=1,x=com.docker.volume.anonymous"}]'
dr_rows=$(docker_residue_capture | docker_residue_classify)
assert_eq $'anonvolume	anon-b	3000000
anonvolume	anon-a	2000000' "$(grep '^anonvolume' <<< "$dr_rows")" "only zero-link volumes carrying the anonymous label key (first or not) are anonvolume rows"
assert_contains "$dr_rows" $'volume	named-d	5000000	0	dangling' "a named dangling volume keeps its volume row"
assert_contains "$dr_rows" $'volume	anon-linked	1000000	1	linked' "a linked anonymous volume is a plain linked volume row"
dr_report=$(docker_residue_report <<< "$dr_rows")
assert_contains "$dr_report" "docker anonymous volumes: 2 dangling, 4.8MB (5000000 bytes) (purge tier, removed by name)" "the report prints the anonymous volumes line"
assert_contains "$dr_report" "docker volumes: 5 (4 dangling" "the volumes line still counts every volume"
assert_contains "$dr_report" "2 named dangling: report-only, no verb" "named dangling volumes say they are report-only"
assert_not_contains "$dr_report" "never removes volumes" "the volumes line no longer claims no volume is ever removed"
dr_report=$(printf 'unavailable\tvolumes\tdocker system df -v failed\n' | docker_residue_report)
assert_contains "$dr_report" "docker anonymous volumes: unavailable (docker system df -v failed)" "volumes unavailable: the anonymous line claims no count"

echo "[docker-residue] anonymous volumes: election and removal"
dr_run yes false
assert_not_contains "$dr_mut" "volume rm" "plain --yes never removes a volume"
dr_run interactive false
assert_not_contains "$dr_conf" "anonymous" "plain interactive never offers the volume step"
assert_not_contains "$dr_mut" "volume rm" "plain interactive never removes a volume"
dr_run yes true
assert_contains "$dr_mut" "docker rm gone-x-1|docker volume rm anon-b|docker volume rm anon-a|docker rmi " "--yes --include-purge: stale rm, then volume rm per anonymous dangling name, then rmi"
assert_eq "2" "$(grep -o 'volume rm [^|]*' <<< "$dr_mut" | wc -l)" "exactly the anonymous dangling set is removed"
assert_not_contains "$dr_mut" "named-d" "a named dangling volume is never passed to volume rm"
assert_contains "$dr_out" "anonymous volumes removed 2, failed 0" "the summary counts volumes"
DR_CONFIRM_YES="anonymous dangling docker volumes"
dr_run interactive true
assert_contains "$dr_conf" "Remove 2 anonymous dangling docker volumes (4.8MB)? (purge tier)" "interactive --include-purge: one confirm naming count and size"
assert_eq "docker volume rm anon-b|docker volume rm anon-a|" "$dr_mut" "a yes on the volume confirm removes exactly the anonymous set"
DR_CONFIRM_YES=""

echo "[docker-residue] a volume orphaned by this run's stale removal waits"
DR_VOLUMES_AFTER_RM_JSON='[{"Name":"anon-a","Size":"2MB","Links":"0","Labels":"com.docker.volume.anonymous="},{"Name":"anon-linked","Size":"1MB","Links":"0","Labels":"com.docker.volume.anonymous="}]'
dr_run yes true
assert_contains "$dr_mut" "docker volume rm anon-a|" "a volume dangling before and after is removed"
assert_not_contains "$dr_mut" "anon-linked" "a volume dangling only after the stale rm is not removed this run"
assert_not_contains "$dr_mut" "anon-b" "a volume gone from the fresh capture is not removed"
DR_VOLUMES_AFTER_RM_JSON=""

echo "[docker-residue] a per-item volume rm failure warns and the run continues"
dr_run yes true
DOCKER_RM_FAIL_TARGET="anon-b"
dr_out=$(process_runtime docker 2>&1; printf '\nMUTATE=%s' "$MUTATE_LOG")
dr_banned_log+="${dr_out##*MUTATE=}"
assert_contains "$dr_out" "could not remove volume anon-b" "the failing volume is warned about"
assert_contains "$dr_out" "docker volume rm anon-a|" "the next volume is still removed"
assert_contains "$dr_out" "anonymous volumes removed 1, failed 1" "the summary counts the failure"
DOCKER_RM_FAIL_TARGET=""

echo "[docker-residue] volumes unavailable elects no volume"
DR_VOLUMES_FAIL=1
dr_run yes true
assert_not_contains "$dr_mut" "volume rm" "no volume is removed when the volume capture fails"
DR_VOLUMES_FAIL=0

echo "[docker-residue] the footprint line includes volumes"
DR_DF_JSON=$'{"Type":"Images","Size":"40B"}\n{"Type":"Containers","Size":"1kB"}'
dr_run yes true
assert_contains "$dr_out" "docker images/containers/volumes: observed footprint change unavailable" "a missing Local Volumes row makes the footprint unavailable"
DR_DF_JSON=$'{"Type":"Images","Size":"40B"}\n{"Type":"Containers","Size":"1kB"}\n{"Type":"Local Volumes","Size":"5MB"}'
DR_VOLUMES_JSON='[{"Name":"orphan-vol","Size":"43.35MB","Links":"0"}]'

echo "[docker-residue] banned verbs never appear in any mode"
dr_banned=""
for dr_verb in "system prune" "image prune" "volume prune" "volume rm -f" "volume rm --force" "rmi -f" "rmi --force" "rm -f" "rm --force"; do
    [[ "$dr_banned_log" == *"$dr_verb"* ]] && dr_banned+="$dr_verb;"
done
assert_eq "" "$dr_banned" "no prune/forced verb in MUTATE_LOG across every mode"
dr_bad_vol=$(grep -o 'volume rm [^|]*' <<< "$dr_banned_log" | grep -vxE 'volume rm (anon-a|anon-b)' || true)
assert_eq "" "$dr_bad_vol" "every volume rm names an elected anonymous volume"

# The residue delta goes through probe_compare: before minus after, so a
# freed footprint prints positive (F1, 2026-10-23 review -- it printed
# after minus before). Footprints are scripted per call; each run is a
# subshell so the stubs never leak.
dr_delta_run() {
    (
        DR_FP_SEQ="$1"
        DR_FP_FILE="$SANDBOX/dr-fp-calls"
        : > "$DR_FP_FILE"
        docker_residue_perl_reason() { :; }
        docker_residue_capture() { echo '{}'; }
        docker_residue_classify() { printf 'stale\tgone-x-1\n'; }
        docker_residue_footprint() {
            local n v
            n=$(wc -l < "$DR_FP_FILE"); echo x >> "$DR_FP_FILE"
            read -r -a v <<< "$DR_FP_SEQ"
            [[ "${v[$n]}" == fail ]] && return 1
            printf '%s\n' "${v[$n]}"
        }
        docker() { :; }
        MODE=yes INCLUDE_PURGE=true RUNTIME_ACTED=false
        rt_docker_residue
        printf 'ACTED=%s\n' "$RUNTIME_ACTED"
    ) 2>&1
}

echo "[docker-residue] a freed footprint prints a positive delta"
dr_d=$(dr_delta_run "1000 400")
assert_contains "$dr_d" "docker images/containers/volumes: observed footprint change 600.0B (600 bytes)" "1000 -> 400 reports 600 bytes freed, positive"
assert_contains "$dr_d" "ACTED=true" "an acting residue step records it in RUNTIME_ACTED"

echo "[docker-residue] pre-probe failure: delta unavailable"
dr_d=$(dr_delta_run "fail 400")
assert_contains "$dr_d" "docker images/containers/volumes: observed footprint change unavailable (docker system df --format json reading failed)" "a failed pre-probe prints the unavailable line"

echo "[docker-residue] post-probe failure: delta unavailable"
dr_d=$(dr_delta_run "1000 fail")
assert_contains "$dr_d" "docker images/containers/volumes: observed footprint change unavailable (docker system df --format json reading failed)" "a failed post-probe prints the unavailable line"

echo "[docker-residue] a large image list (> 128 KiB of JSON) captures: no argv limit"
DR_IMAGES_JSON=$(perl -MJSON::PP -e 'print encode_json([map { {Id => sprintf("sha256:%064x", $_), RepoTags => ["bulk/image-$_:v1"], Created => "2026-01-01T00:00:00Z", Size => $_} } 1 .. 2500])')
DR_CONTAINERS_JSON='[]'
DR_COMPOSE_RESULT=0
dr_big=$(docker_residue_capture)
assert_eq "true" "$([[ ${#DR_IMAGES_JSON} -gt 131072 ]] && echo true || echo false)" "the fixture image list exceeds 128 KiB"
assert_eq "2500" "$(perl -MJSON::PP -e 'print scalar @{decode_json(join "", <STDIN>)->{images}}' <<< "$dr_big")" "every image of an oversized list is captured"
assert_eq "null" "$(dr_capture_field image_error <<< "$dr_big")" "an oversized list is no image_error"

eval "$DR_ORIGINAL_CONFIRM"

eval "$DR_ORIGINAL_DOCKER"
eval "$DR_ORIGINAL_CAPTURE"
unset -f dr_harness_docker dr_prod_docker_residue_capture dr_sync dr_capture_build dr_capture_field
export CACHE_PRUNE_REPO_ROOT="$SANDBOX/empty-fleet-root"
DR_COMPOSE_RESULT=0
reset_logs
