from __future__ import annotations

from unittest.mock import AsyncMock, patch

import httpx
import pytest

import server_http


@pytest.mark.asyncio
async def test_get_app_exposes_mcp_routes(monkeypatch):
    # Default CORS ("*")
    monkeypatch.delenv("CORS_ORIGINS", raising=False)

    app = server_http.get_app()

    # Ensure the expected MCP endpoints are present
    routes = [getattr(r, "path", str(r)) for r in app.router.routes]
    assert "/sse" in routes
    assert "/messages" in routes


@pytest.mark.asyncio
async def test_cors_default_allows_any_origin(monkeypatch):
    # Default behavior: allow all origins
    monkeypatch.delenv("CORS_ORIGINS", raising=False)
    app = server_http.get_app()

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test", timeout=2.0
    ) as client:
        # Preflight request to /messages should be handled by CORS middleware
        r = await client.request(
            "OPTIONS",
            "/messages",
            headers={
                "Origin": "https://any.origin",
                "Access-Control-Request-Method": "POST",
            },
        )
        assert r.status_code in (200, 204)
        # With allow_credentials=True, Starlette echoes the Origin rather than '*'
        assert r.headers.get("access-control-allow-origin") in {
            "*",
            "https://any.origin",
        }


@pytest.mark.asyncio
async def test_cors_custom_origins(monkeypatch):
    monkeypatch.setenv("CORS_ORIGINS", "https://example.com, https://foo.bar")
    app = server_http.get_app()

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test", timeout=2.0
    ) as client:
        r = await client.request(
            "OPTIONS",
            "/messages",
            headers={
                "Origin": "https://example.com",
                "Access-Control-Request-Method": "POST",
            },
        )
        assert r.status_code in (200, 204)
        # With explicit origins, the CORS middleware should echo the allowed origin
        assert r.headers.get("access-control-allow-origin") == "https://example.com"


@pytest.mark.asyncio
async def test_shutdown_closes_http_client(monkeypatch):
    # Patch the underlying httpx client to observe aclose during lifespan shutdown
    async_mock = AsyncMock()
    monkeypatch.setenv("CORS_ORIGINS", "*")

    with patch("server._http.aclose", async_mock):
        app = server_http.get_app()
        # Touch an endpoint so the app is used at least once
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test", timeout=2.0
        ) as client:
            # Touch a non-streaming endpoint (CORS preflight) to exercise the app
            await client.request(
                "OPTIONS",
                "/messages",
                headers={
                    "Origin": "https://any.origin",
                    "Access-Control-Request-Method": "POST",
                },
            )

        # Explicitly close the client; ASGITransport doesn't handle lifespan here
        await server_http.close_http_client()

    async_mock.assert_awaited()
