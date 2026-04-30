const statusEl = document.querySelector("#status");
const outputEl = document.querySelector("#output");
const eventLogEl = document.querySelector("#eventLog");
const vitals = {
  FCP: document.querySelector("#fcp"),
  LCP: document.querySelector("#lcp"),
  CLS: document.querySelector("#cls"),
  INP: document.querySelector("#inp"),
  TTFB: document.querySelector("#ttfb"),
};

const route = window.location.pathname;

function randomHex(bytes) {
  const data = new Uint8Array(bytes);
  crypto.getRandomValues(data);
  return Array.from(data, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function traceContext() {
  const traceId = randomHex(16);
  const spanId = randomHex(8);
  return {
    traceId,
    spanId,
    traceparent: `00-${traceId}-${spanId}-01`,
  };
}

function logEvent(message) {
  const item = document.createElement("li");
  item.textContent = `${new Date().toLocaleTimeString()} ${message}`;
  eventLogEl.prepend(item);
  while (eventLogEl.children.length > 12) {
    eventLogEl.lastElementChild.remove();
  }
}

function setStatus(label, isError = false) {
  statusEl.textContent = label;
  statusEl.classList.toggle("error", isError);
}

async function sendTelemetry(payload, context = traceContext()) {
  const body = JSON.stringify({
    route,
    trace_id: context.traceId,
    span_id: context.spanId,
    user_agent: navigator.userAgent,
    ...payload,
  });

  const headers = {
    "content-type": "application/json",
    traceparent: context.traceparent,
  };

  if (navigator.sendBeacon && payload.event_type !== "api") {
    const blob = new Blob([body], { type: "application/json" });
    navigator.sendBeacon("/frontend-telemetry", blob);
    return;
  }

  await fetch("/frontend-telemetry", {
    method: "POST",
    headers,
    body,
    keepalive: true,
  });
}

async function observedFetch(label, endpoint) {
  const context = traceContext();
  const started = performance.now();
  setStatus("Running");
  logEvent(`started ${label}`);

  try {
    const response = await fetch(endpoint, {
      headers: {
        traceparent: context.traceparent,
      },
    });
    const duration = performance.now() - started;
    const text = await response.text();
    const parsed = safeJson(text);
    outputEl.textContent = JSON.stringify(parsed ?? text, null, 2);

    await sendTelemetry(
      {
        event_type: "api",
        name: label,
        endpoint: endpoint.split("?")[0],
        status: response.ok ? "success" : "error",
        value_ms: Math.round(duration),
        message: `HTTP ${response.status}`,
      },
      context,
    );

    setStatus(response.ok ? "Complete" : "HTTP Error", !response.ok);
    logEvent(`${label} completed in ${Math.round(duration)} ms`);
  } catch (error) {
    const duration = performance.now() - started;
    await sendTelemetry(
      {
        event_type: "error",
        name: "js_error",
        endpoint: endpoint.split("?")[0],
        status: "error",
        value_ms: Math.round(duration),
        message: error.message,
      },
      context,
    );
    setStatus("Error", true);
    outputEl.textContent = error.stack || error.message;
    logEvent(`${label} failed`);
  }
}

function safeJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function observeVitals() {
  const navigation = performance.getEntriesByType("navigation")[0];
  if (navigation) {
    const ttfb = Math.max(0, navigation.responseStart - navigation.requestStart);
    updateVital("TTFB", ttfb);
  }

  if ("PerformanceObserver" in window) {
    try {
      new PerformanceObserver((list) => {
        const fcp = list.getEntries().find((entry) => entry.name === "first-contentful-paint");
        if (fcp) updateVital("FCP", fcp.startTime);
      }).observe({ type: "paint", buffered: true });
    } catch {}

    try {
      new PerformanceObserver((list) => {
        const entries = list.getEntries();
        const lcp = entries[entries.length - 1];
        if (lcp) updateVital("LCP", lcp.startTime);
      }).observe({ type: "largest-contentful-paint", buffered: true });
    } catch {}

    try {
      let cls = 0;
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          if (!entry.hadRecentInput) cls += entry.value;
        }
        updateVital("CLS", cls * 1000);
      }).observe({ type: "layout-shift", buffered: true });
    } catch {}

    try {
      new PerformanceObserver((list) => {
        const entries = list.getEntries();
        const interaction = entries.reduce((max, entry) => Math.max(max, entry.duration), 0);
        if (interaction > 0) updateVital("INP", interaction);
      }).observe({ type: "event", durationThreshold: 16, buffered: true });
    } catch {}
  }
}

function updateVital(name, value) {
  const rounded = Math.round(value);
  vitals[name].textContent = `${rounded} ms`;
  sendTelemetry({
    event_type: "web_vital",
    name,
    value_ms: rounded,
  });
}

document.querySelector("#workButton").addEventListener("click", () => observedFetch("work", "/work"));
document.querySelector("#checkoutButton").addEventListener("click", () => observedFetch("checkout", "/checkout?item=coffee&quantity=2"));
document.querySelector("#errorButton").addEventListener("click", () => observedFetch("error", "/error"));
document.querySelector("#jsErrorButton").addEventListener("click", () => {
  throw new Error("simulated browser exception");
});

window.addEventListener("error", (event) => {
  setStatus("JS Error", true);
  outputEl.textContent = event.error?.stack || event.message;
  logEvent("captured browser exception");
  sendTelemetry({
    event_type: "error",
    name: "js_error",
    status: "error",
    message: event.message,
  });
});

window.addEventListener("unhandledrejection", (event) => {
  sendTelemetry({
    event_type: "error",
    name: "unhandled_rejection",
    status: "error",
    message: String(event.reason),
  });
});

window.addEventListener("load", () => {
  observeVitals();
  sendTelemetry({
    event_type: "page_load",
    name: "load",
    value_ms: Math.round(performance.now()),
  });
  logEvent("page load telemetry sent");
});
