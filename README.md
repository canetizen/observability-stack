# Single-Container Observability Stack

This project packages Grafana, Loki, Tempo, Mimir, Jaeger, and the OpenTelemetry Collector into one Docker image and runs them as processes in one container. The Collector accepts OTLP/gRPC on port 4317 and OTLP/HTTP on port 4318. It sends traces to both Tempo and Jaeger, metrics to Mimir, and logs to Loki.

The stack is intended for local evaluation and air-gapped installation. Services use local filesystem storage under `./data`; the Jaeger all-in-one backend uses in-memory trace storage. The default Grafana password is `admin`, so set a different `GRAFANA_ADMIN_PASSWORD` before exposing Grafana beyond localhost. The published ports bind to localhost by default.

## Package on an internet-connected machine

Docker must be available. The build downloads the pinned upstream service images and combines their executables into one image.

```bash
./run.sh package ./observability-stack.tar
```

Copy the archive and this project directory to the air-gapped host. No upstream images are pulled when starting the packaged image.

## Load and run on the air-gapped host

```bash
./run.sh load-run ./observability-stack.tar
./run.sh verify
```

Open Grafana at `http://localhost:3000` and Jaeger at `http://localhost:16686`. Grafana credentials default to `admin` / `admin`; set the password on launch:

```bash
GRAFANA_ADMIN_PASSWORD='choose-a-password' ./run.sh load-run ./observability-stack.tar
```

The `load-run` and `start` commands replace any existing container with the configured name but preserve data in `./data`. Set `OBSERVABILITY_CONTAINER` or `OBSERVABILITY_DATA_DIR` to use different names or storage locations.

OTLP ports bind to localhost by default. To accept SDK traffic from another host, set `OBSERVABILITY_OTLP_BIND_ADDRESS=0.0.0.0` when running `load-run` or `start`, and restrict access with the host firewall; the OTLP endpoints do not enable TLS or authentication.

## Generate example signals

The Java 17+ example uses the OpenTelemetry SDK directly. It exports a request counter, an active-request up/down counter, a request-duration histogram, spans, and multiline JSON log records containing W3C `traceparent`.

```bash
mvn -f examples/java/pom.xml compile exec:java
```

Set `OTEL_EXPORTER_OTLP_ENDPOINT` to change the default `http://localhost:4317` endpoint. After a few export intervals, run `./run.sh verify`; it checks service readiness and reports whether the example's `demo_requests_total` metric has reached Mimir.

In Grafana, open **Metrics & Logs Overview** to discover metric names from Mimir, inspect raw samples for a selected metric, and view the stack's complete log stream. The dashboard does not assume application metric names or types. Open **Logs & Traces Explorer** for the same generic log stream and a trace detail view. Select a log's derived TraceID link to open the corresponding Jaeger trace; the dashboard's Trace ID field also accepts the 32-hex trace ID extracted from a W3C `traceparent` value. Jaeger service search is available in Explore, where Grafana queries its service list dynamically.

For uniform log discovery, the Collector adds its own `observability.stack_scope=lgtm` resource attribute to every received log and Loki indexes it. This is stack metadata, not an application label requirement. Trace-to-log queries match the W3C trace ID as text in the log body, so the application's JSON property names are otherwise unconstrained.

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

The `./data` directory persists Loki, Tempo, Mimir, and Grafana state across container restarts. Jaeger uses its default in-memory storage and loses its traces when the container stops.