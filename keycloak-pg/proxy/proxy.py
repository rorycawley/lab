"""
PG-wire JWT auth proxy.

The proxy listens on :6432 and pretends to be PostgreSQL. A client
connects, completes the StartupMessage handshake, and is asked for a
cleartext password (PG protocol AuthenticationCleartextPassword). The
"password" the client supplies is actually a JWT obtained from
Keycloak via the client_credentials grant.

The proxy validates the JWT (signature against Keycloak's JWKS, plus
iss / azp / exp). If the JWT is good, the proxy opens a fresh
connection to the real Postgres, authenticates as a backend service
account (`pgproxy`), runs `SET ROLE <claim>` so the rest of the
session executes as the PG role named in the token, and then becomes
a transparent two-way TCP forwarder for the client's queries and
results.

If the JWT is bad, the proxy returns a Postgres ErrorResponse and
closes the connection. Postgres itself never sees the unverified
caller.

Wire-protocol references:
  https://www.postgresql.org/docs/current/protocol-message-formats.html
  https://www.postgresql.org/docs/current/protocol-flow.html
"""

import asyncio
import logging
import os
import struct
import sys
from typing import Optional

import jwt
from jwt import PyJWKClient


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("pg-jwt-proxy")

LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "6432"))
UPSTREAM_HOST = os.environ["UPSTREAM_PG_HOST"]
UPSTREAM_PORT = int(os.environ.get("UPSTREAM_PG_PORT", "5432"))
UPSTREAM_USER = os.environ["UPSTREAM_PG_USER"]
UPSTREAM_PASSWORD = os.environ["UPSTREAM_PG_PASSWORD"]
UPSTREAM_DATABASE = os.environ["UPSTREAM_PG_DATABASE"]
JWKS_URL = os.environ["JWKS_URL"]
EXPECTED_ISS = os.environ["EXPECTED_ISS"]
EXPECTED_AZP = os.environ["EXPECTED_AZP"]
ROLE_CLAIM = os.environ.get("ROLE_CLAIM", "pg_role")

PROTOCOL_VERSION = 196608  # 3.0
SSL_REQUEST_CODE = 80877103
AUTH_OK = 0
AUTH_CLEARTEXT_PASSWORD = 3

jwks_client = PyJWKClient(JWKS_URL)


# ---------- wire helpers ----------

def msg(tag: bytes, payload: bytes) -> bytes:
    """Wrap a payload as a tagged Postgres backend message."""
    return tag + struct.pack("!i", 4 + len(payload)) + payload


def cstring(s: str) -> bytes:
    return s.encode("utf-8") + b"\x00"


async def read_int32(reader: asyncio.StreamReader) -> int:
    return struct.unpack("!i", await reader.readexactly(4))[0]


async def read_startup_or_ssl(reader: asyncio.StreamReader) -> tuple[str, dict[str, str]]:
    """Returns ('ssl', {}) for SSLRequest or ('startup', params) for StartupMessage."""
    length = await read_int32(reader)
    code = await read_int32(reader)
    body = await reader.readexactly(length - 8) if length > 8 else b""

    if code == SSL_REQUEST_CODE:
        return "ssl", {}
    if code != PROTOCOL_VERSION:
        raise RuntimeError(f"unsupported protocol code: {code}")

    parts = body.split(b"\x00")
    params: dict[str, str] = {}
    i = 0
    while i + 1 < len(parts) and parts[i]:
        params[parts[i].decode("utf-8")] = parts[i + 1].decode("utf-8")
        i += 2
    return "startup", params


async def read_password_message(reader: asyncio.StreamReader) -> str:
    tag = await reader.readexactly(1)
    if tag != b"p":
        raise RuntimeError(f"expected PasswordMessage, got tag {tag!r}")
    length = await read_int32(reader)
    payload = await reader.readexactly(length - 4)
    if not payload.endswith(b"\x00"):
        raise RuntimeError("PasswordMessage missing null terminator")
    return payload[:-1].decode("utf-8")


def auth_request(method: int) -> bytes:
    return msg(b"R", struct.pack("!i", method))


