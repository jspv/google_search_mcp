import argparse
import base64
import hashlib
import http.server
import json
import os
import re
import threading
import time
import urllib.parse
import webbrowser
from dataclasses import dataclass
from typing import Dict, Optional

import requests
from requests.exceptions import RequestException

# ========= CONFIG YOU MAY CHANGE =========
LOCAL_CALLBACK = (
    "http://localhost:8765/callback"  # must be in Cognito Allowed callback URLs
)
DEFAULT_SCOPES = [
    "openid",
    "email",
    "phone",
]  # requested scopes if discovery doesn't specify
OPEN_BROWSER = True  # set False to copy/paste the auth URL yourself
TIMEOUT_LOGIN_SEC = 600
# =========================================


# --- tiny utils ---
def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def make_pkce():
    verifier = b64url(os.urandom(64))
    challenge = b64url(hashlib.sha256(verifier.encode()).digest())
    return verifier, challenge


def decode_jwt_noverify(token: str) -> Dict:
    try:
        payload_b64 = token.split(".")[1]
        payload_b64 += "=" * (-len(payload_b64) % 4)
        return json.loads(base64.urlsafe_b64decode(payload_b64.encode()))
    except Exception:
        return {}


def parse_www_authenticate(h: str) -> Dict[str, str]:
    """
    Parse a WWW-Authenticate Bearer header with key="value" params.
    e.g. Bearer authorization_uri="...", token_uri="...", issuer="...", scope="..."
    Returns dict of the params (lowercased keys).
    """
    # Strip "Bearer" prefix if present
    m = re.match(r"^\s*Bearer\s*(.*)$", h, re.IGNORECASE)
    param_str = m.group(1) if m else h
    # key="value" pairs; handle commas inside URLs by using a regex
    rx = re.compile(r'(\w+)=("([^"]*)"|[^,]+)')
    out = {}
    for k, v, qv in rx.findall(param_str):
        out[k.lower()] = qv if qv != "" else v.strip('"')
    return out


# --- OAuth callback capture ---
@dataclass
class AuthResult:
    code: Optional[str] = None
    state: Optional[str] = None
    error: Optional[str] = None
    error_description: Optional[str] = None


AUTH_RESULT = AuthResult()


class CallbackHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/callback":
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Not found")
            return
        qs = urllib.parse.parse_qs(parsed.query)
        AUTH_RESULT.code = (qs.get("code") or [None])[0]
        AUTH_RESULT.state = (qs.get("state") or [None])[0]
        AUTH_RESULT.error = (qs.get("error") or [None])[0]
        AUTH_RESULT.error_description = (qs.get("error_description") or [None])[0]

        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        if AUTH_RESULT.code:
            self.wfile.write(
                b"<h2>Authorization code received.</h2><p>You can close this tab.</p>"
            )
        else:
            msg = AUTH_RESULT.error or "Unknown error"
            self.wfile.write(f"<h2>Authorization failed</h2><pre>{msg}</pre>".encode())

    def log_message(self, *args, **kwargs):
        return


def start_callback_server():
    server = http.server.HTTPServer(("127.0.0.1", 8765), CallbackHandler)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server


