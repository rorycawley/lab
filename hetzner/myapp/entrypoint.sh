#!/bin/sh
# Conditionally attach the OpenTelemetry Java agent.
# Set OTEL_JAVAAGENT_ENABLED=true (via Helm values) to enable tracing.
# Default: agent is NOT loaded — no startup overhead, no Alloy dependency.

JVM_OPTS="-XX:+UseContainerSupport"

if [ "${OTEL_JAVAAGENT_ENABLED}" = "true" ]; then
  JVM_OPTS="${JVM_OPTS} -javaagent:/app/opentelemetry-javaagent.jar"
fi

exec java ${JVM_OPTS} -jar /app/app.jar
