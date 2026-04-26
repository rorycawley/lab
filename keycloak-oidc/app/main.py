import base64
import hashlib
import logging
import os
import secrets
import sys
import time
from typing import Any
from urllib.parse import urlencode

import jwt
import psycopg
import requests
from fastapi import Cookie, FastAPI, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from psycopg.rows import dict_row
from pydantic import BaseModel


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("keycloak-oidc-demo")

app = FastAPI(title="OIDC BFF demo")

# Two base URLs for the same Keycloak realm:
#
#   OIDC_FRONTCHANNEL_BASE   the URL the user's *browser* uses
#   OIDC_BACKCHANNEL_BASE    the URL the *BFF* uses from inside k8s
#
# Both must point at the same Keycloak. They differ because the browser
# can reach `localhost:8180` (Compose port) and the BFF cannot, while
# the BFF can reach `external-keycloak:8180` (ExternalName) and the
# browser cannot. Keycloak is configured with KC_HOSTNAME so the issuer
# claim is fixed regardless of who calls the token endpoint.
OIDC_FRONTCHANNEL_BASE = os.environ["OIDC_FRONTCHANNEL_BASE"]
OIDC_BACKCHANNEL_BASE = os.environ["OIDC_BACKCHANNEL_BASE"]
OIDC_CLIENT_ID = os.environ["OIDC_CLIENT_ID"]
OIDC_CLIENT_SECRET = os.environ["OIDC_CLIENT_SECRET"]
OIDC_REDIRECT_URI = os.environ["OIDC_REDIRECT_URI"]
OIDC_POST_LOGOUT_REDIRECT_URI = os.environ.get(
    "OIDC_POST_LOGOUT_REDIRECT_URI", "http://localhost:8080/"
)
EXPECTED_ISS = os.environ.get("EXPECTED_ISS", OIDC_FRONTCHANNEL_BASE)

PG_HOST = os.environ["PG_HOST"]
PG_PORT = os.environ.get("PG_PORT", "5432")
PG_USER = os.environ["PG_USER"]
PG_PASSWORD = os.environ["PG_PASSWORD"]
PG_DATABASE = os.environ.get("PG_DATABASE", "pocdb")

SESSION_COOKIE = "bff_session"

JWKS = jwt.PyJWKClient(f"{OIDC_BACKCHANNEL_BASE}/protocol/openid-connect/certs")

# In-memory state. Lost on pod restart, which is fine for a single-replica
# POC: users just log in again. `pending_logins` holds per-/login state
# until /callback consumes it. `sessions` holds post-login server-side
# state; the cookie value is the key.
pending_logins: dict[str, dict[str, str]] = {}
sessions: dict[str, dict[str, Any]] = {}


def conninfo() -> str:
    return (
        f"host={PG_HOST} port={PG_PORT} dbname={PG_DATABASE} "
        f"user={PG_USER} password={PG_PASSWORD} sslmode=disable connect_timeout=5"
    )


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def random_token(n: int = 32) -> str:
    return b64url(secrets.token_bytes(n))


def code_challenge_for(verifier: str) -> str:
    return b64url(hashlib.sha256(verifier.encode("ascii")).digest())


def serialize_row(row: dict[str, Any] | None) -> dict[str, Any] | None:
    if row is None:
        return None
    return {k: (v.isoformat() if hasattr(v, "isoformat") else v) for k, v in row.items()}


def upsert_profile(sub: str, claims: dict[str, Any]) -> dict[str, Any]:
    email = claims.get("email")
    pref = claims.get("preferred_username")
    name = claims.get("name") or pref or email or sub
    with psycopg.connect(conninfo(), row_factory=dict_row) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO user_profile
                    (sub, email, preferred_username, display_name, last_login_at)
                VALUES (%s, %s, %s, %s, now())
                ON CONFLICT (sub) DO UPDATE SET
                    email              = EXCLUDED.email,
                    preferred_username = EXCLUDED.preferred_username,
                    display_name       = EXCLUDED.display_name,
                    last_login_at      = now()
                RETURNING sub, email, preferred_username, display_name,
                          created_at, last_login_at,
                          (xmax = 0) AS provisioned_now
                """,
                (sub, email, pref, name),
            )
            row = cur.fetchone()
    if row.pop("provisioned_now"):
        logger.info("USER_PROVISIONED sub=%s email=%s", sub, email)
    else:
        logger.info("USER_LAST_LOGIN_UPDATED sub=%s", sub)
    return row


def get_session(cookie: str | None) -> dict[str, Any] | None:
    if not cookie:
        return None
    return sessions.get(cookie)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict[str, str]:
    with psycopg.connect(conninfo()) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
            cur.fetchone()
    return {"status": "ok"}


HOME_HTML_LOGGED_OUT = """<!doctype html>
<html><head><meta charset="utf-8"><title>OIDC BFF demo</title></head>
<body style="font-family: sans-serif; max-width: 640px; margin: 2em auto;">
<h1>OIDC BFF demo</h1>
<p>You are not logged in.</p>
<p><a href="/login"><button>Log in with Keycloak</button></a></p>
<p style="color:#666;font-size:0.9em">
The browser only ever sees a session cookie. Tokens stay on the BFF.
</p>
</body></html>
"""

HOME_HTML_LOGGED_IN = """<!doctype html>
<html><head><meta charset="utf-8"><title>OIDC BFF demo</title></head>
<body style="font-family: sans-serif; max-width: 640px; margin: 2em auto;">
<h1>OIDC BFF demo</h1>
<p>Logged in as <b>{display}</b> ({email})</p>
<p style="color:#666;font-size:0.9em">sub: <code>{sub}</code></p>
<form method="POST" action="/logout"><button>Log out</button></form>
<h2>Your notes</h2>
<ul id="notes"></ul>
<form id="add">
  <input name="text" placeholder="Add a note" required />
  <button>Add</button>
