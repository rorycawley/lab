#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="grafana-lgtm-demo"

cleanup_verify_pods() {
  kubectl delete pod \
    app-smoke \
    loki-query \
    loki-frontend-query \
    tempo-query \
    tempo-frontend-query \
    tempo-payment-query \
    mimir-app-metrics-query \
    mimir-frontend-metrics-query \
    mimir-cpu-query \
    mimir-memory-query \
    --namespace "$NAMESPACE" \
    --ignore-not-found \
    --wait=false >/dev/null
}

cleanup_verify_pods

echo "==> Pods"
kubectl get pods -n "$NAMESPACE"

echo "==> Emit logs from app"
kubectl run app-smoke \
  --namespace "$NAMESPACE" \
  --pod-running-timeout=180s \
  --rm \
  -i \
  --restart=Never \
  --image=curlimages/curl:8.11.1 \
  --command -- sh -c 'set -e; ready=0; for i in $(seq 1 45); do if curl -fsS http://otel-demo-app:8080/healthz >/dev/null && curl -fsS http://payment-service:8080/healthz >/dev/null; then ready=1; break; fi; sleep 2; done; if [ "$ready" != "1" ]; then echo "App or payment-service did not become reachable" >&2; exit 1; fi; for i in $(seq 1 5); do curl -fsS http://otel-demo-app:8080/work >/dev/null; checkout_ok=0; for j in $(seq 1 10); do if curl -fsS "http://otel-demo-app:8080/checkout?item=coffee&quantity=2" >/dev/null; then checkout_ok=1; break; fi; sleep 1; done; if [ "$checkout_ok" != "1" ]; then echo "Checkout did not succeed after retries" >&2; exit 1; fi; done; curl -sS http://otel-demo-app:8080/error >/dev/null || true; curl -fsS -H "content-type: application/json" -H "traceparent: 00-11111111111111111111111111111111-2222222222222222-01" -d "{\"event_type\":\"page_load\",\"name\":\"load\",\"route\":\"/\",\"value_ms\":123,\"trace_id\":\"11111111111111111111111111111111\",\"span_id\":\"2222222222222222\"}" http://otel-demo-app:8080/frontend-telemetry >/dev/null; curl -fsS -H "content-type: application/json" -H "traceparent: 00-33333333333333333333333333333333-4444444444444444-01" -d "{\"event_type\":\"api\",\"name\":\"work\",\"route\":\"/\",\"endpoint\":\"/work\",\"status\":\"success\",\"value_ms\":84,\"trace_id\":\"33333333333333333333333333333333\",\"span_id\":\"4444444444444444\"}" http://otel-demo-app:8080/frontend-telemetry >/dev/null; curl -fsS -H "content-type: application/json" -d "{\"event_type\":\"web_vital\",\"name\":\"LCP\",\"route\":\"/\",\"value_ms\":420}" http://otel-demo-app:8080/frontend-telemetry >/dev/null'

echo "==> Query Loki for app logs"
kubectl run loki-query \
  --namespace "$NAMESPACE" \
  --pod-running-timeout=180s \
  --rm \
  -i \
  --restart=Never \
  --image=curlimages/curl:8.11.1 \
  --command -- sh -c 'set -e; sleep 8; curl -fsS -G "http://loki-gateway/loki/api/v1/query_range" --data-urlencode "query={namespace=\"grafana-lgtm-demo\",pod=~\"otel-demo-app-.*\"} |= \"WORK_\"" --data-urlencode "limit=5" --data-urlencode "start=$(($(date +%s)-300))000000000" --data-urlencode "end=$(date +%s)000000000" -o /tmp/loki-response.json; if grep -q "\"result\":\\[\\]" /tmp/loki-response.json; then echo "No app WORK logs returned from Loki" >&2; cat /tmp/loki-response.json >&2; exit 1; fi; cat /tmp/loki-response.json | tr -d "\n" | sed -E "s/.{220}/&\\n/g" | head -n 8'