# --- Discovery from MCP URL ---
def discover_from_mcp(mcp_url: str) -> Dict[str, str]:
    """
    Try:
      1) GET mcp_url (no auth) and parse WWW-Authenticate header (401 expected)
      2) GET mcp_url/.well-known/oauth-client (JSON)
    Returns dict with:
      authorization_endpoint, token_endpoint, issuer, scopes (space-delimited), client_id
    """
    print(f"\n== Discovery Probe ==")
    print(f"[*] Probing MCP URL: {mcp_url}")

    # Initial GET to see what we get
    try:
        r = requests.get(mcp_url, timeout=10)
        print(f"  - Initial GET status: {r.status_code}")
        print(f"  - Content-Type: {r.headers.get('Content-Type', 'Not set')}")
        if r.status_code not in [200, 401]:
            print(f"  - Response body preview: {r.text[:200]}...")
    except RequestException as e:
        print(f"  - Initial GET error: {e}")

    # 1) WWW-Authenticate on 401
    print("\n[*] Trying WWW-Authenticate discovery...")
    try:
        r = requests.get(mcp_url, timeout=10)
        if r.status_code == 401:
            wa = r.headers.get("WWW-Authenticate") or r.headers.get("Www-Authenticate")
            print(f"  - Got 401 response")
            if wa:
                print(f"  - WWW-Authenticate header: {wa}")
                params = parse_www_authenticate(wa)
                print(f"  - Parsed params: {params}")

                auth_uri = params.get("authorization_uri") or params.get(
                    "authorization_endpoint"
                )
                token_uri = params.get("token_uri") or params.get("token_endpoint")
                issuer = params.get("issuer")
                scope = params.get("scope") or " ".join(DEFAULT_SCOPES)
                client_id = None

                # Some servers embed client_id in the authorization_uri
                if auth_uri:
                    q = urllib.parse.urlparse(auth_uri).query
                    qs = urllib.parse.parse_qs(q)
                    client_id = (qs.get("client_id") or [None])[0]
                    print(f"  - Extracted client_id from auth URI: {client_id}")

                print(f"  - authorization_endpoint: {auth_uri}")
                print(f"  - token_endpoint: {token_uri}")
                print(f"  - issuer: {issuer}")
                print(f"  - client_id: {client_id}")
                print(f"  - scopes: {scope}")

                if auth_uri and token_uri and issuer and client_id:
                    print("  ✓ WWW-Authenticate discovery successful!")
                    return {
                        "authorization_endpoint": auth_uri,
                        "token_endpoint": token_uri,
                        "issuer": issuer,
                        "scopes": scope,
                        "client_id": client_id,
                    }
                else:
                    print(
                        "  ✗ WWW-Authenticate missing required fields; trying .well-known..."
                    )
            else:
                print("  - No WWW-Authenticate header found")
        else:
            print(f"  - Expected 401, got {r.status_code}")
    except RequestException as e:
        print(f"  - WWW-Authenticate probe error: {e}")

    # 2) .well-known fallback
    print("\n[*] Trying .well-known/oauth-client discovery...")
    well_known = mcp_url.rstrip("/") + "/.well-known/oauth-client"
    print(f"  - Trying URL: {well_known}")
    try:
        rw = requests.get(well_known, timeout=10)
        print(f"  - Status: {rw.status_code}")
        print(f"  - Content-Type: {rw.headers.get('Content-Type', 'Not set')}")

        if rw.status_code == 200 and rw.headers.get("Content-Type", "").startswith(
            "application/json"
        ):
            data = rw.json()
            print(f"  - JSON response: {json.dumps(data, indent=4)}")

            auth_uri = data.get("authorization_endpoint") or data.get(
                "authorization_uri"
            )
            token_uri = data.get("token_endpoint") or data.get("token_uri")
            issuer = data.get("issuer")
            client_id = data.get("client_id")
            scopes = data.get("scopes")
            scope = (
                " ".join(scopes)
                if isinstance(scopes, list)
                else (scopes or " ".join(DEFAULT_SCOPES))
            )

            print(f"  - authorization_endpoint: {auth_uri}")
            print(f"  - token_endpoint: {token_uri}")
            print(f"  - issuer: {issuer}")
            print(f"  - client_id: {client_id}")
            print(f"  - scopes: {scope}")

            if auth_uri and token_uri and issuer and client_id:
                print("  ✓ .well-known discovery successful!")
                return {
                    "authorization_endpoint": auth_uri,
                    "token_endpoint": token_uri,
                    "issuer": issuer,
                    "scopes": scope,
                    "client_id": client_id,
                }
            else:
                print(
                    "  ✗ .well-known JSON missing required fields (auth_uri, token_uri, issuer, client_id)"
                )
        else:
            print(f"  - .well-known returned {rw.status_code} or wrong content type")
            if rw.text:
                print(f"  - Response body preview: {rw.text[:200]}...")
    except RequestException as e:
        print(f"  - .well-known fetch error: {e}")

    # If we reach here, we couldn't discover client_id—abort with clear message
    raise RuntimeError(
        "Could not discover OAuth settings from MCP URL. "
        "Ensure GET /mcp returns 401 with a WWW-Authenticate challenge that includes "
        "authorization_uri (with client_id), token_uri, issuer; OR provide "
        "/mcp/.well-known/oauth-client JSON with those fields."
    )


