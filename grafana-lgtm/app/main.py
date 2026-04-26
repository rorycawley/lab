import logging
import os
import random
import sys
import time
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, HTTPException, Query
from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import Status, StatusCode


SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "otel-demo-app")
OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://grafana-lgtm:4318").rstrip("/")
K8S_NAMESPACE = os.getenv("K8S_NAMESPACE", "")
K8S_POD_NAME = os.getenv("K8S_POD_NAME", "")
K8S_NODE_NAME = os.getenv("K8S_NODE_NAME", "")
K8S_POD_IP = os.getenv("K8S_POD_IP", "")
K8S_DEPLOYMENT_NAME = os.getenv("K8S_DEPLOYMENT_NAME", "otel-demo-app")
K8S_CONTAINER_NAME = os.getenv("K8S_CONTAINER_NAME", "api")


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

    metric_reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=f"{OTLP_ENDPOINT}/v1/metrics"),
        export_interval_millis=5000,
    )
    metrics.set_meter_provider(MeterProvider(resource=resource, metric_readers=[metric_reader]))


configure_otel()

tracer = trace.get_tracer(SERVICE_NAME)
meter = metrics.get_meter(SERVICE_NAME)
request_counter = meter.create_counter(
    "demo_requests_total",
    description="Number of demo endpoint calls.",
)
error_counter = meter.create_counter(
    "demo_errors_total",
    description="Number of demo endpoint errors.",
)
checkout_counter = meter.create_counter(
    "demo_checkouts_total",
    description="Number of checkout attempts.",
)
request_duration = meter.create_histogram(
    "demo_request_duration_ms",
    unit="ms",
    description="Synthetic endpoint duration.",
)
work_latency = meter.create_histogram(
    "demo_work_latency_ms",
    unit="ms",
    description="Synthetic work duration.",
)
logger = logging.getLogger("otel-demo-app")


@asynccontextmanager
async def lifespan(_: FastAPI):
    logger.info("APP_START service=%s otlp_endpoint=%s", SERVICE_NAME, OTLP_ENDPOINT)
    yield
    logger.info("APP_STOP service=%s", SERVICE_NAME)


app = FastAPI(title="Single-file OpenTelemetry LGTM demo", lifespan=lifespan)
FastAPIInstrumentor.instrument_app(app)


def current_trace_context() -> dict[str, str]:
    span_context = trace.get_current_span().get_span_context()
    if not span_context.is_valid:
        return {"trace_id": "", "span_id": ""}
    return {
        "trace_id": format(span_context.trace_id, "032x"),
        "span_id": format(span_context.span_id, "016x"),
    }


def do_synthetic_work(name: str, low_ms: int, high_ms: int) -> int:
    with tracer.start_as_current_span(name) as span:
        delay_ms = random.randint(low_ms, high_ms)
        span.set_attribute("demo.delay_ms", delay_ms)
        time.sleep(delay_ms / 1000)
        work_latency.record(delay_ms, {"operation": name})
        return delay_ms


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/")
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


@app.get("/work")
def work() -> dict[str, Any]:
    request_counter.add(1, {"endpoint": "/work"})
    logger.info("WORK_REQUEST accepted")

    with tracer.start_as_current_span("demo.work") as span:
        database_ms = do_synthetic_work("demo.fake_database_query", 25, 80)
        downstream_ms = do_synthetic_work("demo.fake_downstream_call", 40, 140)
        total_ms = database_ms + downstream_ms
        span.set_attribute("demo.total_ms", total_ms)
        request_duration.record(total_ms, {"endpoint": "/work", "status": "success"})
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
    request_counter.add(1, {"endpoint": "/checkout"})
    checkout_counter.add(1, {"item": item})

    with tracer.start_as_current_span("demo.checkout") as span:
        span.set_attribute("checkout.item", item)
        span.set_attribute("checkout.quantity", quantity)
        logger.info("CHECKOUT_STARTED item=%s quantity=%s", item, quantity)
        inventory_ms = do_synthetic_work("demo.reserve_inventory", 20, 90)
        payment_ms = do_synthetic_work("demo.authorize_payment", 30, 120)
        total_ms = inventory_ms + payment_ms
        request_duration.record(total_ms, {"endpoint": "/checkout", "status": "success"})
        logger.info("CHECKOUT_COMPLETE item=%s quantity=%s", item, quantity)

        return {
            "status": "accepted",
            "item": item,
            "quantity": quantity,
            "inventory_ms": inventory_ms,
            "payment_ms": payment_ms,
            "total_ms": total_ms,
            **current_trace_context(),
        }


@app.get("/error")
def error() -> dict[str, Any]:
    request_counter.add(1, {"endpoint": "/error"})
    with tracer.start_as_current_span("demo.error") as span:
        started_at = time.monotonic()
        try:
            raise RuntimeError("simulated downstream failure")
        except RuntimeError as exc:
            duration_ms = int((time.monotonic() - started_at) * 1000)
            error_counter.add(1, {"endpoint": "/error"})
            request_duration.record(duration_ms, {"endpoint": "/error", "status": "error"})
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            logger.exception("SIMULATED_ERROR message=%s", exc)
            raise HTTPException(status_code=500, detail=str(exc)) from exc
