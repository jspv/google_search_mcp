#!/usr/bin/env python3
"""
AWS Lambda handler to run the stdio-based MCP server and expose it behind
Bedrock AgentCore Gateway using the AWS "run-mcp-servers-with-aws-lambda"
adapter.

This spins up the stdio MCP server defined in `server.py` as a child process
per invocation and bridges the Gateway's request to the server.

Environment:
- Provide GOOGLE_API_KEY and GOOGLE_CX as Lambda environment variables.
- Optionally DYNACONF_DOTENV_PATH if you want to load a .env in development.
"""

from __future__ import annotations

import sys

from mcp.client.stdio import StdioServerParameters


def handler(event, context):
    """AWS Lambda entrypoint for Bedrock AgentCore Gateway target.

    Imports the AWS adapter lazily so local dev/tests don't require the
    package. Configure Lambda with `run-mcp-servers-with-aws-lambda` installed.
    """
    try:
        from mcp_lambda import (
            BedrockAgentCoreGatewayTargetHandler,
            StdioServerAdapterRequestHandler,
        )
    except Exception as e:  # pragma: no cover - only hit if deps missing
        # Provide a helpful error in CloudWatch if the layer/deps are missing
        raise RuntimeError(
            "Missing dependency 'run-mcp-servers-with-aws-lambda' "
            "(module 'mcp_lambda'). Add it to your Lambda image/layer or "
            "include it in the deployment package."
        ) from e

    # Launch our stdio MCP server via `python -m server`
    server_params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "server"],
    )

    request_handler = StdioServerAdapterRequestHandler(server_params)
    event_handler = BedrockAgentCoreGatewayTargetHandler(request_handler)
    return event_handler.handle(event, context)