def error_response(sqlstate: str, message: str) -> bytes:
    fields = (
        b"S" + cstring("FATAL")
        + b"V" + cstring("FATAL")
        + b"C" + cstring(sqlstate)
        + b"M" + cstring(message)
        + b"\x00"
    )
    return msg(b"E", fields)


# ---------- JWT validation ----------

def validate_jwt(token: str) -> dict:
    signing_key = jwks_client.get_signing_key_from_jwt(token).key
    # We don't validate `aud`: Keycloak's client_credentials tokens
    # carry `aud=account` (or similar) which is meaningless to us. The
    # claim that actually identifies *who the token was issued for* in
    # this flow is `azp` (Authorized Party = client_id), and we check
    # that explicitly below.
    claims = jwt.decode(
        token,
        signing_key,
        algorithms=["RS256", "RS384", "RS512", "ES256"],
        issuer=EXPECTED_ISS,
        options={"require": ["exp", "iat", "iss"], "verify_aud": False},
    )
    if claims.get("azp") != EXPECTED_AZP:
        raise ValueError(
            f"azp mismatch: got {claims.get('azp')!r}, expected {EXPECTED_AZP!r}"
        )
    return claims


# ---------- upstream PG ----------

async def upstream_connect_and_set_role(
    role: str,
) -> tuple[asyncio.StreamReader, asyncio.StreamWriter, list[bytes]]:
    """
    Open a fresh upstream PG connection as UPSTREAM_USER, run SET ROLE <role>,
    and return the stream pair plus the bytes of every server-side session
    message (ParameterStatus, BackendKeyData, ... ReadyForQuery) so we can
    replay them to the client and make the proxied session look normal.
    """
    reader, writer = await asyncio.open_connection(UPSTREAM_HOST, UPSTREAM_PORT)
    try:
        return await _upstream_handshake(reader, writer, role)
    except Exception:
        try:
            writer.close()
        except Exception:
            pass
        raise


async def _upstream_handshake(
    reader: asyncio.StreamReader, writer: asyncio.StreamWriter, role: str
) -> tuple[asyncio.StreamReader, asyncio.StreamWriter, list[bytes]]:
    startup = (
        cstring("user") + cstring(UPSTREAM_USER)
        + cstring("database") + cstring(UPSTREAM_DATABASE)
        + cstring("client_encoding") + cstring("UTF8")
        + b"\x00"
    )
    body = struct.pack("!i", PROTOCOL_VERSION) + startup
    writer.write(struct.pack("!i", 4 + len(body)) + body)
    await writer.drain()

    # AuthenticationCleartextPassword is what postgres:18 sends when
    # POSTGRES_HOST_AUTH_METHOD=password. Anything else means our compose
    # is misconfigured.
    tag = await reader.readexactly(1)
    if tag != b"R":
        raise RuntimeError(f"upstream: expected R, got {tag!r}")
    length = await read_int32(reader)
    method = struct.unpack("!i", (await reader.readexactly(length - 4))[:4])[0]
    if method != AUTH_CLEARTEXT_PASSWORD:
        raise RuntimeError(
            f"upstream auth method {method} not supported by this proxy "
            "(set POSTGRES_HOST_AUTH_METHOD=password)"
        )

    writer.write(msg(b"p", cstring(UPSTREAM_PASSWORD)))
    await writer.drain()

    tag = await reader.readexactly(1)
    if tag != b"R":
        raise RuntimeError(f"upstream: expected R after PasswordMessage, got {tag!r}")
    length = await read_int32(reader)
    method = struct.unpack("!i", (await reader.readexactly(length - 4))[:4])[0]
    if method != AUTH_OK:
        raise RuntimeError(f"upstream auth failed: method={method}")

    # Collect everything up to and including ReadyForQuery; we'll forward
    # the ParameterStatus / BackendKeyData / NoticeResponse messages, then
    # send our own ReadyForQuery after running SET ROLE.
    forwarded: list[bytes] = []
    while True:
        tag = await reader.readexactly(1)
        length = await read_int32(reader)
        body = await reader.readexactly(length - 4)
        full = tag + struct.pack("!i", length) + body
        if tag == b"Z":
            ready_for_query = full
            break
        forwarded.append(full)

    safe_role = role.replace('"', '""')
    writer.write(msg(b"Q", cstring(f'SET ROLE "{safe_role}";')))
    await writer.drain()

    while True:
        tag = await reader.readexactly(1)
        length = await read_int32(reader)
        body = await reader.readexactly(length - 4)
        if tag == b"E":
            raise RuntimeError(f"upstream SET ROLE failed: {body!r}")
        if tag == b"Z":
            break

    return reader, writer, forwarded + [ready_for_query]


