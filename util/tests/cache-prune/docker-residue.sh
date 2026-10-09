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

assert_eq "superseded" "$(dr_class_of context-control-cameras:wp2)" "an older work tag of a live repository (offset timestamps) is superseded"
assert_eq "superseded" "$(dr_class_of llama-vulkan:b10121)" "an older tag of the compose-pinned llama repository is superseded"
assert_eq "unreferenced" "$(dr_class_of llama-vulkan:b11429-swap243)" "a tag newer than its live sibling is unreferenced, never superseded"
assert_eq "" "$(dr_class_of llama-vulkan:b10534-swap243)" "the compose-pinned tag is live"
assert_eq "" "$(dr_class_of context-control-cameras:latest)" "the implied <project>-<service>:latest of a build-only service is live"
assert_eq "" "$(dr_class_of searxng/searxng:2026.8.22-9fea41204)" "a docker.io/-prefixed compose ref matches the unprefixed local tag"
assert_eq "" "$(dr_class_of ghcr.io/example/homehub:2026.9.4)" "a profiled service's image is live"
assert_eq "" "$(dr_class_of ghcr.io/example/webapp:v0.11.4-slim)$(dr_class_of alpine:latest)" "Dockerfile base refs (incl. implicit :latest) protect their images"
assert_eq "" "$(awk -F'\t' '$1 == "stale" && $2 == "engine-svc-tts"' <<< "$dr_rows")" "an exited container of a live compose service is not stale"
assert_eq "" "$(dr_class_of engine-svc-tts:torch2.11-rocm7.2)" "the image of a live service's exited container is live"
assert_contains "$dr_rows" $'stale\tlegacy_project-old-1\tsha256:prerename0000\t1000\t' "a pre-rename project's exited container is stale, with its writable-layer bytes"
assert_contains "$dr_rows" $'unreferenced\tlegacy_project-legacy-project:latest\tsha256:prerename0000\t384300000\t2026-07-09T00:00:00Z\tlegacy_project-old-1' "an image held only by a stale container is a candidate naming its blocker"
assert_contains "$dr_rows" $'volume\tcontext-control_radar-data\t4300000000\t0\tdangling' "a zero-link volume is flagged dangling"

echo "[docker-residue] Dockerfile base-ref resolution"
assert_eq "ghcr.io/example/webapp:v0.11.4-slim" "$(docker_residue_dockerfile_bases "$DR_FIX/Dockerfile.overlay")" "ARG default feeds FROM \${ARG}"
assert_eq "example/upstream:9" "$(docker_residue_dockerfile_bases "$DR_FIX/Dockerfile.overlay" '{"UPSTREAM":"example/upstream:9"}')" "a compose build arg overrides the ARG default"
assert_eq $'golang:1.26.7-trixie\nalpine:latest' "$(docker_residue_dockerfile_bases "$DR_FIX/Dockerfile.multistage")" "stage names and scratch are never image refs; --platform is skipped"
assert_failure "an unresolvable FROM variable fails closed" docker_residue_dockerfile_bases "$DR_FIX/Dockerfile.unresolved"

# --- capture path, against a fixture-serving docker double -----------------