echo "==> Query Loki for frontend logs"
kubectl run loki-frontend-query \
  --namespace "$NAMESPACE" \
  --pod-running-timeout=180s \
  --rm \
  -i \
  --restart=Never \
  --image=curlimages/curl:8.11.1 \
  --command -- sh -c 'set -e; sleep 8; curl -fsS -G "http://loki-gateway/loki/api/v1/query_range" --data-urlencode "query={namespace=\"grafana-lgtm-demo\",pod=~\"otel-demo-app-.*\"} |= \"FRONTEND_EVENT\"" --data-urlencode "limit=5" --data-urlencode "start=$(($(date +%s)-300))000000000" --data-urlencode "end=$(date +%s)000000000" -o /tmp/loki-response.json; if grep -q "\"result\":\\[\\]" /tmp/loki-response.json; then echo "No frontend logs returned from Loki" >&2; cat /tmp/loki-response.json >&2; exit 1; fi; cat /tmp/loki-response.json | tr -d "\n" | sed -E "s/.{220}/&\\n/g" | head -n 8'

echo "==> Query Tempo for app traces"
kubectl run tempo-query \
  --namespace "$NAMESPACE" \
  --pod-running-timeout=180s \
  --rm \
  -i \
  --restart=Never \
  --image=curlimages/curl:8.11.1 \
  --command -- sh -c 'for i in $(seq 1 24); do if curl -fsS -G "http://tempo:3200/api/search" --data-urlencode "tags=service.name=otel-demo-app" --data-urlencode "limit=5" -o /tmp/tempo-response.json 2>/dev/null && grep -q "\"traceID\"" /tmp/tempo-response.json; then cat /tmp/tempo-response.json | tr -d "\n" | sed -E "s/.{220}/&\\n/g" | head -n 8; exit 0; fi; sleep 5; done; echo "No app traces returned from Tempo" >&2; cat /tmp/tempo-response.json 2>/dev/null >&2 || true; exit 1'

echo "==> Query Tempo for frontend telemetry traces"
kubectl run tempo-frontend-query \
  --namespace "$NAMESPACE" \
  --pod-running-timeout=180s \
  --rm \
  -i \
  --restart=Never \
  --image=curlimages/curl:8.11.1 \
  --command -- sh -c 'for trace_id in 11111111111111111111111111111111 33333333333333333333333333333333; do for i in $(seq 1 24); do if curl -fsS "http://tempo:3200/api/traces/$trace_id" -o /tmp/tempo-response.json 2>/dev/null && grep -q "frontend\\." /tmp/tempo-response.json; then cat /tmp/tempo-response.json | tr -d "\n" | sed -E "s/.{220}/&\\n/g" | head -n 8; exit 0; fi; sleep 5; done; done; echo "No frontend telemetry traces returned from Tempo" >&2; cat /tmp/tempo-response.json 2>/dev/null >&2 || true; exit 1'

echo "==> Query Tempo for payment-service traces"
kubectl run tempo-payment-query \
  --namespace "$NAMESPACE" \
  --pod-running-timeout=180s \
  --rm \
  -i \
  --restart=Never \
  --image=curlimages/curl:8.11.1 \
  --command -- sh -c 'for i in $(seq 1 24); do if curl -fsS -G "http://tempo:3200/api/search" --data-urlencode "tags=service.name=payment-service" --data-urlencode "limit=5" -o /tmp/tempo-response.json 2>/dev/null && grep -q "\"traceID\"" /tmp/tempo-response.json; then cat /tmp/tempo-response.json | tr -d "\n" | sed -E "s/.{220}/&\\n/g" | head -n 8; exit 0; fi; sleep 5; done; echo "No payment-service traces returned from Tempo (cross-service trace propagation broken?)" >&2; cat /tmp/tempo-response.json 2>/dev/null >&2 || true; exit 1'

echo "==> List S3 objects in alarik/loki"
ALARIK_POD="$(kubectl get pod -n "$NAMESPACE" -l release=alarik -o jsonpath='{.items[0].metadata.name}')"
kubectl exec -n "$NAMESPACE" "$ALARIK_POD" -- sh -c 'test -d /export/loki && test -n "$(ls -A /export/loki)" && ls -R /export/loki | head -n 40'

