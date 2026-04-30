import logging
import os
import random
import sys
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import requests
from fastapi import FastAPI, HTTPException, Query, Request, Response
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import Status, StatusCode
from prometheus_client import REGISTRY, Counter, Histogram
from prometheus_client.exposition import choose_encoder
from pydantic import BaseModel, Field


SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "otel-demo-app")
OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://alloy.grafana-lgtm-demo.svc:4318").rstrip("/")
PAYMENT_SERVICE_URL = os.getenv("PAYMENT_SERVICE_URL", "http://payment-service:8080").rstrip("/")
K8S_NAMESPACE = os.getenv("K8S_NAMESPACE", "")
K8S_POD_NAME = os.getenv("K8S_POD_NAME", "")
K8S_NODE_NAME = os.getenv("K8S_NODE_NAME", "")
K8S_POD_IP = os.getenv("K8S_POD_IP", "")
K8S_DEPLOYMENT_NAME = os.getenv("K8S_DEPLOYMENT_NAME", "otel-demo-app")
K8S_CONTAINER_NAME = os.getenv("K8S_CONTAINER_NAME", "api")
STATIC_DIR = Path(__file__).parent / "static"


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
logger = logging.getLogger("otel-demo-app")


class FrontendTelemetry(BaseModel):
    event_type: str = Field(default="event", max_length=64)
    name: str = Field(default="unknown", max_length=80)
    route: str = Field(default="/", max_length=120)
    value_ms: float | None = Field(default=None, ge=0, le=120000)
    status: str | None = Field(default=None, max_length=32)
    endpoint: str | None = Field(default=None, max_length=120)
    message: str | None = Field(default=None, max_length=500)
    trace_id: str | None = Field(default=None, max_length=32)
    span_id: str | None = Field(default=None, max_length=16)
    user_agent: str | None = Field(default=None, max_length=240)

prom_request_counter = Counter(
    "demo_requests",
    "Number of demo endpoint calls.",
    ["endpoint"],
)
prom_error_counter = Counter(
    "demo_errors",
    "Number of demo endpoint errors.",
    ["endpoint"],
)
prom_checkout_counter = Counter(
    "demo_checkouts",
    "Number of checkout attempts.",
    ["item"],
)
prom_request_duration = Histogram(
    "demo_request_duration_ms",
    "Synthetic endpoint duration in milliseconds.",
    ["endpoint", "status"],
    buckets=(10, 25, 50, 75, 100, 150, 250, 500, 1000, 2500, 5000),
)
prom_work_latency = Histogram(
    "demo_work_latency_ms",
    "Synthetic work duration in milliseconds.",
    ["operation"],
    buckets=(10, 25, 50, 75, 100, 150, 250, 500, 1000, 2500),
)
prom_frontend_events = Counter(
    "frontend_events",
    "Number of browser telemetry events received.",
    ["event_type", "name", "route"],
)
prom_frontend_errors = Counter(
    "frontend_errors",
    "Number of browser errors reported.",
    ["name", "route"],
)
prom_frontend_api_duration = Histogram(
    "frontend_api_duration_ms",
    "Browser-observed API request duration in milliseconds.",
    ["endpoint", "status"],
    buckets=(25, 50, 75, 100, 150, 250, 500, 1000, 2500, 5000, 10000),
)
prom_frontend_web_vital = Histogram(
    "frontend_web_vital_ms",
    "Browser-observed Web Vital timings in milliseconds.",
    ["name"],
    buckets=(10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000),
)


@asynccontextmanager
async def lifespan(_: FastAPI):
    logger.info("APP_START service=%s otlp_endpoint=%s", SERVICE_NAME, OTLP_ENDPOINT)
    yield
    logger.info("APP_STOP service=%s", SERVICE_NAME)


app = FastAPI(title="Single-file OpenTelemetry LGTM demo", lifespan=lifespan)
FastAPIInstrumentor.instrument_app(app)
RequestsInstrumentor().instrument()
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


