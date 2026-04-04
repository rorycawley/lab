# ── Stage 1: Build ───────────────────────────────────────────────────
FROM clojure:temurin-21-tools-deps-alpine AS builder

WORKDIR /app

# Copy deps first → Docker caches this layer until deps.edn changes
COPY deps.edn .
RUN clj -P                      # download all dependencies
RUN clj -P -T:build             # download build-tool dependencies

# Now copy source and build the uberjar
COPY . .
RUN clj -T:build uber

# ── Stage 2: Run ─────────────────────────────────────────────────────
FROM eclipse-temurin:21-jre-alpine

# Non-root user for security
RUN addgroup -S app && adduser -S app -G app

WORKDIR /app

# Download OpenTelemetry Java agent for automatic trace instrumentation
# This auto-instruments Jetty, HTTP clients, JDBC etc. — zero code changes.
# Controlled via OTEL_* env vars in K8s deployment.
ADD --chmod=644 \
  https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.11.0/opentelemetry-javaagent.jar \
  /app/opentelemetry-javaagent.jar

COPY --from=builder /app/target/app.jar .

USER app
EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=15s \
  CMD wget -qO- http://localhost:8080/health || exit 1

# OTEL_JAVAAGENT_ENABLED (default: true) controls whether the agent loads.
# Set to "false" in values-local.yaml if you don't need tracing locally.
ENTRYPOINT ["java", "-XX:+UseContainerSupport", \
            "-javaagent:/app/opentelemetry-javaagent.jar", \
            "-jar", "app.jar"]
