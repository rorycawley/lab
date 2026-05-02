import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


SERVICE_NAME = os.getenv("SERVICE_NAME", "service")
NAMESPACE = os.getenv("NAMESPACE", "default")
PORT = int(os.getenv("PORT", "8443"))
PEER_URL = os.getenv("PEER_URL", "")
REQUIRE_CLIENT_CERT = os.getenv("REQUIRE_CLIENT_CERT", "false").lower() == "true"
ALLOWED_CLIENT_CN = os.getenv("ALLOWED_CLIENT_CN", "")

TLS_CERT = os.getenv("TLS_CERT", "/tls/tls.crt")
TLS_KEY = os.getenv("TLS_KEY", "/tls/tls.key")
CA_CERT = os.getenv("CA_CERT", "/tls/ca.crt")
CLIENT_CERT = os.getenv("CLIENT_CERT", TLS_CERT)
CLIENT_KEY = os.getenv("CLIENT_KEY", TLS_KEY)


def log(event, **fields):
    record = {
        "event": event,
        "service": SERVICE_NAME,
        "namespace": NAMESPACE,
        **fields,
    }
    print(json.dumps(record, sort_keys=True), flush=True)


def write_json(handler, status, payload):
    body = json.dumps(payload, sort_keys=True).encode("utf-8")
    handler.send_response(status)
    handler.send_header("content-type", "application/json")
    handler.send_header("content-length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def peer_common_name(handler):
    # Teaching shortcut: production identity checks should validate SAN, not CN.
    cert = handler.connection.getpeercert()
    if not cert:
        return None
    for subject_part in cert.get("subject", []):
        for key, value in subject_part:
            if key == "commonName":
                return value
    return None


class Handler(BaseHTTPRequestHandler):
    server_version = "zero-trust-demo/1.0"

    def do_GET(self):
        started = time.monotonic()
        if self.path == "/healthz":
            write_json(self, 200, {"ok": True, "service": SERVICE_NAME})
            return

        if self.path == "/readyz":
            write_json(
                self,
                200,
                {
                    "ready": True,
                    "service": SERVICE_NAME,
                    "requires_client_cert": REQUIRE_CLIENT_CERT,
                },
            )
            return

        if self.path == "/identity":
            cn = peer_common_name(self)
            if ALLOWED_CLIENT_CN and cn != ALLOWED_CLIENT_CN:
                log("CLIENT_IDENTITY_REJECTED", client_cn=cn)
                write_json(
                    self,
                    403,
                    {
                        "error": "client_common_name_not_allowed",
                        "client_cn": cn,
                        "allowed_client_cn": ALLOWED_CLIENT_CN,
                    },
                )
                return
            log("IDENTITY_REQUEST", client_cn=cn)
            write_json(
                self,
                200,
                {
                    "service": SERVICE_NAME,
                    "namespace": NAMESPACE,
                    "tls": True,
                    "client_cn": cn,
                    "requires_client_cert": REQUIRE_CLIENT_CERT,
                },
            )
            return

        if self.path == "/call-peer":
            if not PEER_URL:
                write_json(self, 400, {"error": "PEER_URL is not configured"})
                return
            payload, status = call_peer()
            elapsed_ms = round((time.monotonic() - started) * 1000, 2)
            if status == 200:
                log("PEER_CALL_ALLOWED", peer_url=PEER_URL, elapsed_ms=elapsed_ms)
            else:
                log("PEER_CALL_FAILED", peer_url=PEER_URL, status=status, elapsed_ms=elapsed_ms)
            write_json(
                self,
                status,
                {
                    "caller": SERVICE_NAME,
                    "namespace": NAMESPACE,
                    "peer_url": PEER_URL,
                    "elapsed_ms": elapsed_ms,
                    "peer_response": payload,
                },
            )
            return

        write_json(self, 404, {"error": "not_found", "path": self.path})

    def log_message(self, fmt, *args):
        log("HTTP_ACCESS", remote=self.client_address[0], message=fmt % args)


def call_peer():
    ctx = ssl.create_default_context(cafile=CA_CERT)
    ctx.load_cert_chain(certfile=CLIENT_CERT, keyfile=CLIENT_KEY)
    req = urllib.request.Request(f"{PEER_URL}/identity")
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=5) as response:
            return json.loads(response.read().decode("utf-8")), response.status
    except urllib.error.HTTPError as exc:
        return json.loads(exc.read().decode("utf-8")), exc.code
    except Exception as exc:
        return {"error": type(exc).__name__, "detail": str(exc)}, 502


def main():
    if not os.path.exists(TLS_CERT) or not os.path.exists(TLS_KEY):
        print("TLS certificate and key are required", file=sys.stderr)
        sys.exit(1)

    ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ctx.load_cert_chain(certfile=TLS_CERT, keyfile=TLS_KEY)
    ctx.load_verify_locations(cafile=CA_CERT)
    ctx.verify_mode = ssl.CERT_REQUIRED if REQUIRE_CLIENT_CERT else ssl.CERT_OPTIONAL

    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    log("SERVER_START", port=PORT, require_client_cert=REQUIRE_CLIENT_CERT)
    server.serve_forever()


if __name__ == "__main__":
    main()