def current_trace_context() -> dict[str, str]:
    span_context = trace.get_current_span().get_span_context()
    if not span_context.is_valid:
        return {"trace_id": "", "span_id": ""}
    return {
        "trace_id": format(span_context.trace_id, "032x"),
        "span_id": format(span_context.span_id, "016x"),
    }


def trace_exemplar() -> dict[str, str] | None:
    span_context = trace.get_current_span().get_span_context()
    if not span_context.is_valid:
        return None
    return {"trace_id": format(span_context.trace_id, "032x")}


def safe_label(value: str | None, fallback: str, allowed: set[str]) -> str:
    if value in allowed:
        return value
    return fallback


def do_synthetic_work(name: str, low_ms: int, high_ms: int) -> int:
    with tracer.start_as_current_span(name) as span:
        delay_ms = random.randint(low_ms, high_ms)
        span.set_attribute("demo.delay_ms", delay_ms)
        time.sleep(delay_ms / 1000)
        prom_work_latency.labels(operation=name).observe(delay_ms, exemplar=trace_exemplar())
        return delay_ms


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/metrics")
def prometheus_metrics(request: Request) -> Response:
    encoder, content_type = choose_encoder(request.headers.get("accept", ""))
    return Response(encoder(REGISTRY), media_type=content_type)


@app.get("/")
def frontend() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html", media_type="text/html")


@app.get("/api")
def index() -> dict[str, Any]:
    return {
        "service": SERVICE_NAME,
        "otlp_endpoint": OTLP_ENDPOINT,
        "kubernetes": {
            "namespace": K8S_NAMESPACE,
            "pod": K8S_POD_NAME,
            "node": K8S_NODE_NAME,
            "pod_ip": K8S_POD_IP,
            "deployment": K8S_DEPLOYMENT_NAME,
            "container": K8S_CONTAINER_NAME,
        },
        "try": ["/work", "/checkout?item=coffee&quantity=2", "/error"],
    }


@app.post("/frontend-telemetry")
def frontend_telemetry(event: FrontendTelemetry, request: Request) -> dict[str, str]:
    allowed_event_types = {"page_load", "api", "web_vital", "interaction", "error"}
    allowed_names = {
        "app_start",
        "load",
        "route_view",
        "work",
        "checkout",
        "error",
        "LCP",
        "CLS",
        "FCP",
        "TTFB",
        "INP",
        "js_error",
        "unhandled_rejection",
    }
    allowed_routes = {"/"}
    allowed_endpoints = {"/work", "/checkout", "/error", "/frontend-telemetry", "none"}

    event_type = safe_label(event.event_type, "event", allowed_event_types)
    name = safe_label(event.name, "unknown", allowed_names)
    route = safe_label(event.route, "/", allowed_routes)
    endpoint = safe_label(event.endpoint or "none", "none", allowed_endpoints)
    status = safe_label(event.status or "unknown", "unknown", {"success", "error", "unknown"})

    with tracer.start_as_current_span(f"frontend.{event_type}") as span:
        span.set_attribute("frontend.event_type", event_type)
        span.set_attribute("frontend.name", name)
        span.set_attribute("frontend.route", route)
        span.set_attribute("frontend.endpoint", endpoint)
        if event.value_ms is not None:
            span.set_attribute("frontend.value_ms", event.value_ms)
        if event.message:
            span.set_attribute("frontend.message", event.message)

        prom_frontend_events.labels(event_type=event_type, name=name, route=route).inc()
        if event_type == "api" and event.value_ms is not None:
            prom_frontend_api_duration.labels(endpoint=endpoint, status=status).observe(event.value_ms, exemplar=trace_exemplar())
        if event_type == "web_vital" and event.value_ms is not None:
            prom_frontend_web_vital.labels(name=name).observe(event.value_ms, exemplar=trace_exemplar())
        if event_type == "error":
            prom_frontend_errors.labels(name=name, route=route).inc()
            span.set_status(Status(StatusCode.ERROR, event.message or "frontend error"))

        logger.info(
            "FRONTEND_EVENT type=%s name=%s route=%s endpoint=%s status=%s value_ms=%s browser_trace_id=%s ip=%s user_agent=%s message=%s",
            event_type,
            name,
            route,
            endpoint,
            status,
            event.value_ms,
            event.trace_id or "",
            request.client.host if request.client else "",
            event.user_agent or "",
            event.message or "",
        )

    return {"status": "ok"}


