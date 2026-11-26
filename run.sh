#!/usr/bin/env bash
#
# Description: Builds, exports, loads, and runs the single-container observability stack.
# Created by: Mustafa Can Caliskan
# Date: 2026-11-19

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${OBSERVABILITY_IMAGE:-local/observability-stack:1.1.0}"
CONTAINER="${OBSERVABILITY_CONTAINER:-observability-stack}"
DATA_DIR="${OBSERVABILITY_DATA_DIR:-$SCRIPT_DIR/data}"

usage() {
    printf 'Usage:\n  %s package [image.tar]\n  %s load-run <image.tar> <log-directory>\n  %s start <log-directory>\n  %s stop|status|verify\n' "$0" "$0" "$0" "$0"
}

run_container() {
    local log_directory="$1"
    if [[ ! -d "$log_directory" ]]; then
        printf 'Log directory does not exist: %s\n' "$log_directory" >&2
        return 2
    fi
    log_directory="$(cd -- "$log_directory" && pwd -P)"
    mkdir -p "$DATA_DIR"
    if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
        docker rm -f "$CONTAINER" >/dev/null
    fi
    docker run -d \
        --name "$CONTAINER" \
        --network host \
        --restart unless-stopped \
        -e "GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:-admin}" \
        -v "$DATA_DIR:/data" \
        --mount "type=bind,src=${log_directory},dst=/var/log/observability,readonly" \
        "$IMAGE"
    printf 'Grafana: http://localhost:3000 (admin / configured password)\n'
    printf 'Jaeger:  http://localhost:16686\n'
    printf 'OTLP:    localhost:4317 (gRPC), localhost:4318 (HTTP)\n'
    printf 'File logs: %s/*.log (mounted read-only)\n' "$log_directory"
}

verify_stack() {
    local attempt
    for attempt in {1..30}; do
        if curl --fail --silent http://127.0.0.1:3000/api/health >/dev/null \
            && curl --fail --silent http://127.0.0.1:16686/ >/dev/null \
            && curl --fail --silent http://127.0.0.1:3100/ready >/dev/null \
            && curl --fail --silent http://127.0.0.1:3200/ready >/dev/null \
            && curl --fail --silent http://127.0.0.1:9009/ready >/dev/null; then
            printf 'Grafana, Jaeger, Loki, Tempo, and Mimir are ready.\n'
            if curl --fail --silent --get --data-urlencode 'query=demo_requests_total' \
                http://127.0.0.1:9009/prometheus/api/v1/query \
                | grep -Eq '"result":[[:space:]]*\[[[:space:]]*\{'; then
                printf 'Demo metric demo_requests_total is present in Mimir.\n'
            else
                printf 'Stack is healthy; start examples/java to generate the demo signals.\n'
            fi
            return 0
        fi
        sleep 2
    done
    printf 'Stack did not become ready. Inspect logs with: docker logs %s\n' "$CONTAINER" >&2
    return 1
}

command="${1:-}"
case "$command" in
    package)
        archive="${2:-$SCRIPT_DIR/observability-stack.tar}"
        docker build -t "$IMAGE" "$SCRIPT_DIR"
        mkdir -p "$(dirname -- "$archive")"
        docker save --output "$archive" "$IMAGE"
        printf 'Saved %s to %s\n' "$IMAGE" "$archive"
        ;;
    load-run)
        if [[ $# -ne 3 ]]; then
            usage
            exit 2
        fi
        docker load --input "$2"
        run_container "$3"
        ;;
    start)
        if [[ $# -ne 2 ]]; then
            usage
            exit 2
        fi
        if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
            printf 'Image %s is not loaded. Run package or load-run first.\n' "$IMAGE" >&2
            exit 1
        fi
        run_container "$2"
        ;;
    stop)
        docker stop "$CONTAINER"
        ;;
    status)
        docker ps --filter "name=^/${CONTAINER}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
        ;;
    verify)
        command -v curl >/dev/null || { printf 'curl is required for verification.\n' >&2; exit 1; }
        verify_stack
        ;;
    *)
        usage
        exit 2
        ;;
esac