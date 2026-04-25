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

# Download OpenTelemetry Java agent with checksum verification.
# The checksum file is published alongside the JAR in each GitHub
# release. If the checksum doesn't match, the build fails —
# catching supply-chain tampering at build time.
#
# To update: change OTEL_VERSION and rebuild.
ARG OTEL_VERSION=2.11.0
RUN apk add --no-cache curl \
    && curl -fSL -o opentelemetry-javaagent.jar \
       "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_VERSION}/opentelemetry-javaagent.jar" \
    && curl -fSL -o opentelemetry-javaagent.jar.sha256 \
       "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_VERSION}/opentelemetry-javaagent.jar.sha256" \
    && echo "$(cat opentelemetry-javaagent.jar.sha256)  opentelemetry-javaagent.jar" | sha256sum -c - \
    && rm opentelemetry-javaagent.jar.sha256 \
    && chmod 644 opentelemetry-javaagent.jar \
    && apk del curl

COPY --from=builder /app/target/app.jar .

# Entrypoint script: conditionally loads the OTel Java agent.
# When OTEL_JAVAAGENT_ENABLED=true, the agent is attached via -javaagent
# and instruments Jetty, HTTP clients, JDBC, etc. automatically.
# When false (the default), the agent JAR is never loaded — no startup
# overhead, no connection attempts to Alloy.
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

USER app
EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=15s \
  CMD wget -qO- http://localhost:8080/health || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