@app.get("/work")
def work() -> dict[str, Any]:
    prom_request_counter.labels(endpoint="/work").inc()
    logger.info("WORK_REQUEST accepted")

    with tracer.start_as_current_span("demo.work") as span:
        database_ms = do_synthetic_work("demo.fake_database_query", 25, 80)
        downstream_ms = do_synthetic_work("demo.fake_downstream_call", 40, 140)
        total_ms = database_ms + downstream_ms
        span.set_attribute("demo.total_ms", total_ms)
        prom_request_duration.labels(endpoint="/work", status="success").observe(total_ms, exemplar=trace_exemplar())
        logger.info("WORK_COMPLETE total_ms=%s", total_ms)

        return {
            "status": "ok",
            "database_ms": database_ms,
            "downstream_ms": downstream_ms,
            "total_ms": total_ms,
            **current_trace_context(),
        }


@app.get("/checkout")
def checkout(
    item: str = Query("coffee", min_length=1),
    quantity: int = Query(1, ge=1, le=10),
) -> dict[str, Any]:
    prom_request_counter.labels(endpoint="/checkout").inc()
    prom_checkout_counter.labels(item=item).inc()

    with tracer.start_as_current_span("demo.checkout") as span:
        span.set_attribute("checkout.item", item)
        span.set_attribute("checkout.quantity", quantity)
        logger.info("CHECKOUT_STARTED item=%s quantity=%s", item, quantity)
        inventory_ms = do_synthetic_work("demo.reserve_inventory", 20, 90)

        payment_started = time.monotonic()
        try:
            response = requests.post(
                f"{PAYMENT_SERVICE_URL}/authorize",
                json={"item": item, "quantity": quantity},
                timeout=5,
            )
            response.raise_for_status()
        except requests.RequestException as exc:
            payment_ms = int((time.monotonic() - payment_started) * 1000)
            total_ms = inventory_ms + payment_ms
            prom_error_counter.labels(endpoint="/checkout").inc()
            prom_request_duration.labels(endpoint="/checkout", status="error").observe(total_ms, exemplar=trace_exemplar())
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            logger.warning("CHECKOUT_PAYMENT_FAILED item=%s err=%s", item, exc)
            raise HTTPException(status_code=502, detail=f"payment failed: {exc}") from exc

        payment_ms = int((time.monotonic() - payment_started) * 1000)
        total_ms = inventory_ms + payment_ms
        prom_request_duration.labels(endpoint="/checkout", status="success").observe(total_ms, exemplar=trace_exemplar())
        logger.info("CHECKOUT_COMPLETE item=%s quantity=%s txn_id=%s", item, quantity, response.json().get("txn_id"))

        return {
            "status": "accepted",
            "item": item,
            "quantity": quantity,
            "inventory_ms": inventory_ms,
            "payment_ms": payment_ms,
            "total_ms": total_ms,
            "txn_id": response.json().get("txn_id"),
            **current_trace_context(),
        }


@app.get("/error")
def error() -> dict[str, Any]:
    prom_request_counter.labels(endpoint="/error").inc()
    with tracer.start_as_current_span("demo.error") as span:
        started_at = time.monotonic()
        try:
            raise RuntimeError("simulated downstream failure")
        except RuntimeError as exc:
            duration_ms = int((time.monotonic() - started_at) * 1000)
            prom_error_counter.labels(endpoint="/error").inc()
            prom_request_duration.labels(endpoint="/error", status="error").observe(duration_ms, exemplar=trace_exemplar())
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            logger.exception("SIMULATED_ERROR message=%s", exc)
            raise HTTPException(status_code=500, detail=str(exc)) from exc
