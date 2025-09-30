#!/usr/bin/env bash
set -euo pipefail

# Package, upload, and deploy the Lambda via CloudFormation.
# Requirements:
# - AWS CLI configured
# - bash, zip
#
# Usage:
#   ./deploy/cfn_deploy.sh <stack-name> <s3-bucket> [s3-prefix] [region]
#
# Config via environment variables (optional, or via .env):
#   FUNCTION_NAME   (default: google-search-mcp)
#   ROLE_ARN        (default: empty; template will create a role when empty)
#   TIMEOUT         (default: 60)
#   MEMORY          (default: 512)
#   LOG_RETENTION   (default: 14)
#   GOOGLE_API_KEY  (required)
#   GOOGLE_CX       (required)
#   GOOGLE_LOG_LEVEL      (default: INFO)
#   GOOGLE_LOG_QUERIES    (default: false)
#   GOOGLE_LOG_QUERY_TEXT (default: false)
#
# Example:
#   FUNCTION_NAME=my-func GOOGLE_API_KEY=xxx GOOGLE_CX=yyy \
#   ./deploy/cfn_deploy.sh google-search-mcp my-bucket some/prefix us-west-2

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <stack-name> <s3-bucket> [s3-prefix] [region]" >&2
  exit 2
fi

STACK_NAME="$1"
S3_BUCKET="$2"
S3_PREFIX="${3:-}"
REGION="${4:-}"

DIST_ZIP="dist/google_search_mcp_lambda.zip"
TEMPLATE_FILE="deploy/cloudformation-lambda.yaml"

# Resolve AWS CLI command
AWSCMD=(aws)
if [[ -n "$REGION" ]]; then
  AWSCMD+=("--region" "$REGION")
fi

# Always disable AWS CLI pager so script exits cleanly
export AWS_PAGER=""

# Load .env if present (from repo root)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$REPO_ROOT/.env" ]]; then
  echo "Loading environment from $REPO_ROOT/.env"
  set -a
  # shellcheck disable=SC1090
  source "$REPO_ROOT/.env"
  set +a
fi

# Build the ZIP if missing
if [[ ! -f "$DIST_ZIP" ]]; then
  echo "Building ZIP..."
  ./deploy/build_zip.sh
fi

# Compute versioned S3 key (prevents CFN no-op due to same key)
TS="$(date +%Y%m%d-%H%M%S)"
BASE_KEY="google_search_mcp_lambda-${TS}.zip"
if [[ -n "$S3_PREFIX" ]]; then
  S3_KEY="$S3_PREFIX/$BASE_KEY"
else
  S3_KEY="$BASE_KEY"
fi
echo "Using S3 key: $S3_KEY"

# Upload the ZIP
echo "Uploading $DIST_ZIP to s3://$S3_BUCKET/$S3_KEY ..."
"${AWSCMD[@]}" s3 cp "$DIST_ZIP" "s3://$S3_BUCKET/$S3_KEY"

# Check required secrets (from env or .env)
: "${GOOGLE_API_KEY:?GOOGLE_API_KEY env var is required}"
: "${GOOGLE_CX:?GOOGLE_CX env var is required}"

# Defaults
FUNCTION_NAME="${FUNCTION_NAME:-google-search-mcp}"
ROLE_ARN="${ROLE_ARN:-}"
TIMEOUT="${TIMEOUT:-60}"
MEMORY="${MEMORY:-512}"
LOG_RETENTION="${LOG_RETENTION:-14}"
GOOGLE_LOG_LEVEL="${GOOGLE_LOG_LEVEL:-INFO}"
GOOGLE_LOG_QUERIES="${GOOGLE_LOG_QUERIES:-false}"
GOOGLE_LOG_QUERY_TEXT="${GOOGLE_LOG_QUERY_TEXT:-false}"

# Compose parameter overrides
PARAMS=(
  "FunctionName=$FUNCTION_NAME"
  "S3Bucket=$S3_BUCKET"
  "S3Key=$S3_KEY"
  "TimeoutSeconds=$TIMEOUT"
  "MemorySizeMB=$MEMORY"
  "LogRetentionDays=$LOG_RETENTION"
  "GoogleApiKey=$GOOGLE_API_KEY"
  "GoogleCx=$GOOGLE_CX"
  "GoogleLogLevel=$GOOGLE_LOG_LEVEL"
  "GoogleLogQueries=$GOOGLE_LOG_QUERIES"
  "GoogleLogQueryText=$GOOGLE_LOG_QUERY_TEXT"
)

