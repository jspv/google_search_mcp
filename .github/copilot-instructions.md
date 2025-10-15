# Copilot instructions for google_search_mcp

Purpose: Give AI coding agents the minimum, high‑signal context to work productively in this repo.

## What this repo is
- An MCP server exposing one tool: Google Programmable Search (CSE).
- Same logic runs in 3 surfaces: stdio (default), HTTP over SSE, and Streamable HTTP; plus adapters for AWS Lambda and containers.

## Architecture (files you’ll touch)
- `server.py` — FastMCP server with a single tool `@mcp.tool() async def search(...)`. Uses one shared `httpx.AsyncClient` `_http` (HTTP/2). Config via Dynaconf (`GOOGLE_*`). Import‑time check requires `GOOGLE_API_KEY` and `GOOGLE_CX`.
  - Behavior: `num` clamped 1..10, `safe` must be `off|active`, optional `ALLOW_DOMAINS` filter, lean responses via `fields` when `lean_fields=True`.
  - Return shape (do not change casually): `{provider, query, searchInfo, nextPage, latency_ms, results[], raw, trace}`. Secrets are never echoed (no API key; `cx` omitted).
- `server_http.py` — ASGI SSE app from the same `mcp` instance; exposes standard MCP endpoints `/sse` and `/messages` (not a custom REST API). CORS via `CORS_ORIGINS` ("*" default). On shutdown, awaits `_http.aclose()`.
- `server_http_stream.py` — Streamable HTTP transport variant; same CORS and shutdown behavior.
- `lambda_handler.py` — Bridges Bedrock AgentCore Gateway to the stdio server by spawning `python -m server` and explicitly passing env.
- `Dockerfile.mcp` — Multi‑mode container; `MCP_MODE=stdio|http|http-stream` (port 8000 by default).
- Schema tooling: `scripts/dump_tool_schema.py` and `deploy_aws_agentcore_auth0/gen_tool_schema.sh`.

## Workflows
- Install deps: `uv sync` (+ extras as needed: `--extra http`, `--extra lambda`, `--extra container`).
- Run servers: `uv run python -m server` | `HOST=0.0.0.0 PORT=8000 uv run python -m server_http` | `uv run python -m server_http_stream`.
- Tests: `uv run pytest -q` (VS Code Task: “Run tests”). Tests patch env and mock HTTP; no real Google calls.

## Conventions and patterns
- Always reuse the global `_http` client; do not create per‑request clients. Ensure it’s closed on app shutdown (tests assert `aclose()` awaited).
- No custom REST endpoints; only MCP transports. For middleware, attach to the Starlette app in `get_app()`.
- Config precedence: environment variables override `.env` (Dynaconf). `DYNACONF_DOTENV_PATH` is honored.
- Logging is opt‑in via `GOOGLE_LOG_*`: logs go to stderr by default; optionally to `GOOGLE_LOG_FILE`. Query text is logged only if `GOOGLE_LOG_QUERY_TEXT=true` (hash otherwise).

## Adding tools (pattern)
- Define new tools in `server.py` to share config and `_http`:
  ```python
  @mcp.tool()
  async def my_tool(arg: str) -> dict:
      # Reuse shared client, mirror logging/return-shape norms
      return {"ok": True, "echo": arg}
  ```
- Keep returns JSON‑serializable; avoid echoing secrets. If you add required settings, update `tests/conftest.py` so imports don’t fail.

## Gotchas (tests enforce these)
- Import‑time env required (`GOOGLE_API_KEY`, `GOOGLE_CX`) — set before launching servers or scripts.
- CORS: default `"*"`; with credentials, Starlette echoes the Origin. Preflight behavior is asserted in `tests/test_server_http*.py`.
- Search shape and input hygiene are validated by tests; changing response fields or relaxing validation will fail tests.

Questions or unclear areas (e.g., expanding result shapes, adding params, or wiring a new transport)? Say which file/area you’re touching and we’ll refine the rules.
