import json
import os
import time
from typing import Any

import boto3
from botocore.exceptions import ClientError

"""
OAuth 2.0 Dynamic Client Registration (RFC 7591) - minimal implementation
backed by Amazon Cognito User Pool App Clients.

Expose this Lambda behind an API Gateway route or Lambda Function URL
as POST /register. It:
- Optionally enforces an Initial Access Token (RFC 7591 style)
- Creates a Cognito User Pool App Client matching requested grants/scopes
- Returns client_id/client_secret in an RFC-like response

Environment variables:
- USER_POOL_ID (required): Cognito User Pool ID, e.g. us-east-1_XXXXXXXXX
- DEFAULT_SCOPES (optional): Space-delimited scopes if none provided
    (e.g. "openid profile")
- SUPPORTED_IDPS (optional): Comma-delimited; default 'COGNITO'
- REQUIRE_INITIAL_ACCESS_TOKEN (optional): 'true'|'false' (default: 'true')
- INITIAL_ACCESS_TOKEN (optional): Bearer token if REQUIRE_INITIAL_ACCESS_TOKEN=true
- ALLOW_AUTH_CODE (optional): 'true'|'false' (default: 'false')
- ALLOW_CLIENT_CREDENTIALS (optional): 'true'|'false' (default: 'true')
- CORS_ALLOW_ORIGIN (optional): '*' by default

Notes:
- This is a pragmatic mapping to Cognito; not all RFC 7591 fields are supported.
- For machine-to-machine Gateway usage, client_credentials is the typical grant.
"""


def _json(body: dict[str, Any], status: int = 200):
    headers = {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": os.environ.get("CORS_ALLOW_ORIGIN", "*"),
        "Access-Control-Allow-Headers": "authorization,content-type",
        "Access-Control-Allow-Methods": "POST,OPTIONS",
    }
    return {"statusCode": status, "headers": headers, "body": json.dumps(body)}


def _parse_bearer(auth: str | None) -> str | None:
    if not auth:
        return None
    parts = auth.split()
    if len(parts) == 2 and parts[0].lower() == "bearer":
        return parts[1]
    return None


def _bool_env(name: str, default: bool) -> bool:
    val = os.environ.get(name)
    if val is None:
        return default
    return str(val).lower() in {"1", "true", "yes", "y", "on"}


def _to_scopes(scope_str: str | None) -> list[str]:
    if not scope_str:
        return []
    return [s for s in scope_str.split() if s]


def handler(event, context):
    # Health ping support and CORS preflight
    if isinstance(event, dict):
        if event.get("httpMethod") == "OPTIONS":
            return _json({"status": "ok"}, 200)
        if event.get("ping") or event.get("health"):
            return _json(
                {"status": "ok", "handler": "oauth-dcr", "ts": int(time.time())}
            )

    user_pool_id = os.environ.get("USER_POOL_ID")
    if not user_pool_id:
        return _json(
            {
                "error": "server_error",
                "error_description": "Missing USER_POOL_ID",
            },
            500,
        )

    require_iat = _bool_env("REQUIRE_INITIAL_ACCESS_TOKEN", True)
    expected_iat = os.environ.get("INITIAL_ACCESS_TOKEN")

    # Normalize headers
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    provided_token = _parse_bearer(
        headers.get("authorization") or headers.get("Authorization")
    )

    if require_iat:
        if not expected_iat:
            return _json(
                {
                    "error": "server_error",
                    "error_description": "Missing INITIAL_ACCESS_TOKEN in env",
                },
                500,
            )
        if provided_token != expected_iat:
            return _json(
                {
                    "error": "invalid_token",
                    "error_description": "Invalid or missing initial access token",
                },
                401,
            )

    # Parse body
    try:
        body_raw = event.get("body") or "{}"
        if event.get("isBase64Encoded"):
            # API Gateway v1/v2 may set this; assume utf-8 input
            body_raw = body_raw  # leave as-is; relying on API GW decoding if set
        req = json.loads(body_raw) if isinstance(body_raw, str) else (body_raw or {})
    except Exception:
        return _json(
            {
                "error": "invalid_client_metadata",
                "error_description": "Invalid JSON body",
            },
            400,
        )

    # RFC 7591 fields
    client_name = req.get("client_name") or f"registered-client-{int(time.time())}"
    redirect_uris: list[str] = req.get("redirect_uris") or []
    token_endpoint_auth_method = (
        req.get("token_endpoint_auth_method") or "client_secret_basic"
    ).lower()
    grant_types: list[str] = req.get("grant_types") or ["client_credentials"]
    scope_str = req.get("scope") or os.environ.get("DEFAULT_SCOPES", "openid")
    scopes = _to_scopes(scope_str)

    allow_auth_code = _bool_env("ALLOW_AUTH_CODE", False)
    allow_client_credentials = _bool_env("ALLOW_CLIENT_CREDENTIALS", True)

    # Map RFC grant_types -> Cognito AllowedOAuthFlows
    allowed_oauth_flows: list[str] = []
    if allow_auth_code and (
        "authorization_code" in grant_types
        or "authorization-code" in [g.replace("_", "-") for g in grant_types]
    ):
        allowed_oauth_flows.append("code")
    if allow_client_credentials and ("client_credentials" in grant_types):
        allowed_oauth_flows.append("client_credentials")
    # We generally avoid implicit for security; add only if explicitly requested
    # AND auth_code is allowed
    if allow_auth_code and ("implicit" in grant_types):
        allowed_oauth_flows.append("implicit")

    if not allowed_oauth_flows:
        # Default to client_credentials if allowed, else reject
        if allow_client_credentials:
            allowed_oauth_flows = ["client_credentials"]
        else:
            return _json(
                {
                    "error": "unsupported_grant_type",
                    "error_description": "No allowed grant types",
                },
                400,
            )

    # Auth method -> GenerateSecret
    generate_secret = token_endpoint_auth_method in {
        "client_secret_basic",
        "client_secret_post",
    }

    # Supported identity providers
    supported_idps_env = os.environ.get("SUPPORTED_IDPS", "COGNITO")
    supported_idps = [p.strip() for p in supported_idps_env.split(",") if p.strip()]

    # Build Cognito params
    params: dict[str, Any] = {
        "UserPoolId": user_pool_id,
        "ClientName": client_name,
        "GenerateSecret": generate_secret,
        "AllowedOAuthFlowsUserPoolClient": True,
        "AllowedOAuthFlows": allowed_oauth_flows,
        "SupportedIdentityProviders": supported_idps,
    }

    if scopes:
        params["AllowedOAuthScopes"] = scopes
    if redirect_uris:
        # Only relevant for code/implicit
        params["CallbackURLs"] = redirect_uris

    # Create client
    try:
        cognito = boto3.client("cognito-idp")
        resp = cognito.create_user_pool_client(**params)
        client = resp.get("UserPoolClient", {})
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "ClientError")
        return _json(
            {"error": "server_error", "error_description": f"Cognito error: {code}"},
            500,
        )
    except Exception as e:
        return _json({"error": "server_error", "error_description": str(e)}, 500)

    # Shape RFC 7591-like response
    out: dict[str, Any] = {
        "client_id": client.get("ClientId"),
        "client_id_issued_at": int(time.time()),
        "client_name": client_name,
        "token_endpoint_auth_method": token_endpoint_auth_method,
        "grant_types": grant_types,
        "scope": " ".join(scopes) if scopes else "",
        "redirect_uris": redirect_uris,
    }
    if generate_secret and client.get("ClientSecret"):
        out["client_secret"] = client.get("ClientSecret")

    return _json(out, 201)