# Optional role
if [[ -n "$ROLE_ARN" ]]; then
  PARAMS+=("RoleArn=$ROLE_ARN")
fi

# Deploy the stack
echo "Deploying CloudFormation stack: $STACK_NAME ..."
"${AWSCMD[@]}" cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE_FILE" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides "${PARAMS[@]}"

echo "\nDeployed. Describe stack outputs:"
"${AWSCMD[@]}" cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs' --output table || true

# Inspect current Lambda configuration
CUR_RUNTIME=$("${AWSCMD[@]}" lambda get-function-configuration \
  --function-name "$FUNCTION_NAME" \
  --query 'Runtime' --output text 2>/dev/null || echo "unknown")
CUR_ARCH=$("${AWSCMD[@]}" lambda get-function-configuration \
  --function-name "$FUNCTION_NAME" \
  --query 'Architectures[0]' --output text 2>/dev/null || echo "unknown")

echo "Current Lambda runtime: $CUR_RUNTIME"
echo "Current Lambda architecture: $CUR_ARCH"

# Ensure runtime matches the build target (python3.12)
if [[ "$CUR_RUNTIME" != "python3.12" ]]; then
  echo "Updating Lambda runtime to python3.12 to match packaged wheels..."
  "${AWSCMD[@]}" lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.12 >/dev/null
  # brief wait loop for the update to propagate
  for i in {1..20}; do
    sleep 1
    NEW_RUNTIME=$("${AWSCMD[@]}" lambda get-function-configuration \
      --function-name "$FUNCTION_NAME" \
      --query 'Runtime' --output text 2>/dev/null || echo "unknown")
    if [[ "$NEW_RUNTIME" == "python3.12" ]]; then
      break
    fi
  done
fi

# Warn if architecture is arm64 while we build x86_64 wheels by default
if [[ "$CUR_ARCH" == "arm64" ]]; then
  echo "WARNING: Lambda architecture is arm64 but the build default targets x86_64." >&2
  echo "         Either rebuild with ARCH=arm64 (and set CFN Architectures to arm64) or change the function to x86_64." >&2
fi

# Ensure the latest code is applied even if the CFN template had no changes
echo "\nEnsuring latest code is deployed from s3://$S3_BUCKET/$S3_KEY ..."
"${AWSCMD[@]}" lambda update-function-code \
  --function-name "$FUNCTION_NAME" \
  --s3-bucket "$S3_BUCKET" \
  --s3-key "$S3_KEY" \
  --publish >/dev/null

# --- Smoke test: invoke the Lambda once with a health ping ---
echo "\nSmoke test: invoking Lambda '$FUNCTION_NAME' with health ping..."
OUT_FILE="/tmp/${FUNCTION_NAME}_out.json"

# Invoke with health ping payload
STATUS_CODE=$("${AWSCMD[@]}" lambda invoke \
  --function-name "$FUNCTION_NAME" \
  --payload '{"ping":true}' \
  --cli-binary-format raw-in-base64-out \
  --log-type Tail \
  "$OUT_FILE" \
  --query 'StatusCode' \
  --output text 2>/dev/null || echo "N/A")

echo "Invoke StatusCode: ${STATUS_CODE:-N/A}"
echo "Response payload saved to: $OUT_FILE"

# Basic error heuristics: detect common packaging/import errors
if grep -q "Unable to import module 'lambda_handler'" "$OUT_FILE" 2>/dev/null; then
  echo "ERROR: Lambda could not import lambda_handler (likely wrong platform wheels)." >&2
  exit 1
fi
if grep -qi "No module named 'rpds.rpds'" "$OUT_FILE" 2>/dev/null; then
  echo "ERROR: Missing native module rpds.rpds; rebuild ZIP using Docker path (now enabled by default on macOS)." >&2
  exit 1
fi
if grep -qi "Missing dependency 'run-mcp-servers-with-aws-lambda'" "$OUT_FILE" 2>/dev/null; then
  echo "ERROR: Adapter library not packaged. Re-run build_zip.sh and redeploy." >&2
  exit 1
fi

# Success detection for health ping
if grep -q '"status": "ok"' "$OUT_FILE" 2>/dev/null; then
  echo "Health ping OK."
elif grep -qi "Missing bedrockAgentCoreToolName" "$OUT_FILE" 2>/dev/null; then
  echo "WARNING: Lambda did not recognize the health ping; you may be running old code. Rebuild and redeploy." >&2
else
  echo "WARNING: Unexpected response from Lambda. Check $OUT_FILE for details." >&2
fi

echo "Smoke test completed."
