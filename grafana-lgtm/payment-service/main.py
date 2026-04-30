import logging
import os
import random
import sys
import time
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, HTTPException, Request, Response
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import Status, StatusCode
from prometheus_client import REGISTRY, Counter, Histogram
from prometheus_client.exposition import choose_encoder


SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "payment-service")
OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://alloy.grafana-lgtm-demo.svc:4318").rstrip("/")
K8S_NAMESPACE = os.getenv("K8S_NAMESPACE", "")
K8S_POD_NAME = os.getenv("K8S_POD_NAME", "")
K8S_NODE_NAME = os.getenv("K8S_NODE_NAME", "")
K8S_POD_IP = os.getenv("K8S_POD_IP", "")
K8S_DEPLOYMENT_NAME = os.getenv("K8S_DEPLOYMENT_NAME", "payment-service")
K8S_CONTAINER_NAME = os.getenv("K8S_CONTAINER_NAME", "api")
FAILURE_RATE = float(os.getenv("PAYMENT_FAILURE_RATE", "0.05"))


class TraceContextFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        span_context = trace.get_current_span().get_span_context()
        if span_context.is_valid:
            record.otelTraceID = format(span_context.trace_id, "032x")
            record.otelSpanID = format(span_context.span_id, "016x")
        else:
            record.otelTraceID = ""
            record.otelSpanID = ""
        return True


def configure_otel() -> None:
    resource = Resource.create(
        {
            "service.name": SERVICE_NAME,
            "service.version": "demo",
            "deployment.environment": "rancher-desktop",
            "k8s.namespace.name": K8S_NAMESPACE,
            "k8s.pod.name": K8S_POD_NAME,
            "k8s.node.name": K8S_NODE_NAME,
            "k8s.pod.ip": K8S_POD_IP,
            "k8s.deployment.name": K8S_DEPLOYMENT_NAME,
            "k8s.container.name": K8S_CONTAINER_NAME,
        }
    )

    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=f"{OTLP_ENDPOINT}/v1/traces"))
    )
    trace.set_tracer_provider(tracer_provider)

    logger_provider = LoggerProvider(resource=resource)
    logger_provider.add_log_record_processor(
        BatchLogRecordProcessor(OTLPLogExporter(endpoint=f"{OTLP_ENDPOINT}/v1/logs"))
    )

    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.addFilter(TraceContextFilter())
    console_handler.setFormatter(
        logging.Formatter(
            "%(asctime)s %(levelname)s trace_id=%(otelTraceID)s span_id=%(otelSpanID)s %(message)s"
        )
    )
    otel_handler = LoggingHandler(level=logging.INFO, logger_provider=logger_provider)
    logging.basicConfig(level=logging.INFO, handlers=[console_handler, otel_handler])


configure_otel()

tracer = trace.get_tracer(SERVICE_NAME)
logger = logging.getLogger("payment-service")

prom_authorizations = Counter(
    "payment_authorizations",
    "Authorize calls by status.",
    ["status"],
)
prom_authorize_duration = Histogram(
    "payment_authorize_duration_ms",
    "Authorize call duration in milliseconds.",
    ["status"],
    buckets=(10, 25, 50, 75, 100, 150, 250, 500, 1000, 2500),
)


@asynccontextmanager
async def lifespan(_: FastAPI):
    logger.info("APP_START service=%s otlp_endpoint=%s", SERVICE_NAME, OTLP_ENDPOINT)
    yield
    logger.info("APP_STOP service=%s", SERVICE_NAME)


app = FastAPI(title="Payment service", lifespan=lifespan)
FastAPIInstrumentor.instrument_app(app)


def trace_exemplar() -> dict[str, str] | None:
    span_context = trace.get_current_span().get_span_context()
    if not span_context.is_valid:
        return None
    return {"trace_id": format(span_context.trace_id, "032x")}


def synthetic_work(name: str, low_ms: int, high_ms: int) -> int:
    with tracer.start_as_current_span(name) as span:
        delay_ms = random.randint(low_ms, high_ms)
        span.set_attribute("payment.delay_ms", delay_ms)
        time.sleep(delay_ms / 1000)
        return delay_ms


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/metrics")
def prometheus_metrics(request: Request) -> Response:
    encoder, content_type = choose_encoder(request.headers.get("accept", ""))
    return Response(encoder(REGISTRY), media_type=content_type)


@app.post("/authorize")
def authorize(payload: dict[str, Any]) -> dict[str, Any]:
    item = str(payload.get("item", "unknown"))
    quantity = int(payload.get("quantity", 0))
    started_at = time.monotonic()

    with tracer.start_as_current_span("payment.authorize") as span:
        span.set_attribute("payment.item", item)
        span.set_attribute("payment.quantity", quantity)
        logger.info("AUTHORIZE_START item=%s quantity=%s", item, quantity)

        synthetic_work("payment.fraud_check", 10, 40)
        synthetic_work("payment.charge_card", 25, 90)

        if random.random() < FAILURE_RATE:
            duration_ms = int((time.monotonic() - started_at) * 1000)
            prom_authorizations.labels(status="declined").inc()
            prom_authorize_duration.labels(status="declined").observe(duration_ms, exemplar=trace_exemplar())
            span.set_status(Status(StatusCode.ERROR, "card declined"))
            logger.warning("AUTHORIZE_DECLINED item=%s", item)
            raise HTTPException(status_code=402, detail="card declined")

        duration_ms = int((time.monotonic() - started_at) * 1000)
        prom_authorizations.labels(status="approved").inc()
        prom_authorize_duration.labels(status="approved").observe(duration_ms, exemplar=trace_exemplar())
        txn_id = format(random.randint(0, 2**64 - 1), "016x")
        logger.info("AUTHORIZE_APPROVED item=%s txn_id=%s", item, txn_id)
        return {"approved": True, "txn_id": txn_id, "ms": duration_ms}
