#!/usr/bin/env bash
#
# Description: Starts and supervises all observability services in one container.
# Created by: Mustafa Can Caliskan
# Date: 2026-11-19

set -Eeuo pipefail

process_ids=()

start_service() {
    "$@" &
    process_ids+=("$!")
}

stop_services() {
    trap - INT TERM
    if ((${#process_ids[@]})); then
        kill "${process_ids[@]}" 2>/dev/null || true
        wait "${process_ids[@]}" 2>/dev/null || true
    fi
}

trap stop_services INT TERM EXIT

mkdir -p /data/grafana /data/loki /data/tempo /data/mimir /data/jaeger /data/otelcol/storage

start_service /usr/local/bin/mimir -config.file=/etc/observability/mimir.yaml -target=all
start_service /usr/local/bin/loki -config.file=/etc/observability/loki.yaml
start_service /usr/local/bin/tempo -config.file=/etc/observability/tempo.yaml
start_service /usr/local/bin/jaeger-all-in-one \
    --collector.otlp.grpc.host-port=127.0.0.1:14317 \
    --collector.otlp.http.host-port=127.0.0.1:14318
start_service env \
    GF_PATHS_CONFIG=/etc/observability/grafana.ini \
    GF_PATHS_DATA=/data/grafana \
    GF_PATHS_LOGS=/data/grafana/logs \
    GF_PATHS_PLUGINS=/usr/share/grafana/plugins-baked \
    GF_PATHS_PROVISIONING=/etc/observability/grafana/provisioning \
    /usr/share/grafana/bin/grafana server --homepath=/usr/share/grafana --config=/etc/observability/grafana.ini
start_service /usr/local/bin/otelcol-contrib --config=/etc/observability/collector.yaml

set +e
wait -n "${process_ids[@]}"
exit_code=$?
set -e
printf 'An observability service exited; stopping the container (exit code %s).\n' "$exit_code" >&2
exit "$exit_code"