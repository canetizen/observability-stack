# Single-Container Observability Stack

This project packages Grafana 13.2.0, Loki, Tempo, Mimir, Jaeger, the OpenTelemetry Collector, and Grafana Logs, Metrics, and Traces Drilldown apps into one Docker image. All services run in one container. The Collector accepts OTLP/gRPC on port 4317 and OTLP/HTTP on port 4318, sends traces to both Tempo and Jaeger, metrics to Mimir, and OTLP logs to Loki. Drilldown plugin archives are downloaded during the online image build and included in the exported tar, so Grafana does not need internet access after installation.

The stack is intended for air-gapped installation and runs with Docker host networking. Services use local filesystem storage under `./data`; the Jaeger all-in-one backend uses in-memory trace storage. The default Grafana password is `admin`; set a strong `GRAFANA_ADMIN_PASSWORD` before starting the container.

## Package on an internet-connected machine

Docker must be available. The build downloads the pinned upstream service images and the pinned Grafana plugin versions, then combines them into one image.

```bash
./run.sh package ./observability-stack.tar
```

Copy the archive, `run.sh`, and the directory containing the logs to the air-gapped host. The tar contains Grafana and all three Drilldown apps; startup performs no image or plugin downloads.

## Load and run on the air-gapped host

```bash
./run.sh load-run ./observability-stack.tar /path/to/application/logs
./run.sh verify
```

The log directory must exist and contain the `.log` files directly inside it. The script mounts it read-only at `/var/log/observability`; the Collector tails `*.log` files and treats each line as one JSON record. New content and new files are followed as they appear.

Records are expected to carry `time`, `timeUnixNano`, `severityText`, and `severityNumber`. `timeUnixNano` (integer or numeric string) becomes the OTLP log timestamp, and `severityNumber`/`severityText` become the OTLP severity, so they should follow the OpenTelemetry severity scale. A record missing these fields is still ingested, with the Collector's read time and no severity. Records emitted inside a trace also carry `trace_id`, `span_id`, and a W3C `traceparent`; the Collector sets the OTLP trace context from them. Records without these fields are ingested without trace correlation. All JSON fields are kept as log attributes, nested objects flattened (`{"user":{"id":1}}` becomes `user_id`). Lines that are not JSON are ingested as plain text, and the Collector logs a parse error for each. File logs carry the `log_file_name` attribute; they have no `service.name`, so Loki groups them under `service_name=unknown_service`. Existing contents are read on first start, and file offsets are persisted under `./data/otelcol` to avoid replay after restart. The directory is not recursive.

Open Grafana at `http://localhost:3000` and Jaeger at `http://localhost:16686`. The Drilldown apps are listed under **Drilldown** (`/drilldown`) and open at `/a/grafana-lokiexplore-app/explore` (Logs), `/a/grafana-metricsdrilldown-app/drilldown` (Metrics), and `/a/grafana-exploretraces-app/` (Traces). The `/plugins/<id>/page/<slug>` URLs reported as `defaultNavUrl` by Grafana's plugin API are not routable in Grafana 13.2. Grafana credentials default to `admin` / `admin`; set the password on launch:

```bash
GRAFANA_ADMIN_PASSWORD='choose-a-password' ./run.sh load-run ./observability-stack.tar /path/to/application/logs
```

The `start` command uses the already-loaded image and takes the same log directory argument:

```bash
./run.sh start /path/to/application/logs
```

Both `load-run` and `start` replace any existing container with the configured name but preserve data in `./data`. Set `OBSERVABILITY_CONTAINER` or `OBSERVABILITY_DATA_DIR` to use different names or storage locations.

Host networking means Docker port publishing is not used. All service ports bind directly on the host network, so ensure they are free and restrict access with the host firewall. OTLP and backend APIs do not enable TLS or authentication by default. Grafana, Loki, Tempo, Mimir, Jaeger, and Collector listener ports may be reachable from other machines depending on host firewall rules.

## Generate example signals

The Java 17+ example uses the OpenTelemetry SDK directly. It exports a request counter, an active-request up/down counter, a request-duration histogram, spans, and multiline JSON log records containing a top-level W3C `traceparent` field. File ingestion and OTLP ingestion both export to Loki. The file receiver parses each single-line JSON record as described above and leaves the JSON record as the log body.

For a file-ingestion smoke test, pass the included fixture directory. The fixtures carry fixed timestamps from 2026-11-26, so Loki rejects them once they are older than 7 days; use records with current timestamps after that:

```bash
./run.sh start examples/logs
```

```bash
mvn -f examples/java/pom.xml compile exec:java
```

Set `OTEL_EXPORTER_OTLP_ENDPOINT` to change the default `http://localhost:4317` endpoint. After a few export intervals, run `./run.sh verify`; it checks service readiness and reports whether the example's `demo_requests_total` metric has reached Mimir.

In Grafana, open **Metrics & Logs Overview** to discover metric names from Mimir, inspect raw samples for a selected metric, and view the stack's complete log stream. The dashboard does not assume application metric names or types. Open **Logs & Traces Explorer** for the same generic log stream and a trace detail view. Select a log's derived TraceID link to open the corresponding Jaeger trace; the dashboard's Trace ID field also accepts a 32-hex trace ID, such as the one in a W3C `traceparent` value. Jaeger service search is available in Explore, where Grafana queries its service list dynamically.

For uniform log discovery, the Collector adds its own `observability.stack_scope=lgtm` resource attribute to every received log and Loki indexes it. This is stack metadata, not an application label requirement. Log-to-trace links and trace-to-log queries use the `trace_id` that Loki stores for each log record from its OTLP trace context, so they work for file logs and for OTLP logs from any SDK without requiring trace IDs in the log body.

Loki rejects records whose timestamp is older than 7 days or more than 10 minutes in the future (Loki defaults), and records with more than 1024 attributes (JSON fields after flattening, plus resource and trace metadata) or 256KB of attribute data; rejected records are dropped and logged by the Collector.

## Ports and persistence

| Host port | Service |
| --- | --- |
| 3000 | Grafana |
| 3100 | Loki API |
| 3200 | Tempo API |
| 4317 | OTLP/gRPC receiver |
| 4318 | OTLP/HTTP receiver |
| 9009 | Mimir API |
| 16686 | Jaeger UI |

With host networking these ports are bound directly on the host; Docker `-p` mappings and their localhost-only isolation do not apply. Loki, Mimir, Tempo, and Jaeger also have internal gRPC listeners on ports 9097, 9095, 9096, and 16685 respectively.

Tempo's internal OTLP/HTTP receiver uses loopback port 14320 to avoid colliding with other host services; applications should send OTLP to the Collector ports 4317/4318 instead.

The `./data` directory persists Loki, Tempo, Mimir, Grafana state, and Collector file offsets across container restarts. Jaeger uses its default in-memory storage and loses its traces when the container stops. Grafana 13.2 may migrate the existing Grafana database the first time this image starts; keep a backup of `./data` before upgrading from an earlier Grafana version.