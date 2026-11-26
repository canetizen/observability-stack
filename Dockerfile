FROM grafana/grafana:13.2.0 AS grafana-plugins
USER root
RUN /usr/share/grafana/bin/grafana cli --homepath=/usr/share/grafana plugins install grafana-metricsdrilldown-app 3.0.0 \
    && /usr/share/grafana/bin/grafana cli --homepath=/usr/share/grafana plugins install grafana-lokiexplore-app 3.2.0 \
    && /usr/share/grafana/bin/grafana cli --homepath=/usr/share/grafana plugins install grafana-exploretraces-app 3.2.0
FROM grafana/loki:3.3.2 AS loki
FROM grafana/tempo:2.7.2 AS tempo
FROM grafana/mimir:2.15.0 AS mimir
FROM jaegertracing/all-in-one:1.65.0 AS jaeger
FROM otel/opentelemetry-collector-contrib:0.120.0 AS otelcol

FROM grafana/grafana:13.2.0
USER root

COPY --from=loki /usr/bin/loki /usr/local/bin/loki
COPY --from=tempo /tempo /usr/local/bin/tempo
COPY --from=mimir /bin/mimir /usr/local/bin/mimir
COPY --from=jaeger /go/bin/all-in-one-linux /usr/local/bin/jaeger-all-in-one
COPY --from=otelcol /otelcol-contrib /usr/local/bin/otelcol-contrib
COPY --from=grafana-plugins --chown=472:0 /var/lib/grafana/plugins /usr/share/grafana/plugins-baked

COPY docker/ /etc/observability/
COPY scripts/container-entrypoint.sh /usr/local/bin/container-entrypoint

RUN mkdir -p /data/loki /data/tempo /data/mimir /data/jaeger /data/otelcol/storage \
    && chmod +x /usr/local/bin/container-entrypoint \
    && chmod -R a+rwX /data

EXPOSE 3000 3100 3200 4317 4318 9009 14320 16686
VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/container-entrypoint"]