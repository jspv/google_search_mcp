#!/usr/bin/env bash

# Example: Test your AgentCore Gateway MCP endpoint
# Replace these values with your actual configuration:

GATEWAY_URL="https://your-gateway-id.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp"
CLIENT_ID="your-client-id-here"
CLIENT_SECRET="your-client-secret-here"
TOKEN_URL="https://your-domain.auth.us-east-1.amazoncognito.com/oauth2/token"

echo "Testing AgentCore Gateway with your credentials..."
echo "Gateway: $GATEWAY_URL"

echo ""
python3 deploy_aws_agentcore_auth0/test_gateway_auth0.py "$GATEWAY_URL" "$CLIENT_ID" "$CLIENT_SECRET" "$TOKEN_URL"

# Alternative env var usage:
# export GATEWAY_URL="$GATEWAY_URL"
# export COGNITO_CLIENT_ID="$CLIENT_ID"
# export COGNITO_CLIENT_SECRET="$CLIENT_SECRET"
# export COGNITO_TOKEN_URL="$TOKEN_URL"
# python3 deploy_aws_agentcore_auth0/test_gateway_auth0.py