DR_ROOT="$SANDBOX/docker-residue-root"
mkdir -p "$DR_ROOT/context-control"
: > "$DR_ROOT/context-control/compose.yml"
DR_COMPOSE_JSON=$(sed "s|@FIXTURES@|$DR_FIX|g" "$DR_FIX/compose-config.json")
DR_COMPOSE_RESULT=0
DR_IMAGES_JSON='[{"Id":"sha256:old","RepoTags":["webapp-overlay:v0.11.3"],"Created":"2026-01-01T00:00:00Z","Size":5},{"Id":"sha256:overlay","RepoTags":["webapp-overlay:v0.11.4"],"Created":"2026-09-01T00:00:00Z","Size":7}]'
DR_CONTAINERS_JSON='[]'
DR_DF_JSON=""
DR_ORIGINAL_DOCKER="$(declare -f docker)"
eval "dr_harness_$(declare -f docker)"
docker() {
    case "$*" in
        "system df -v --format json")
            printf 'docker %s|' "$*" >> "$ALL_LOG_FILE"
            printf '{"Volumes":[{"Name":"orphan-vol","Size":"43.35MB","Links":"0"}]}\n'
            ;;
        "compose version")
            printf 'docker %s|' "$*" >> "$ALL_LOG_FILE"
            ;;
        compose\ -f\ *)
            printf 'docker %s|' "$*" >> "$ALL_LOG_FILE"
            ((DR_COMPOSE_RESULT == 0)) || return 1
            printf '%s\n' "$DR_COMPOSE_JSON"
            ;;
        "images -q --no-trunc")
            printf 'docker %s|' "$*" >> "$ALL_LOG_FILE"
            jq -r '.[].Id' <<< "$DR_IMAGES_JSON"
            ;;
        image\ inspect*)
            printf 'docker %s|' "$*" >> "$ALL_LOG_FILE"
            printf '%s\n' "$DR_IMAGES_JSON"
            ;;
        "ps -aq --no-trunc")
            printf 'docker %s|' "$*" >> "$ALL_LOG_FILE"
            jq -r '.[].Id' <<< "$DR_CONTAINERS_JSON"
            ;;
        ps\ -a\ --size*)
            printf 'docker %s|' "$*" >> "$ALL_LOG_FILE"
            jq -c '.[] | {id: .Id, size: "1kB"}' <<< "$DR_CONTAINERS_JSON"
            ;;
        container\ inspect*)
            printf 'docker %s|' "$*" >> "$ALL_LOG_FILE"
            printf '%s\n' "$DR_CONTAINERS_JSON"
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
dr_bad=$(jq -c '.images += [{id: "sha256:badts", tags: ["webapp-overlay:v0.0.1"], created: "not-a-date", size: 3}]' <<< '{"images":[{"id":"sha256:live","tags":["webapp-overlay:v0.11.4"],"created":"2026-09-01T00:00:00Z","size":7},{"id":"sha256:old2","tags":["dead:1"],"created":"2026-01-01T00:00:00Z","size":1},{"id":"sha256:liveb","tags":["dead:2"],"created":"garbage","size":1}],"containers":[],"compose":[{"project":"p","services":[{"name":"a","image":"webapp-overlay:v0.11.4","build":false},{"name":"b","image":"dead:2","build":false}]}],"base_refs":[],"volumes":[],"image_error":null,"volume_error":null}' | docker_residue_classify)
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
assert_contains "$dr_out" "docker images/containers: observed footprint change 0.0B" "the residue step prints its own measured footprint line"

echo "[docker-residue] --yes --include-purge: stale containers first"
dr_run yes true
assert_contains "$dr_mut" "docker builder prune --force|docker rm gone-x-1|docker rmi webapp-overlay:v0.11.1|docker rmi webapp-overlay:v0.11.3|" "builder prune, then stale rm, then superseded rmi"
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
assert_eq "docker builder prune --force|" "$dr_mut" "only the build-cache prune runs when images are unavailable"
assert_contains "$dr_out" "docker residue: nothing elected (images unavailable: compose config failed" "says why nothing was elected"
DR_COMPOSE_RESULT=0

echo "[docker-residue] banned verbs never appear in any mode"
dr_banned=""
for dr_verb in "system prune" "image prune" "volume prune" "volume rm" "rmi -f" "rmi --force" "rm -f" "rm --force"; do
    [[ "$dr_banned_log" == *"$dr_verb"* ]] && dr_banned+="$dr_verb;"
done
assert_eq "" "$dr_banned" "no prune/volume/forced verb in MUTATE_LOG across every mode"

eval "$DR_ORIGINAL_CONFIRM"

eval "$DR_ORIGINAL_DOCKER"
unset -f dr_harness_docker
export CACHE_PRUNE_REPO_ROOT="$SANDBOX/empty-fleet-root"
DR_COMPOSE_RESULT=0
reset_logs