# ---------- per-client handler ----------

async def pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter, label: str) -> None:
    try:
        while True:
            data = await src.read(65536)
            if not data:
                break
            dst.write(data)
            await dst.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError):
        pass
    except Exception:
        logger.exception("PIPE_ERROR direction=%s", label)
    finally:
        try:
            dst.close()
        except Exception:
            pass


async def handle_client(
    client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter
) -> None:
    peer = client_writer.get_extra_info("peername")
    logger.info("CLIENT_CONNECT from=%s", peer)
    upstream_writer: Optional[asyncio.StreamWriter] = None
    try:
        kind, params = await read_startup_or_ssl(client_reader)
        if kind == "ssl":
            client_writer.write(b"N")
            await client_writer.drain()
            kind, params = await read_startup_or_ssl(client_reader)
            if kind != "startup":
                raise RuntimeError("expected StartupMessage after SSLRequest")

        logger.info(
            "CLIENT_STARTUP user=%r database=%r",
            params.get("user"), params.get("database"),
        )

        client_writer.write(auth_request(AUTH_CLEARTEXT_PASSWORD))
        await client_writer.drain()

        token = await read_password_message(client_reader)

        try:
            claims = validate_jwt(token)
        except Exception as exc:
            logger.warning("JWT_REJECTED reason=%s", exc)
            client_writer.write(error_response("28000", f"JWT invalid: {exc}"))
            await client_writer.drain()
            return

        role = claims.get(ROLE_CLAIM)
        if not isinstance(role, str) or not role:
            logger.warning("JWT_MISSING_ROLE_CLAIM claim=%s", ROLE_CLAIM)
            client_writer.write(
                error_response("28000", f"JWT missing string claim {ROLE_CLAIM!r}")
            )
            await client_writer.drain()
            return

        logger.info(
            "JWT_OK sub=%s azp=%s role=%s exp=%s",
            claims.get("sub"), claims.get("azp"), role, claims.get("exp"),
        )

        try:
            upstream_reader, upstream_writer, session_msgs = (
                await upstream_connect_and_set_role(role)
            )
        except Exception as exc:
            logger.exception("UPSTREAM_FAILED")
            client_writer.write(error_response("08006", f"upstream failed: {exc}"))
            await client_writer.drain()
            return

        client_writer.write(auth_request(AUTH_OK))
        for m in session_msgs:
            client_writer.write(m)
        await client_writer.drain()

        await asyncio.gather(
            pipe(client_reader, upstream_writer, "client->upstream"),
            pipe(upstream_reader, client_writer, "upstream->client"),
        )

    except asyncio.IncompleteReadError:
        logger.info("CLIENT_DISCONNECT_EARLY peer=%s", peer)
    except Exception:
        logger.exception("CLIENT_HANDLER_ERROR peer=%s", peer)
    finally:
        try:
            client_writer.close()
        except Exception:
            pass
        if upstream_writer is not None:
            try:
                upstream_writer.close()
            except Exception:
                pass


async def main() -> None:
    # Best-effort JWKS warm-up. If Keycloak's realm doesn't exist yet
    # (bootstrap hasn't run), keep going - the first real request will
    # retry the fetch.
    try:
        jwks_client.get_jwk_set()
        logger.info("JWKS_PREFETCHED url=%s", JWKS_URL)
    except Exception as exc:
        logger.warning("JWKS_PREFETCH_DEFERRED url=%s reason=%s", JWKS_URL, exc)

    server = await asyncio.start_server(handle_client, LISTEN_HOST, LISTEN_PORT)
    logger.info(
        "PROXY_LISTENING addr=%s:%d upstream=%s:%d issuer=%s",
        LISTEN_HOST, LISTEN_PORT, UPSTREAM_HOST, UPSTREAM_PORT, EXPECTED_ISS,
    )
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
