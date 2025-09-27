#!/usr/bin/env bash
set -euo pipefail

# Generate tool schema JSON for AgentCore Gateway from the local stdio MCP server.
# Requires Node/npm on the build machine.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v npx >/dev/null 2>&1; then
  echo "npx not found. Install Node.js/npm." >&2
  exit 2
fi

# Allow user to override env; defaults are placeholders
export GOOGLE_API_KEY="${GOOGLE_API_KEY:-placeholder}"
export GOOGLE_CX="${GOOGLE_CX:-placeholder}"

npx @modelcontextprotocol/inspector --cli --method tools/list \
  uvx --from . google-search-mcp > tool-schema.json

echo "Wrote tool-schema.json"
