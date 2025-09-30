#!/usr/bin/env bash
set -euo pipefail

# Automate AgentCore Gateway setup for the MCP Lambda function.
# This script generates the tool schema and provides guidance for Gateway configuration.
#
# Usage:
#   ./deploy/setup_gateway.sh [function-arn]
#
# If function-arn is not provided, it will try to get it from the CloudFormation stack.

FUNCTION_ARN="${1:-}"
STACK_NAME="${STACK_NAME:-google-mcp}"
REGION="${REGION:-us-east-1}"

# Load .env if present
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$REPO_ROOT/.env" ]]; then
  echo "Loading environment from $REPO_ROOT/.env"
  set -a
  # shellcheck disable=SC1090
  source "$REPO_ROOT/.env"
  set +a
fi

# AWS CLI command with region
AWSCMD=(aws)
if [[ -n "$REGION" ]]; then
  AWSCMD+=("--region" "$REGION")
fi
export AWS_PAGER=""

echo "=== AgentCore Gateway Setup ==="

# Step 1: Generate tool schema
echo "Step 1: Generating tool schema..."
if ! ./deploy/gen_tool_schema.sh; then
  echo "ERROR: Failed to generate tool schema. Ensure Node.js/npm is installed." >&2
  exit 1
fi

if [[ ! -f "tool-schema.json" ]]; then
  echo "ERROR: tool-schema.json not found after generation." >&2
  exit 1
fi

echo "✓ Tool schema generated: tool-schema.json"

# Step 2: Get Lambda function ARN if not provided
if [[ -z "$FUNCTION_ARN" ]]; then
  echo "Step 2: Getting Lambda function ARN from CloudFormation..."
  FUNCTION_ARN=$("${AWSCMD[@]}" cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query 'Stacks[0].Outputs[?OutputKey==`FunctionArn`].OutputValue' \
    --output text 2>/dev/null || echo "")
  
  if [[ -z "$FUNCTION_ARN" ]]; then
    echo "ERROR: Could not get function ARN from stack '$STACK_NAME'. Provide it manually:" >&2
    echo "  $0 arn:aws:lambda:REGION:ACCOUNT:function:FUNCTION_NAME" >&2
    exit 1
  fi
fi

echo "✓ Lambda function ARN: $FUNCTION_ARN"

# Step 3: Create Gateway configuration JSON
echo "Step 3: Creating Gateway configuration template..."

cat > gateway-config.json <<EOF
{
  "lambdaTarget": {
    "functionArn": "$FUNCTION_ARN",
    "region": "$REGION"
  },
  "mcpProvider": {
    "name": "google-search-mcp",
    "description": "Google Custom Search Engine MCP server",
    "toolSchema": $(cat tool-schema.json)
  }
}
EOF

echo "✓ Gateway configuration saved: gateway-config.json"

# Step 4: Provide setup instructions
echo ""
echo "=== Manual Setup Required in AWS Console ==="
echo ""
echo "1. Open AWS Bedrock > AgentCore Gateway in region: $REGION"
echo ""
echo "2. Create a Lambda Compute Target:"
echo "   - Target Type: AWS Lambda"
echo "   - Function ARN: $FUNCTION_ARN"
echo "   - Region: $REGION"
echo "   - Save the target (note the target ID)"
echo ""
echo "3. Create an MCP Provider:"
echo "   - Provider Name: google-search-mcp"
echo "   - Description: Google Custom Search Engine MCP server"
echo "   - Compute Target: Select the Lambda target created above"
echo "   - Tools Schema: Copy and paste the contents of tool-schema.json"
echo "   - Save the provider (note the provider endpoint URL)"
echo ""
echo "4. Configure Authentication (if required):"
echo "   - Set up Cognito/Okta/Auth0 integration as needed"
echo "   - Configure OAuth scopes and permissions"
echo ""
echo "=== Testing ==="
echo ""
echo "Once configured, test the MCP provider endpoint:"
echo ""
echo "# Test tools list (replace YOUR_GATEWAY_URL with actual endpoint)"
echo "npx @modelcontextprotocol/inspector --cli \\"
echo "  --url 'https://YOUR_GATEWAY_URL/mcp/google-search-mcp' \\"
echo "  --method tools/list"
echo ""
echo "# Test a search (replace YOUR_GATEWAY_URL with actual endpoint)"
echo "npx @modelcontextprotocol/inspector --cli \\"
echo "  --url 'https://YOUR_GATEWAY_URL/mcp/google-search-mcp' \\"
echo "  --method tools/call \\"
echo "  --params '{\"name\":\"google.search\",\"arguments\":{\"query\":\"AWS Lambda pricing\"}}'"
echo ""
echo "=== Files Created ==="
echo "- tool-schema.json: MCP tools schema for Gateway"
echo "- gateway-config.json: Configuration template (for reference)"
echo ""
echo "Setup guidance complete!"