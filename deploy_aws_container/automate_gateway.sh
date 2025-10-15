#!/usr/bin/env bash
set -euo pipefail

# Deprecated shim: forward to canonical script in deploy_aws_agentcore_auth0/
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../deploy_aws_agentcore_auth0/deploy_gateway.sh"
if [[ ! -x "$TARGET" ]]; then
  echo "ERROR: Canonical script not found at $TARGET" >&2
  exit 1
fi
echo "[DEPRECATED] Use deploy_aws_agentcore_auth0/deploy_gateway.sh instead." >&2
exec "$TARGET" "$@"