</form>
<script>
async function load() {{
  const r = await fetch("/notes", {{credentials: "same-origin"}});
  const j = await r.json();
  const ul = document.getElementById("notes");
  ul.innerHTML = "";
  for (const n of j.notes) {{
    const li = document.createElement("li");
    li.textContent = n.text + "  (" + n.created_at + ")";
    ul.appendChild(li);
  }}
}}
document.getElementById("add").addEventListener("submit", async (e) => {{
  e.preventDefault();
  const text = e.target.text.value;
  await fetch("/notes", {{
    method: "POST", credentials: "same-origin",
    headers: {{"Content-Type": "application/json"}},
    body: JSON.stringify({{text}}),
  }});
  e.target.reset();
  load();
}});
load();
</script>
</body></html>
"""


@app.get("/", response_class=HTMLResponse)
def home(bff_session: str | None = Cookie(default=None)) -> HTMLResponse:
    sess = get_session(bff_session)
    if sess is None:
        return HTMLResponse(HOME_HTML_LOGGED_OUT)
    claims = sess["claims"]
    return HTMLResponse(
        HOME_HTML_LOGGED_IN.format(
            display=claims.get("name") or claims.get("preferred_username") or "user",
            email=claims.get("email", ""),
            sub=claims.get("sub", ""),
        )
    )


@app.get("/login")
def login() -> RedirectResponse:
    state = random_token()
    nonce = random_token()
    verifier = random_token(32)
    challenge = code_challenge_for(verifier)
    pending_logins[state] = {
        "verifier": verifier,
        "nonce": nonce,
        "ts": str(int(time.time())),
    }
    params = {
        "response_type": "code",
        "client_id": OIDC_CLIENT_ID,
        "redirect_uri": OIDC_REDIRECT_URI,
        "scope": "openid email profile",
        "state": state,
        "nonce": nonce,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    url = f"{OIDC_FRONTCHANNEL_BASE}/protocol/openid-connect/auth?{urlencode(params)}"
    logger.info("LOGIN_INIT state=%s", state)
    return RedirectResponse(url, status_code=302)


@app.get("/callback")
def callback(
    code: str | None = None,
    state: str | None = None,
    error: str | None = None,
    error_description: str | None = None,
) -> Response:
    if error:
        logger.warning("CALLBACK_ERROR %s: %s", error, error_description)
        raise HTTPException(status_code=400, detail=f"OIDC error: {error}: {error_description}")
    if not code or not state:
        raise HTTPException(status_code=400, detail="missing code or state")
    pending = pending_logins.pop(state, None)
    if pending is None:
        raise HTTPException(status_code=400, detail="unknown or replayed state")

    token_resp = requests.post(
        f"{OIDC_BACKCHANNEL_BASE}/protocol/openid-connect/token",
        data={
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": OIDC_REDIRECT_URI,
            "client_id": OIDC_CLIENT_ID,
            "client_secret": OIDC_CLIENT_SECRET,
            "code_verifier": pending["verifier"],
        },
        timeout=10,
    )
    if token_resp.status_code != 200:
        logger.warning(
            "TOKEN_EXCHANGE_FAILED status=%s body=%s",
            token_resp.status_code,
            token_resp.text[:300],
        )
        raise HTTPException(
            status_code=502, detail=f"token exchange failed: {token_resp.text}"
        )
    body = token_resp.json()

    id_token = body.get("id_token")
    if not id_token:
        raise HTTPException(status_code=502, detail="no id_token in token response")

    # Verify the ID token. PyJWT validates signature/iss/aud/exp; we add
    # the OIDC nonce check explicitly because PyJWT does not.
    signing_key = JWKS.get_signing_key_from_jwt(id_token).key
    try:
        claims = jwt.decode(
            id_token,
            signing_key,
            algorithms=["RS256"],
            audience=OIDC_CLIENT_ID,
            issuer=EXPECTED_ISS,
            options={"require": ["exp", "iat", "iss", "sub", "aud"]},
        )
    except jwt.PyJWTError as exc:
        logger.warning("ID_TOKEN_INVALID %s", exc)
        raise HTTPException(status_code=401, detail=f"invalid id_token: {exc}")
    if claims.get("nonce") != pending["nonce"]:
        raise HTTPException(status_code=401, detail="nonce mismatch")

    sub = claims["sub"]
    upsert_profile(sub, claims)

    sid = random_token()
    sessions[sid] = {
        "sub": sub,
        "claims": claims,
        "id_token": id_token,
        "access_token": body.get("access_token"),
        "refresh_token": body.get("refresh_token"),
        "expires_at": int(time.time()) + int(body.get("expires_in", 0)),
    }
    logger.info("LOGIN_OK sub=%s email=%s", sub, claims.get("email"))

    resp = RedirectResponse("/", status_code=302)
    resp.set_cookie(
        SESSION_COOKIE,
        sid,
        httponly=True,
        samesite="lax",
        secure=False,  # POC: localhost over plain HTTP
        path="/",
    )
    return resp


@app.get("/me")
def me(bff_session: str | None = Cookie(default=None)) -> JSONResponse:
    sess = get_session(bff_session)
    if sess is None:
        return JSONResponse({"error": "not authenticated"}, status_code=401)
    with psycopg.connect(conninfo(), row_factory=dict_row) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT sub, email, preferred_username, display_name, "
                "       created_at, last_login_at "
                "FROM user_profile WHERE sub = %s",
                (sess["sub"],),
            )
            row = cur.fetchone()
    return JSONResponse(
        {
            "sub": sess["sub"],
            "claims": {
                "email": sess["claims"].get("email"),
                "preferred_username": sess["claims"].get("preferred_username"),
                "name": sess["claims"].get("name"),
            },
            "profile": serialize_row(row),
        }
    )


class NoteIn(BaseModel):
    text: str


@app.get("/notes")
def list_notes(bff_session: str | None = Cookie(default=None)) -> JSONResponse:
    sess = get_session(bff_session)
    if sess is None:
        return JSONResponse({"error": "not authenticated"}, status_code=401)
    with psycopg.connect(conninfo(), row_factory=dict_row) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, text, created_at FROM notes "
                "WHERE sub = %s ORDER BY id",
                (sess["sub"],),
            )
            rows = cur.fetchall()
    return JSONResponse({"notes": [serialize_row(r) for r in rows]})


@app.post("/notes")
def add_note(
    body: NoteIn,
    bff_session: str | None = Cookie(default=None),
) -> JSONResponse:
    sess = get_session(bff_session)
    if sess is None:
        return JSONResponse({"error": "not authenticated"}, status_code=401)
    with psycopg.connect(conninfo(), row_factory=dict_row) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO notes (sub, text) VALUES (%s, %s) "
                "RETURNING id, text, created_at",
                (sess["sub"], body.text),
            )
            row = cur.fetchone()
    logger.info("NOTE_ADDED sub=%s id=%s", sess["sub"], row["id"])
    return JSONResponse({"note": serialize_row(row)})


def _do_logout(bff_session: str | None) -> Response:
    sess = sessions.pop(bff_session, None) if bff_session else None
    if sess is None:
        resp = RedirectResponse("/", status_code=302)
        resp.delete_cookie(SESSION_COOKIE, path="/")
        return resp
    logger.info("LOGOUT sub=%s", sess["sub"])
    params = {
        "id_token_hint": sess["id_token"],
        "post_logout_redirect_uri": OIDC_POST_LOGOUT_REDIRECT_URI,
        "client_id": OIDC_CLIENT_ID,
    }
    url = f"{OIDC_FRONTCHANNEL_BASE}/protocol/openid-connect/logout?{urlencode(params)}"
    resp = RedirectResponse(url, status_code=302)
    resp.delete_cookie(SESSION_COOKIE, path="/")
    return resp


@app.post("/logout")
def logout_post(bff_session: str | None = Cookie(default=None)) -> Response:
    return _do_logout(bff_session)


@app.get("/logout")
def logout_get(bff_session: str | None = Cookie(default=None)) -> Response:
    return _do_logout(bff_session)
