#!/usr/bin/env python3
"""
Web-based MCP server (Streamable HTTP) using FastMCP's built-in ASGI app.

This serves the MCP protocol over plain HTTP (no SSE), suitable for clients that
use StreamableHttp transports. It reuses the same tools and configuration from
server.py.

Configuration:
- CORS_ORIGINS: comma-separated list or "*" (default) to allow all origins.
- HOST / PORT: bind address (defaults 127.0.0.1:8000).

Run via console script (if installed):
    google-search-mcp-stream

Or directly:
    python -m server_http_stream
"""

from __future__ import annotations

import os

import uvicorn
from starlette.middleware.cors import CORSMiddleware

import server as mcp_server


def get_app():
    """Return the FastMCP Streamable HTTP ASGI app with optional CORS."""
    app = mcp_server.mcp.streamable_http_app()

    cors_origins = os.environ.get("CORS_ORIGINS", "*")
    origins = (
        ["*"]
        if cors_origins.strip() == "*"
        else [o.strip() for o in cors_origins.split(",") if o.strip()]
    )
    if origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=origins,
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )

    app.add_event_handler("shutdown", close_http_client)
    return app


async def close_http_client() -> None:
    try:
        await mcp_server._http.aclose()  # type: ignore[attr-defined]
    except Exception:
        pass


def main() -> None:
    host = os.environ.get("HOST", "127.0.0.1")
    port_str = os.environ.get("PORT", "8000")
    try:
        port = int(port_str)
    except ValueError:
        port = 8000
    log_level = (os.environ.get("LOG_LEVEL") or "info").lower()
    uvicorn.run(
        "server_http_stream:get_app",
        factory=True,
        host=host,
        port=port,
        log_level=log_level,  # type: ignore[arg-type]
    )


if __name__ == "__main__":
    main()
