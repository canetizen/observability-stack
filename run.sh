#!/usr/bin/env bash
#
# Description: Builds, exports, loads, and runs the single-container observability stack.
# Created by: Mustafa Can Caliskan
# Date: 2026-11-19

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${OBSERVABILITY_IMAGE:-local/observability-stack:1.0.0}"
CONTAINER="${OBSERVABILITY_CONTAINER:-observability-stack}"
DATA_DIR="${OBSERVABILITY_DATA_DIR:-$SCRIPT_DIR/data}"
OTLP_BIND_ADDRESS="${OBSERVABILITY_OTLP_BIND_ADDRESS:-127.0.0.1}"

usage() {
    printf 'Usage:\n  %s package [image.tar]\n  %s load-run <image.tar>\n  %s start|stop|status|verify\n' "$0" "$0" "$0"
}

run_container() {
    mkdir -p "$DATA_DIR"
    if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
        docker rm -f "$CONTAINER" >/dev/null
    fi
    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        -p "127.0.0.1:${GRAFANA_PORT:-3000}:3000" \
        -p "127.0.0.1:${LOKI_PORT:-3100}:3100" \
        -p "127.0.0.1:${TEMPO_PORT:-3200}:3200" \
        -p "127.0.0.1:${MIMIR_PORT:-9009}:9009" \
        -p "${OTLP_BIND_ADDRESS}:${OTLP_GRPC_PORT:-4317}:4317" \
        -p "${OTLP_BIND_ADDRESS}:${OTLP_HTTP_PORT:-4318}:4318" \
        -p "127.0.0.1:${JAEGER_UI_PORT:-16686}:16686" \
        -e "GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:-admin}" \
        -v "$DATA_DIR:/data" \
        "$IMAGE"
    printf 'Grafana: http://localhost:%s (admin / configured password)\n' "${GRAFANA_PORT:-3000}"
    printf 'Jaeger:  http://localhost:%s\n' "${JAEGER_UI_PORT:-16686}"
}

verify_stack() {
    local grafana_port="${GRAFANA_PORT:-3000}"
    local jaeger_port="${JAEGER_UI_PORT:-16686}"
    local loki_port="${LOKI_PORT:-3100}"
    local tempo_port="${TEMPO_PORT:-3200}"
    local mimir_port="${MIMIR_PORT:-9009}"
    local attempt
    for attempt in {1..30}; do
        if curl --fail --silent "http://127.0.0.1:${grafana_port}/api/health" >/dev/null \
            && curl --fail --silent "http://127.0.0.1:${jaeger_port}/" >/dev/null \
            && curl --fail --silent "http://127.0.0.1:${loki_port}/ready" >/dev/null \
            && curl --fail --silent "http://127.0.0.1:${tempo_port}/ready" >/dev/null \
            && curl --fail --silent "http://127.0.0.1:${mimir_port}/ready" >/dev/null; then
            printf 'Grafana, Jaeger, Loki, Tempo, and Mimir are ready.\n'
            if curl --fail --silent --get --data-urlencode 'query=demo_requests_total' \
                "http://127.0.0.1:${mimir_port}/prometheus/api/v1/query" \
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
        if [[ $# -ne 2 ]]; then
            usage
            exit 2
        fi
        docker load --input "$2"
        run_container
        ;;
    start)
        if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
            printf 'Image %s is not loaded. Run package or load-run first.\n' "$IMAGE" >&2
            exit 1
        fi
        run_container
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