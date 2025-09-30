#!/usr/bin/env python3
"""
Test script for AWS AgentCore Gateway with Cognito authentication.

This script tests the complete AgentCore Gateway setup:
1. Authenticates with Cognito using client credentials OAuth flow
2. Lists available tools from the MCP server through the gateway
3. Calls a tool to test end-to-end functionality

Usage:
  python3 test_gateway.py <gateway-url> <client-id> <client-secret> <token-url>

Example:
  python3 test_gateway.py \
    "https://your-gateway.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp" \
    "your-client-id" \
    "your-client-secret" \
    "https://your-domain.auth.us-east-1.amazoncognito.com/oauth2/token"

Or set environment variables:
  export GATEWAY_URL="https://your-gateway.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp"
  export COGNITO_CLIENT_ID="your-client-id"
  export COGNITO_CLIENT_SECRET="your-client-secret"
  export COGNITO_TOKEN_URL="https://your-domain.auth.us-east-1.amazoncognito.com/oauth2/token"
  python3 test_gateway.py

KNOWN ISSUE:
Tool calls may fail with "Missing GOOGLE_API_KEY or GOOGLE_CX" errors due to environment
variable inheritance issues between Lambda main process and MCP server subprocess.
This affects tool execution but not tool listing.
"""

import os
import sys
import json
import requests


def fetch_access_token(client_id, client_secret, token_url):
    """Get OAuth access token from Cognito using client credentials flow."""
    response = requests.post(
        token_url,
        data=f"grant_type=client_credentials&client_id={client_id}&client_secret={client_secret}",
        headers={"Content-Type": "application/x-www-form-urlencoded"}
    )
    
    result = response.json()
    if "access_token" not in result:
        print(f"❌ Failed to get access token. Response: {result}")
        print(f"💡 Make sure you're using the OAuth token endpoint, not JWKS URL")
        print(f"   Correct format: https://your-domain.auth.us-east-1.amazoncognito.com/oauth2/token")
        print(f"   You provided: {token_url}")
        sys.exit(1)
    
    return result["access_token"]


def list_tools(gateway_url, access_token):
    """List available tools using JSON-RPC 2.0 format."""
    response = requests.post(
        gateway_url,
        headers={
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json"
        },
        json={
            "jsonrpc": "2.0",
            "method": "tools/list",
            "id": 1
        }
    )
    
    print(f"🔍 Response status: {response.status_code}")
    result = response.json()
    
    if "error" in result:
        print(f"❌ JSON-RPC Error: {result['error']}")
        return result
    
    return result


def call_tool(gateway_url, access_token, tool_name, arguments):
    """Call a tool using JSON-RPC 2.0 format."""
    response = requests.post(
        gateway_url,
        headers={
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json"
        },
        json={
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": {
                "name": tool_name,
                "arguments": arguments
            },
            "id": 2
        }
    )
    
    print(f"🔍 Tool call status: {response.status_code}")
    result = response.json()
    
    if "error" in result:
        print(f"❌ Tool call error: {result['error']}")
    
    return result


def main():
    """Main function to test the gateway."""
    if len(sys.argv) == 5:
        gateway_url = sys.argv[1]
        client_id = sys.argv[2]
        client_secret = sys.argv[3]
        token_url = sys.argv[4]
    else:
        gateway_url = os.getenv("GATEWAY_URL")
        client_id = os.getenv("COGNITO_CLIENT_ID")
        client_secret = os.getenv("COGNITO_CLIENT_SECRET")
        token_url = os.getenv("COGNITO_TOKEN_URL")
    
    if not all([gateway_url, client_id, client_secret, token_url]):
        print("❌ Missing required parameters. Set environment variables or provide as arguments.")
        print("\nUsage:")
        print("  python3 test_gateway.py <gateway-url> <client-id> <client-secret> <token-url>")
        print("\nOr set environment variables:")
        print("  export GATEWAY_URL='https://...gateway.bedrock-agentcore...amazonaws.com/mcp'")
        print("  export COGNITO_CLIENT_ID='your-client-id'")
        print("  export COGNITO_CLIENT_SECRET='your-client-secret'")
        print("  export COGNITO_TOKEN_URL='https://your-domain.auth.us-east-1.amazoncognito.com/oauth2/token'")
        print("  python3 test_gateway.py")
        sys.exit(1)
    
    print(f"Testing gateway: {gateway_url}")
    
    # Get access token
    access_token = fetch_access_token(client_id, client_secret, token_url)
    print("✅ Got access token")
    
    # List available tools
    tools_response = list_tools(gateway_url, access_token)
    print(f"✅ Tools response: {json.dumps(tools_response, indent=2)}")
    
    # Test a tool call if tools are available
    if "result" in tools_response and "tools" in tools_response["result"]:
        tools = tools_response["result"]["tools"]
        if len(tools) > 0:
            tool_name = tools[0]["name"]
            print(f"\n🔧 Testing tool: {tool_name}")
            
            # Call the search tool
            result = call_tool(gateway_url, access_token, tool_name, {"q": "test search"})
            print(f"✅ Tool result: {json.dumps(result, indent=2)}")
    
    print("\n🎉 Gateway test completed!")


if __name__ == "__main__":
    main()