echo "==> Query Mimir for request latency metrics"
kubectl run mimir-app-metrics-query \
  --namespace "$NAMESPACE" \
  --pod-running-timeout=180s \
  --rm \
  -i \
  --restart=Never \
  --image=curlimages/curl:8.11.1 \
  --command -- sh -c 'set -e; for i in $(seq 1 18); do curl -fsS -G "http://mimir-nginx/prometheus/api/v1/query" --data-urlencode "query={__name__=~\"demo_(request_duration|work_latency).*\"}" -o /tmp/mimir-response.json; if ! grep -q "\"result\":\\[\\]" /tmp/mimir-response.json; then cat /tmp/mimir-response.json | tr -d "\n" | sed -E "s/.{220}/&\\n/g" | head -n 8; exit 0; fi; sleep 5; done; echo "No app latency metrics returned from Mimir" >&2; cat /tmp/mimir-response.json >&2; exit 1'

echo "==> Query Mimir for frontend metrics"
kubectl run mimir-frontend-metrics-query \
  --namespace "$NAMESPACE" \
  --pod-running-timeout=180s \
  --rm \
  -i \
  --restart=Never \
  --image=curlimages/curl:8.11.1 \
  --command -- sh -c 'set -e; for i in $(seq 1 18); do curl -fsS -G "http://mimir-nginx/prometheus/api/v1/query" --data-urlencode "query={__name__=~\"frontend_(events|api_duration|web_vital).*\"}" -o /tmp/mimir-response.json; if ! grep -q "\"result\":\\[\\]" /tmp/mimir-response.json; then cat /tmp/mimir-response.json | tr -d "\n" | sed -E "s/.{220}/&\\n/g" | head -n 8; exit 0; fi; sleep 5; done; echo "No frontend metrics returned from Mimir" >&2; cat /tmp/mimir-response.json >&2; exit 1'

echo "==> Query Mimir for pod CPU metrics"
kubectl run mimir-cpu-query \
  --namespace "$NAMESPACE" \
  --pod-running-timeout=180s \
  --rm \
  -i \
  --restart=Never \
  --image=curlimages/curl:8.11.1 \
  --command -- sh -c 'set -e; for i in $(seq 1 12); do curl -fsS -G "http://mimir-nginx/prometheus/api/v1/query" --data-urlencode "query=container_cpu_usage_seconds_total{namespace=\"grafana-lgtm-demo\",pod=~\"otel-demo-app-.*\"}" -o /tmp/mimir-response.json; if ! grep -q "\"result\":\\[\\]" /tmp/mimir-response.json; then cat /tmp/mimir-response.json | tr -d "\n" | sed -E "s/.{220}/&\\n/g" | head -n 8; exit 0; fi; sleep 5; done; echo "No pod CPU metrics returned from Mimir" >&2; cat /tmp/mimir-response.json >&2; exit 1'

echo "==> Query Mimir for pod memory metrics"
kubectl run mimir-memory-query \
  --namespace "$NAMESPACE" \
  --pod-running-timeout=180s \
  --rm \
  -i \
  --restart=Never \
  --image=curlimages/curl:8.11.1 \
  --command -- sh -c 'set -e; for i in $(seq 1 12); do curl -fsS -G "http://mimir-nginx/prometheus/api/v1/query" --data-urlencode "query=container_memory_working_set_bytes{namespace=\"grafana-lgtm-demo\",pod=~\"otel-demo-app-.*\"}" -o /tmp/mimir-response.json; if ! grep -q "\"result\":\\[\\]" /tmp/mimir-response.json; then cat /tmp/mimir-response.json | tr -d "\n" | sed -E "s/.{220}/&\\n/g" | head -n 8; exit 0; fi; sleep 5; done; echo "No pod memory metrics returned from Mimir" >&2; cat /tmp/mimir-response.json >&2; exit 1'
