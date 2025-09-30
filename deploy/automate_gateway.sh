#!/usr/bin/env bash
set -euo pipefail

# Attempt to automate AgentCore Gateway setup via AWS APIs.
# This script tries to create compute targets and MCP providers programmatically.
#
# Usage:
#   ./deploy/automate_gateway.sh [function-arn]
#
# Prerequisites:
#   - AWS CLI configured with appropriate permissions
#   - Bedrock AgentCore Gateway service available in region

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

echo "=== AgentCore Gateway API Automation ==="

# Step 1: Generate tool schema (prerequisite)
echo "Step 1: Generating tool schema..."
if ! ./deploy/gen_tool_schema.sh; then
  echo "ERROR: Failed to generate tool schema." >&2
  exit 1
fi

# Step 2: Get Lambda function ARN
if [[ -z "$FUNCTION_ARN" ]]; then
  echo "Step 2: Getting Lambda function ARN from CloudFormation..."
  FUNCTION_ARN=$("${AWSCMD[@]}" cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query 'Stacks[0].Outputs[?OutputKey==`FunctionArn`].OutputValue' \
    --output text 2>/dev/null || echo "")
  
  if [[ -z "$FUNCTION_ARN" ]]; then
    echo "ERROR: Could not get function ARN. Provide it manually:" >&2
    echo "  $0 arn:aws:lambda:REGION:ACCOUNT:function:FUNCTION_NAME" >&2
    exit 1
  fi
fi

echo "✓ Lambda function ARN: $FUNCTION_ARN"

# Step 3: Check if AgentCore Control Plane API is available
echo "Step 3: Testing AgentCore Control Plane API availability..."

# Try to list compute targets to see if the API is available
if "${AWSCMD[@]}" bedrock-agentcore-control list-compute-targets >/dev/null 2>&1; then
  echo "✓ AgentCore Control Plane API is available"
  USE_API=true
else
  echo "⚠ AgentCore Control Plane API not available or not accessible."
  echo "   Falling back to console-based setup instructions..."
  USE_API=false
fi

if [[ "$USE_API" == "true" ]]; then
  # Step 4: Create Lambda compute target via API
  echo "Step 4: Creating Lambda compute target..."
  
  COMPUTE_TARGET_ID="google-search-mcp-lambda-$(date +%s)"
  
  # Create compute target JSON
  cat > /tmp/compute-target.json <<EOF
{
  "name": "$COMPUTE_TARGET_ID",
  "type": "LAMBDA",
  "configuration": {
    "lambda": {
      "functionArn": "$FUNCTION_ARN"
    }
  }
}
EOF

  if "${AWSCMD[@]}" bedrock-agentcore-control create-compute-target \
    --cli-input-json file:///tmp/compute-target.json \
    --query 'computeTargetId' --output text > /tmp/compute-target-id.txt; then
    
    COMPUTE_TARGET_ID=$(cat /tmp/compute-target-id.txt)
    echo "✓ Created compute target: $COMPUTE_TARGET_ID"
    
    # Step 5: Create MCP provider via API
    echo "Step 5: Creating MCP provider..."
    
    # Create MCP provider JSON
    cat > /tmp/mcp-provider.json <<EOF
{
  "name": "google-search-mcp",
  "description": "Google Custom Search Engine MCP server",
  "computeTargetId": "$COMPUTE_TARGET_ID",
  "toolsSchema": $(cat tool-schema.json)
}
EOF

    if MCP_PROVIDER_ID=$("${AWSCMD[@]}" bedrock-agentcore-control create-mcp-provider \
      --cli-input-json file:///tmp/mcp-provider.json \
      --query 'mcpProviderId' --output text 2>/dev/null); then
      
      echo "✓ Created MCP provider: $MCP_PROVIDER_ID"
      
      # Get the provider endpoint URL
      if MCP_ENDPOINT=$("${AWSCMD[@]}" bedrock-agentcore-control get-mcp-provider \
        --mcp-provider-id "$MCP_PROVIDER_ID" \
        --query 'endpointUrl' --output text 2>/dev/null); then
        
        echo "✓ MCP provider endpoint: $MCP_ENDPOINT"
        
        # Step 6: Test the endpoint (requires Cognito credentials)
        echo "Step 6: Testing the MCP endpoint..."
        echo "Note: Testing requires Cognito credentials. Set COGNITO_* environment variables or test manually:"
        echo "  python3 deploy/test_gateway.py \"$MCP_ENDPOINT\" <client-id> <client-secret> <token-url>"
        
        if [[ -n "${COGNITO_CLIENT_ID:-}" && -n "${COGNITO_CLIENT_SECRET:-}" && -n "${COGNITO_TOKEN_URL:-}" ]]; then
          if python3 ./deploy/test_gateway.py "$MCP_ENDPOINT"; then
            echo ""
            echo "🎉 SUCCESS! AgentCore Gateway setup complete and tested."
          else
            echo "⚠ Setup completed but testing failed. Verify manually with correct credentials."
          fi
        else
          echo "⚠ Skipping automated test - no Cognito credentials provided."
        fi
        
      else
        echo "⚠ Provider created but couldn't get endpoint URL. Check console."
      fi
      
    else
      echo "✗ Failed to create MCP provider. Check permissions and try console setup."
      USE_API=false
    fi
    
  else
    echo "✗ Failed to create compute target. Check permissions and try console setup."
    USE_API=false
  fi
  
  # Cleanup temp files
  rm -f /tmp/compute-target.json /tmp/mcp-provider.json /tmp/compute-target-id.txt
fi

if [[ "$USE_API" == "false" ]]; then
  # Fallback to console instructions
  echo ""
  echo "=== Manual Console Setup Required ==="
  echo ""
  echo "The AgentCore Gateway API is not available or automation failed."
  echo "Please use the console-based setup:"
  echo ""
  echo "  ./deploy/setup_gateway.sh"
  echo ""
  echo "This will provide detailed console instructions."
fi