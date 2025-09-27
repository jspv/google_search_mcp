# Google Search MCP Server

A Model Context Protocol (MCP) server that provides Google Custom Search functionality.

## Configuration

This server uses [Dynaconf](https://www.dynaconf.com/) for configuration management, supporting both `.env` files and environment variables.

### Setup

1. Copy the example environment file:
   ```bash
   cp .env.example .env
   ```

2. Edit `.env` and add your Google API credentials:
   ```bash
   GOOGLE_API_KEY=your_actual_api_key_here
   GOOGLE_CX=your_custom_search_engine_id_here
   ```

### Environment Variable Override

Environment variables will **override** `.env` file values when both are present. This allows for flexible deployment scenarios:

- **Development**: Use `.env` file for local development
- **Production**: Use environment variables for production deployment
- **CI/CD**: Environment variables can override defaults for testing

#### Example:

If your `.env` file contains:
```bash
GOOGLE_API_KEY=dev_key_from_file
```

And you set an environment variable:
```bash
export GOOGLE_API_KEY=prod_key_from_env
```

The server will use `prod_key_from_env` (environment variable takes precedence).

### Required Configuration

- `GOOGLE_API_KEY`: Your Google Custom Search API key
- `GOOGLE_CX`: Your Custom Search Engine ID

Get these from:
- API Key: [Google Cloud Console](https://console.developers.google.com/)
- Search Engine ID: [Google Custom Search](https://cse.google.com/cse/all)

### Optional Configuration

- `ALLOW_DOMAINS` (`GOOGLE_ALLOW_DOMAINS` env var): Comma-separated list of allowed domains (e.g., `example.com, docs.python.org`).
   When set, results outside these domains are filtered out.

- Logging:
   - `LOG_QUERIES` (`GOOGLE_LOG_QUERIES`): Enable logging of query hash, timing, and key params.
   - `LOG_QUERY_TEXT` (`GOOGLE_LOG_QUERY_TEXT`): Also log full query text (off by default).
   - `LOG_LEVEL` (`GOOGLE_LOG_LEVEL`): Set logging level (e.g., `INFO`, `DEBUG`).
   - `LOG_FILE` (`GOOGLE_LOG_FILE`): Optional path to also write logs to a file (stderr remains enabled).

## Usage

Run the server:
```bash
python server.py
```

### Web-based MCP (SSE)

If you are integrating with a browser or any client that uses MCP over HTTP/SSE, run the web server variant:

```bash
# Install HTTP extras
uv sync --extra http

# Start the SSE MCP server (defaults to 127.0.0.1:8000)
uv run google-search-mcp-http

# Or run directly
uv run python -m server_http
```

This exposes the standard MCP endpoints used by web clients:
- GET /sse (Server-Sent Events connection)
- POST /messages (MCP messages)

Notes:
- CORS is enabled by default (CORS_ORIGINS="*"). Customize with `CORS_ORIGINS` env var.
- Same configuration applies as stdio mode (`GOOGLE_API_KEY`, `GOOGLE_CX`, logging flags, etc.).

### Run via uvx (no activation, from any folder)

The project exposes a console script `google-search-mcp` so you can run it with `uvx` without activating a venv:

```bash
# Run using the repo as the source
uvx --from /Users/justin/src/google_search_mcp google-search-mcp

# If you need .env loading, either run with cwd set to the repo
(cd /Users/justin/src/google_search_mcp && uvx --from . google-search-mcp)

# Or point Dynaconf directly at the .env
DYNACONF_DOTENV_PATH=/Users/justin/src/google_search_mcp/.env \
uvx --from /Users/justin/src/google_search_mcp google-search-mcp
```

### Run via pipx (isolated, globally available)

You can also install and run the script with pipx:

```bash
# Install from local path
pipx install /Users/justin/src/google_search_mcp

# Or from a VCS URL (example)
# pipx install git+https://github.com/jspv/google_search_mcp.git

# Run the server
google-search-mcp

# If you rely on .env, run it from the repo directory or set DYNACONF_DOTENV_PATH
cd /Users/justin/src/google_search_mcp && google-search-mcp
# or
DYNACONF_DOTENV_PATH=/Users/justin/src/google_search_mcp/.env google-search-mcp
```

## Quick start

This project uses httpx with HTTP/2 support enabled for better performance. The dependency is declared as `httpx[http2]` and will install the `h2` package automatically when you sync the environment.

### Using uv (recommended)

```bash
# Install deps from pyproject/lockfile
uv sync

# Create and fill in your configuration
cp .env.example .env
$EDITOR .env

# Run tests (optional sanity check)
uv run pytest -q

# Start the MCP server
uv run python server.py
```

### Try it quickly (no MCP client required)

You can also call the tool function directly for a quick smoke test (uses your env vars):

```bash
uv run python -c 'import asyncio, server; print(asyncio.run(server.search("site:python.org httpx", num=2, safe="off")))'
```

Note: When using the MCP server with a client, the `search` tool parameters follow Google CSE semantics. In particular, `safe` must be one of `off` or `active`, and `num` is clamped to the CSE maximum of 10.

### Logging behavior

If `LOG_QUERIES` is enabled, the server will write a single line per request to stdout containing:
- q_hash (short, non-reversible hash of the query), dt_ms (latency), num, start, safe, and endpoint (cse/siterestrict)
- If `LOG_QUERY_TEXT` is true, it also includes the full `q` text.

Example log line:

```
2025-09-27T12:34:56+0000 INFO google_search_mcp: search q_hash=1a2b3c4d dt_ms=123 num=5 start=1 safe=off endpoint=cse q="site:python.org httpx"
```

When a client spawns the server via `uvx`, logs go to the server process’s stderr by default (safe for MCP stdio). To persist logs regardless of the client’s stderr handling:

- Set a file path (absolute recommended):
   ```
   GOOGLE_LOG_QUERIES=true
   GOOGLE_LOG_FILE=/var/log/google_search_mcp.log
   ```
- Or redirect stderr in the launch command:
   ```
   uvx --from /path/to/repo google-search-mcp 2>> /tmp/google_search_mcp.log
   ```

## Streamable HTTP Variant

For clients that use StreamableHttpServerParams (non-SSE MCP over HTTP), run the Streamable HTTP server variant:

```bash
# Ensure HTTP extras are installed
uv sync --extra http

# Start the Streamable MCP server
uv run google-search-mcp-stream

# Or run directly
uv run python -m server_http_stream
```

Client usage example with the official MCP streamable HTTP transport:

```python
import asyncio
from mcp.client.session import ClientSession
from mcp.client.streamable_http import streamable_http_client


async def main():
   async with streamable_http_client("http://127.0.0.1:8000") as (read, write):
      async with ClientSession(read, write) as session:
         await session.initialize()
         tools = await session.list_tools()
         print([t.name for t in tools.tools])


if __name__ == "__main__":
   asyncio.run(main())
```

Notes:
- Endpoints are managed by FastMCP; you should not call `/sse` for this variant.
- CORS is enabled and configurable with `CORS_ORIGINS`.
