#!/usr/bin/env bash
set -euo pipefail

# Create or update the Lambda function from the built ZIP.
# Requirements:
# - AWS CLI configured
# - dist/google_search_mcp_lambda.zip present (run ./deploy/build_zip.sh first)
#
# Usage:
#   ./deploy/deploy_lambda.sh <function-name> <role-arn> [region]
#
# Env vars (optional):
#   GOOGLE_API_KEY, GOOGLE_CX, GOOGLE_LOG_LEVEL, GOOGLE_LOG_QUERIES, GOOGLE_LOG_QUERY_TEXT
#   TIMEOUT (default 60), MEMORY (default 512)
#
# Example:
#   ./deploy/deploy_lambda.sh google-search-mcp arn:aws:iam:123456789012:role/LambdaExec us-west-2 \
#     GOOGLE_API_KEY=... GOOGLE_CX=...

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_ZIP="$ROOT_DIR/dist/google_search_mcp_lambda.zip"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <function-name> <role-arn> [region]" >&2
  exit 2
fi

FUNC_NAME="$1"
ROLE_ARN="$2"
REGION="${3:-}"

AWSCMD=(aws)
if [[ -n "$REGION" ]]; then
  AWSCMD+=("--region" "$REGION")
fi

if [[ ! -f "$DIST_ZIP" ]]; then
  echo "ZIP not found at $DIST_ZIP; building..." >&2
  "$ROOT_DIR/deploy/build_zip.sh"
fi

TIMEOUT="${TIMEOUT:-60}"
MEMORY="${MEMORY:-512}"

# Compose env vars
declare -A VARS
[[ -n "${GOOGLE_API_KEY:-}" ]] && VARS[GOOGLE_API_KEY]="$GOOGLE_API_KEY"
[[ -n "${GOOGLE_CX:-}" ]] && VARS[GOOGLE_CX]="$GOOGLE_CX"
[[ -n "${GOOGLE_LOG_LEVEL:-}" ]] && VARS[GOOGLE_LOG_LEVEL]="$GOOGLE_LOG_LEVEL"
[[ -n "${GOOGLE_LOG_QUERIES:-}" ]] && VARS[GOOGLE_LOG_QUERIES]="$GOOGLE_LOG_QUERIES"
[[ -n "${GOOGLE_LOG_QUERY_TEXT:-}" ]] && VARS[GOOGLE_LOG_QUERY_TEXT]="$GOOGLE_LOG_QUERY_TEXT"

ENV_JSON="{\"Variables\":{"
FIRST=1
for k in "${!VARS[@]}"; do
  v=${VARS[$k]}
  if [[ $FIRST -eq 0 ]]; then ENV_JSON+=" , "; fi
  ENV_JSON+="\"$k\":\"$v\""
  FIRST=0
done
ENV_JSON+="}}"

set +e
${AWSCMD[@]} lambda get-function --function-name "$FUNC_NAME" >/dev/null 2>&1
EXISTS=$?
set -e

if [[ $EXISTS -ne 0 ]]; then
  echo "Creating Lambda function $FUNC_NAME ..."
  ${AWSCMD[@]} lambda create-function \
    --function-name "$FUNC_NAME" \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler lambda_handler.handler \
    --timeout "$TIMEOUT" \
    --memory-size "$MEMORY" \
    --zip-file "fileb://$DIST_ZIP" >/dev/null
else
  echo "Updating code for $FUNC_NAME ..."
  ${AWSCMD[@]} lambda update-function-code \
    --function-name "$FUNC_NAME" \
    --zip-file "fileb://$DIST_ZIP" >/dev/null

  echo "Updating configuration for $FUNC_NAME ..."
  ${AWSCMD[@]} lambda update-function-configuration \
    --function-name "$FUNC_NAME" \
    --timeout "$TIMEOUT" \
    --memory-size "$MEMORY" \
    --environment "$ENV_JSON" >/dev/null
fi

echo "Deployment complete: $FUNC_NAME"