def main():
    parser = argparse.ArgumentParser(description="OAuth test client for MCP servers")
    parser.add_argument("mcp_url", help="MCP server URL to test OAuth against")
    args = parser.parse_args()

    mcp_url = args.mcp_url

    # 0) Discover from MCP
    info = discover_from_mcp(mcp_url)
    auth_ep = info["authorization_endpoint"]
    token_ep = info["token_endpoint"]
    issuer = info["issuer"]
    scope = info["scopes"]
    client_id = info["client_id"]

    print("\n== Discovery ==")
    print(" authorization_endpoint:", auth_ep)
    print(" token_endpoint:       ", token_ep)
    print(" issuer:               ", issuer)
    print(" client_id:            ", client_id)
    print(" scopes:               ", scope)

    # 1) Start local callback
    server = start_callback_server()
    print(f"\nCallback server listening on {LOCAL_CALLBACK}")

    # 2) PKCE
    verifier, challenge = make_pkce()
    state = b64url(os.urandom(16))

    # 3) Build authorize URL (reuse discovered auth_ep, but inject our redirect/state/pkce)
    #    Keep any existing query params from the discovered authorization_endpoint
    parsed = urllib.parse.urlparse(auth_ep)
    base_qs = urllib.parse.parse_qs(parsed.query)
    base_qs = {k: v[-1] if isinstance(v, list) else v for k, v in base_qs.items()}
    # Force required params (client_id should already be present from discovery header/JSON)
    base_qs.update(
        {
            "client_id": client_id,
            "response_type": "code",
            "redirect_uri": LOCAL_CALLBACK,
            "scope": scope,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": state,
        }
    )
    final_auth_url = urllib.parse.urlunparse(
        (
            parsed.scheme,
            parsed.netloc,
            parsed.path,
            parsed.params,
            urllib.parse.urlencode(base_qs),
            parsed.fragment,
        )
    )

    print("\nOpen this URL to sign in:")
    print(final_auth_url, "\n")
    if OPEN_BROWSER:
        webbrowser.open(final_auth_url)

    # 4) Wait for callback
    print("Waiting for login to complete in the browser...")
    deadline = time.time() + TIMEOUT_LOGIN_SEC
    while time.time() < deadline and not (AUTH_RESULT.code or AUTH_RESULT.error):
        time.sleep(0.2)

    if AUTH_RESULT.error:
        print(
            f"\nERROR from authorize: {AUTH_RESULT.error} :: {AUTH_RESULT.error_description or ''}"
        )
        server.shutdown()
        return
    if not AUTH_RESULT.code:
        print("\nTimed out waiting for auth code.")
        server.shutdown()
        return

    print(f"\nGot authorization code: {AUTH_RESULT.code[:8]}...")

    # 5) Token exchange
    data = {
        "grant_type": "authorization_code",
        "client_id": client_id,
        "code": AUTH_RESULT.code,
        "redirect_uri": LOCAL_CALLBACK,
        "code_verifier": verifier,
    }
    try:
        resp = requests.post(
            token_ep,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            data=data,
            timeout=20,
        )
        resp.raise_for_status()
    except RequestException as e:
        print(
            "\nToken exchange failed:",
            e,
            "\nResponse:",
            getattr(e, "response", None) and getattr(e.response, "text", ""),
        )
        server.shutdown()
        return

    tokens = resp.json()
    access_token = tokens.get("access_token")
    id_token = tokens.get("id_token")
    print("\nTokens received:")
    print(" - access_token:", "<present>" if access_token else "<missing>")
    print(" - id_token:    ", "<present>" if id_token else "<missing>")

    # 6) Decode & show claims
    claims = decode_jwt_noverify(access_token or "")
    print("\nAccess token claims (decoded, unsigned):")
    print(json.dumps(claims, indent=2))

    # 7) Call MCP via POST
    try:
        ping = {"jsonrpc": "2.0", "id": "1", "method": "ping", "params": {}}
        r = requests.post(
            mcp_url,
            headers={
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            json=ping,
            timeout=30,
        )
        print("\nMCP POST status:", r.status_code)
        print("MCP POST body:  ", r.text[:1000])
    except RequestException as e:
        print("\nMCP POST failed:", e)

    # 8) Try SSE (may not be supported on same path)
    try:
        print("\nTrying SSE GET (may hang if unsupported). Ctrl+C to skip.")
        with requests.get(
            mcp_url,
            headers={
                "Authorization": f"Bearer {access_token}",
                "Accept": "text/event-stream",
            },
            stream=True,
            timeout=15,
        ) as s:
            print("SSE response status:", s.status_code)
            if s.status_code == 200:
                for i, line in enumerate(s.iter_lines(decode_unicode=True)):
                    if line:
                        print("SSE:", line)
                    if i > 10:
                        break
            else:
                print("SSE not supported or different path required.")
    except Exception as e:
        print("SSE attempt error:", e)

    server.shutdown()
    print("\nDone.")


if __name__ == "__main__":
    main()
