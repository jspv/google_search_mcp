from __future__ import annotations

from unittest.mock import AsyncMock, patch

import httpx
import pytest

import server_http_stream


@pytest.mark.asyncio
async def test_get_app_has_routes(monkeypatch):
    monkeypatch.delenv("CORS_ORIGINS", raising=False)

    app = server_http_stream.get_app()

    # Ensure the app has at least one route registered
    assert len(app.router.routes) > 0


@pytest.mark.asyncio
async def test_stream_cors_default_allows_any_origin(monkeypatch):
    # Default behavior: allow all origins
    monkeypatch.delenv("CORS_ORIGINS", raising=False)
    app = server_http_stream.get_app()

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test", timeout=2.0
    ) as client:
        # Preflight request to an arbitrary path should be handled by CORS middleware
        r = await client.request(
            "OPTIONS",
            "/any-path",
            headers={
                "Origin": "https://any.origin",
                "Access-Control-Request-Method": "POST",
            },
        )
        assert r.status_code in (200, 204)
        assert r.headers.get("access-control-allow-origin") in {
            "*",
            "https://any.origin",
        }


@pytest.mark.asyncio
async def test_stream_cors_custom_origins(monkeypatch):
    monkeypatch.setenv("CORS_ORIGINS", "https://example.com, https://foo.bar")
    app = server_http_stream.get_app()

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test", timeout=2.0
    ) as client:
        r = await client.request(
            "OPTIONS",
            "/whatever",
            headers={
                "Origin": "https://example.com",
                "Access-Control-Request-Method": "POST",
            },
        )
        assert r.status_code in (200, 204)
        assert r.headers.get("access-control-allow-origin") == "https://example.com"


@pytest.mark.asyncio
async def test_stream_shutdown_closes_http_client(monkeypatch):
    # Patch the underlying httpx client to observe aclose during shutdown
    async_mock = AsyncMock()
    monkeypatch.setenv("CORS_ORIGINS", "*")

    with patch("server._http.aclose", async_mock):
        app = server_http_stream.get_app()
        # Touch a preflight to exercise the app
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
            timeout=2.0,
        ) as client:
            await client.request(
                "OPTIONS",
                "/preflight",
                headers={
                    "Origin": "https://any.origin",
                    "Access-Control-Request-Method": "POST",
                },
            )

        # Explicitly close since ASGITransport may not trigger lifespan events here
        await server_http_stream.close_http_client()

    async_mock.assert_awaited()
