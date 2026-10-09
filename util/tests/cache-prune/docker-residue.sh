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
            printf 'sha256:old\nsha256:overlay\n'
            ;;
        image\ inspect*)
            printf 'docker %s|' "$*" >> "$ALL_LOG_FILE"
            printf '[{"Id":"sha256:old","RepoTags":["webapp-overlay:v0.11.3"],"Created":"2026-01-01T00:00:00Z","Size":5},{"Id":"sha256:overlay","RepoTags":["webapp-overlay:v0.11.4"],"Created":"2026-09-01T00:00:00Z","Size":7}]\n'
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

eval "$DR_ORIGINAL_DOCKER"
unset -f dr_harness_docker
export CACHE_PRUNE_REPO_ROOT="$SANDBOX/empty-fleet-root"
DR_COMPOSE_RESULT=0
reset_logs
