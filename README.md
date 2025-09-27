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

## Usage

Run the server:
```bash
python server.py
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
