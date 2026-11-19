/*
 * Description: Emits sample OpenTelemetry metrics, traces, and trace-correlated JSON logs.
 * Created by: Mustafa Can Caliskan
 * Date: 2026-11-19
 */
package local.observability;

import io.opentelemetry.api.OpenTelemetry;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.logs.Logger;
import io.opentelemetry.api.logs.Severity;
import io.opentelemetry.api.metrics.DoubleHistogram;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.LongUpDownCounter;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.api.trace.propagation.W3CTraceContextPropagator;
import io.opentelemetry.context.propagation.ContextPropagators;
import io.opentelemetry.exporter.otlp.logs.OtlpGrpcLogRecordExporter;
import io.opentelemetry.exporter.otlp.metrics.OtlpGrpcMetricExporter;
import io.opentelemetry.exporter.otlp.trace.OtlpGrpcSpanExporter;
import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.logs.SdkLoggerProvider;
import io.opentelemetry.sdk.logs.export.BatchLogRecordProcessor;
import io.opentelemetry.sdk.metrics.SdkMeterProvider;
import io.opentelemetry.sdk.metrics.export.PeriodicMetricReader;
import io.opentelemetry.sdk.resources.Resource;
import io.opentelemetry.sdk.trace.SdkTracerProvider;
import io.opentelemetry.sdk.trace.export.BatchSpanProcessor;

import java.time.Duration;
import java.util.List;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.TimeUnit;

/**
 * Generates a small continuous workload so backend ingestion and Grafana panels can be checked.
 */
public final class DemoApplication {
    private static final String SERVICE_NAME = "otel-java-demo";
    private static final AttributeKey<String> ROUTE = AttributeKey.stringKey("http.route");
    private static final Attributes REQUEST_ATTRIBUTES = Attributes.of(ROUTE, "/checkout");

    private DemoApplication() {
    }

    /**
     * Starts the demo workload and exports all three signal types over OTLP/gRPC.
     *
     * @param args unused command-line arguments
     * @throws InterruptedException if the workload thread is interrupted
     */
    public static void main(String[] args) throws InterruptedException {
        String endpoint = System.getenv().getOrDefault("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317");
        Resource resource = Resource.getDefault().toBuilder()
                .put(AttributeKey.stringKey("service.name"), SERVICE_NAME)
                .put(AttributeKey.stringKey("deployment.environment"), "demo")
                .build();

        SdkMeterProvider meterProvider = SdkMeterProvider.builder()
                .setResource(resource)
                .registerMetricReader(PeriodicMetricReader.builder(
                        OtlpGrpcMetricExporter.builder().setEndpoint(endpoint).build())
                        .setInterval(Duration.ofSeconds(5))
                        .build())
                .build();
        SdkTracerProvider tracerProvider = SdkTracerProvider.builder()
                .setResource(resource)
                .addSpanProcessor(BatchSpanProcessor.builder(
                        OtlpGrpcSpanExporter.builder().setEndpoint(endpoint).build()).build())
                .build();
        SdkLoggerProvider loggerProvider = SdkLoggerProvider.builder()
                .setResource(resource)
                .addLogRecordProcessor(BatchLogRecordProcessor.builder(
                        OtlpGrpcLogRecordExporter.builder().setEndpoint(endpoint).build()).build())
                .build();

        OpenTelemetry telemetry = OpenTelemetrySdk.builder()
                .setMeterProvider(meterProvider)
                .setTracerProvider(tracerProvider)
                .setLoggerProvider(loggerProvider)
                .setPropagators(ContextPropagators.create(W3CTraceContextPropagator.getInstance()))
                .build();

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            loggerProvider.close();
            tracerProvider.close();
            meterProvider.close();
        }, "otel-shutdown"));

        runWorkload(telemetry);
    }

    private static void runWorkload(OpenTelemetry telemetry) throws InterruptedException {
        Tracer tracer = telemetry.getTracer(SERVICE_NAME);
        Logger logger = telemetry.getLogsBridge().get(SERVICE_NAME);
        var meter = telemetry.getMeter(SERVICE_NAME);
        LongCounter requests = meter.counterBuilder("demo.requests")
                .setDescription("Number of simulated checkout requests")
                .setUnit("{request}")
                .build();
        LongUpDownCounter activeRequests = meter.upDownCounterBuilder("demo.active_requests")
                .setDescription("Number of checkout requests currently in progress")
                .setUnit("{request}")
                .build();
        DoubleHistogram requestDuration = meter.histogramBuilder("demo.request.duration")
                .setDescription("Duration of simulated checkout requests")
                .setUnit("s")
                .setExplicitBucketBoundariesAdvice(List.of(0.05, 0.1, 0.25, 0.5, 0.75, 1.0))
                .build();

        System.out.printf("Sending OTLP signals to %s; stop with Ctrl+C.%n", System.getenv()
                .getOrDefault("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317"));
        while (!Thread.currentThread().isInterrupted()) {
            activeRequests.add(1, REQUEST_ATTRIBUTES);
            Span span = tracer.spanBuilder("POST /checkout").startSpan();
            long startNanos = System.nanoTime();
            try (var scope = span.makeCurrent()) {
                span.setAttribute("http.request.method", "POST");
                span.setAttribute("http.route", "/checkout");
                TimeUnit.MILLISECONDS.sleep(ThreadLocalRandom.current().nextLong(150, 750));
                requests.add(1, REQUEST_ATTRIBUTES);
                emitJsonLog(logger, span);
            } catch (InterruptedException exception) {
                Thread.currentThread().interrupt();
            } finally {
                requestDuration.record((System.nanoTime() - startNanos) / 1_000_000_000.0, REQUEST_ATTRIBUTES);
                activeRequests.add(-1, REQUEST_ATTRIBUTES);
                span.end();
            }
            TimeUnit.MILLISECONDS.sleep(500);
        }
    }

    private static void emitJsonLog(Logger logger, Span span) {
        String traceId = span.getSpanContext().getTraceId();
        String spanId = span.getSpanContext().getSpanId();
        String traceparent = "00-" + traceId + "-" + spanId + "-01";
        String body = "{\n"
                + "  \"event\": \"checkout.completed\",\n"
                + "  \"service\": \"" + SERVICE_NAME + "\",\n"
                + "  \"trace_id\": \"" + traceId + "\",\n"
                + "  \"span_id\": \"" + spanId + "\",\n"
                + "  \"traceparent\": \"" + traceparent + "\",\n"
                + "  \"result\": \"success\"\n"
                + "}";
        logger.logRecordBuilder()
                .setSeverity(Severity.INFO)
                .setBody(body)
                .setAttribute(ROUTE, "/checkout")
                .emit();
    }
}