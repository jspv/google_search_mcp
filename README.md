# Google Search MCP Server

A Model Context Protocol (MCP) server that provides Google Custom Search functionality.

<a href="https://glama.ai/mcp/servers/@jspv/google_search_mcp">
  <img width="380" height="200" src="https://glama.ai/mcp/servers/@jspv/google_search_mcp/badge" alt="Google Search Server MCP server" />
</a>

**🎯 This repository demonstrates 5 different deployment patterns** for the same MCP functionality:

1. **[stdio Mode](#1-stdio-mode-default-mcp)** - Standard MCP over stdin/stdout for local development and MCP client integration
2. **[HTTP over SSE](#2-http-over-sse-mcp-transport)** - MCP HTTP transport using Server‑Sent Events (browser-friendly)
3. **[HTTP Streamable](#3-http-streamable-non-sse)** - MCP Streamable HTTP transport (non‑SSE)
4. **[AWS Lambda + AgentCore Gateway](#4-aws-lambda--agentcore-gateway)** - Serverless deployment with OAuth authentication
5. **[Containerized MCP Service](#5-containerized-mcp-service)** - Docker containers deployed to ECS Fargate for scalable cloud deployment

## Installation

Clone the repository and install dependencies:

```bash
git clone https://github.com/jspv/google-search-mcp.git
cd google-search-mcp
uv sync
```

## Project structure

- `server.py` / `server_http.py` / `server_http_stream.py` — MCP servers (stdio, HTTP, streaming)
- `lambda_handler.py` — AWS Lambda adapter for MCP stdio server
- `Dockerfile.mcp` — Container image for HTTP/streaming MCP service
- `deploy/` — legacy deployment assets (use `deploy_aws_agentcore_auth0/`)
- `deploy_aws_agentcore_auth0/` — canonical Auth0 + AgentCore Gateway deploy scripts and templates
   - `build_zip.sh` — build Lambda ZIP
   - `deploy_lambda.sh` — deploy Lambda via CloudFormation
   - `AGENTCORE_GATEWAY_CHECKLIST.md` — complete Gateway (Lambda + Cognito) integration checklist
   
   - `deploy_gateway.sh` — attempt AgentCore setup via CLI
   - `gen_tool_schema.sh` — generate MCP tool schema (uses Python stdio client)
   - `cloudformation-*.yaml` — infrastructure templates
   - `README-*.md` — deployment-specific docs
- `scripts/` — developer/CI utilities
   - `dump_tool_schema.py` — dump schema from an MCP server over stdio
- `dist/` — build artifacts and generated outputs
   - `schema/tool-schema.json` — generated tool schema for AgentCore
   - `google_search_mcp_lambda.zip` — built Lambda package
- `tests/` — unit and integration tests


### Optional Dependencies

Install additional dependencies based on your deployment needs:

```bash
# For HTTP/streaming modes
uv sync --extra http

# For AWS Lambda deployment
uv sync --extra lambda

# For containerized deployments (ECS/Fargate)
uv sync --extra container

# For AWS (both Lambda and container)
uv sync --extra aws

# For development
uv sync --extra dev

# Install multiple extras
uv sync --extra http --extra aws --extra dev
```

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

This project provides 5 different deployment patterns for the same Google Search MCP functionality:

### 1. stdio Mode (Default MCP)

Standard MCP server for local development and integration with MCP clients:

```bash
# Run via uv (recommended)
uv run python -m server

# Or direct execution
python server.py

# Run via uvx (no activation, from any folder)
uvx --from /Users/justin/src/google_search_mcp google-search-mcp

# Run via pipx (isolated, globally available)
pipx install /Users/justin/src/google_search_mcp
google-search-mcp
```

Communicates over stdin/stdout using the standard MCP protocol.

### 2. HTTP over SSE (MCP transport)

MCP over HTTP using Server‑Sent Events (SSE). This exposes the standard MCP HTTP endpoints used by browser clients.

```bash
# Install HTTP extras and run
uv sync --extra http
uv run python -m server_http

# Or via console script (if installed)
uv run google-search-mcp-http

# With custom host/port
HOST=0.0.0.0 PORT=8000 uv run python -m server_http
```

Available MCP endpoints (not a custom REST API):
- `GET /sse` — SSE connection for events
- `POST /messages` — MCP message handling

Notes:
- CORS enabled by default (customize with `CORS_ORIGINS`).
- Same configuration as stdio mode (`GOOGLE_API_KEY`, `GOOGLE_CX`, etc.).

### 3. HTTP Streamable (non‑SSE)

MCP Streamable HTTP transport for clients that don't use SSE.

```bash
# Start the Streamable HTTP MCP server
uv sync --extra http
uv run python -m server_http_stream

# Or via console script (if installed)
uv run google-search-mcp-stream

# Custom host/port
HOST=0.0.0.0 PORT=8000 uv run python -m server_http_stream
```

Notes:
- Not a REST interface. Use an MCP client that supports the Streamable HTTP transport.
- CORS behavior matches the SSE app and is configurable via `CORS_ORIGINS`.

### 4. AWS Lambda + AgentCore Gateway

**Prerequisites**: 
```bash
# Install Lambda dependencies
uv sync --extra lambda

# Configure AWS credentials
aws configure
```

Deploy to AWS Lambda with Bedrock AgentCore Gateway integration:

```bash
# Build and deploy
./deploy_aws_agentcore_auth0/build_zip.sh        # Cross-platform build
./deploy_aws_agentcore_auth0/deploy_lambda.sh    # Deploy via CloudFormation
./deploy_aws_agentcore_auth0/deploy_gateway.sh # Setup AgentCore Gateway

# Test the deployment
python3 deploy_aws_agentcore_auth0/test_gateway_auth0.py https://your-gateway-url.amazonaws.com client-id client_secret https://your-domain.auth0.com [audience]
```

Features:
- JSON-RPC 2.0 protocol with OAuth authentication
- Serverless execution with environment variable inheritance
- Integrated with AWS Bedrock AgentCore ecosystem

### 5. Containerized MCP Service

**Prerequisites**:
```bash
# Install container dependencies (for ECR/ECS deployment)
uv sync --extra container

# Configure Docker and AWS
docker --version
aws configure
```

**Local Testing**:
```bash
# Build container
docker build -f Dockerfile.mcp -t google-search-mcp .

# Run locally
docker run -p 8000:8000 --env-file .env -e MCP_MODE=http-stream google-search-mcp
```

**Deploy to AWS ECS Fargate**:
```bash
# Deploy to ECS Fargate
./deploy/deploy_mcp_container.sh google-search-mcp us-east-1 ecs-fargate
```

Features:
- Multi-mode container supporting stdio, HTTP, and streaming
- Scalable deployment via ECS Fargate
- Environment variable configuration
- Health checks and monitoring

**Note**: AgentCore Runtime uses preview SDK and requires manual configuration as APIs are not publicly available.

### Configuration Notes

All deployment patterns use the same configuration:
- Set `DYNACONF_DOTENV_PATH` for .env loading when needed
- Environment variables override settings.toml values
- Logging configuration applies across all modes

## Quick Start

This project uses httpx with HTTP/2 support enabled. The dependency is declared as `httpx[http2]` and will install the `h2` package automatically.

### Using uv (recommended)

```bash
# Install dependencies
uv sync

# Create and configure environment
cp .env.example .env
$EDITOR .env

# Run tests (optional sanity check)
uv run pytest -q

# Start the MCP server (stdio mode)
uv run python server.py
```

### Quick Test (no MCP client required)

Test the search function directly:

```bash
uv run python -c 'import asyncio, server; print(asyncio.run(server.search("site:python.org httpx", num=2, safe="off")))'
```

Note: `safe` must be `off` or `active`, and `num` is clamped to maximum of 10 per Google CSE limits.

### Logging behavior

If `LOG_QUERIES` is enabled, the server will write a single line per request to stdout containing:
- q_hash (short, non-reversible hash of the query), dt_ms (latency), num, start, safe, and endpoint (cse/siterestrict)
- If `LOG_QUERY_TEXT` is true, it also includes the full `q` text.

Example log line:

```
2025-09-27T12:34:56+0000 INFO google_search_mcp: search q_hash=1a2b3c4d dt_ms=123 num=5 start=1 safe=off endpoint=cse q="site:python.org httpx"
```

When a client spawns the server via `uvx`, logs go to the server process's stderr by default (safe for MCP stdio). To persist logs regardless of the client's stderr handling:

- Set a file path (absolute recommended):
   ```
   GOOGLE_LOG_QUERIES=true
   GOOGLE_LOG_FILE=/var/log/google_search_mcp.log
   ```
- Or redirect stderr in the launch command:
   ```
   uvx --from /path/to/repo google-search-mcp 2>> /tmp/google_search_mcp.log
   ```

## Testing

### Unit Tests

Run the test suite to validate functionality:

```bash
# Run all tests
uv run pytest

# Run with quiet output
uv run pytest -q

# Run specific test files
uv run pytest tests/test_server.py
uv run pytest tests/test_server_http.py
```

## Testing

## Testing

The project includes a comprehensive test suite located in the `tests/` directory. All tests use pytest and mock external dependencies for reliable, fast execution.

### Unit Tests

Run the comprehensive test suite to validate functionality:

```bash
# Run all tests
uv run pytest

# Run with quiet output
uv run pytest -q

# Run specific test modules
uv run pytest tests/test_server.py              # Core MCP server functionality  
uv run pytest tests/test_server_http.py         # HTTP endpoint testing
uv run pytest tests/test_server_http_stream.py  # HTTP streaming testing
uv run pytest tests/test_client.py              # Client integration
uv run pytest tests/test_logging.py             # Logging configuration
```

### Local Testing

Use an MCP client (e.g., Inspector or your app) that supports SSE or Streamable HTTP transports. There is no custom REST `list_tools`/`call_tool` in this server.

### AWS Gateway Testing

For AWS AgentCore Gateway deployments, use the dedicated test script:

```bash
# Test gateway with authentication
python3 deploy_aws_agentcore_auth0/test_gateway_auth0.py \
   "https://your-gateway.amazonaws.com/mcp" \
   "client-id" \
   "client-secret" \
   "https://your-domain.auth0.com" \
   "https://your-gateway.amazonaws.com/mcp"  # audience (optional depending on IdP)
```

This validates authentication, tool listing, and tool execution through the gateway.

## Deployment Details

### AWS Lambda + AgentCore Gateway
- Uses JSON-RPC 2.0 protocol with OAuth authentication
- Cognito client credentials flow required
- Manual console configuration for compute targets and MCP providers (APIs not publicly available)
- See [`deploy/README-lambda-zip.md`](deploy/README-lambda-zip.md) for detailed instructions (use scripts under `deploy_aws_agentcore_auth0/`)

### AWS AgentCore Runtime  
- Uses preview AgentCore SDK (placeholder implementation)
- Requires manual configuration as APIs are not publicly available
- Container-based deployment via ECR integration
- Provides persistent sessions with microVM isolation