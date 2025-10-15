#!/usr/bin/env python3
"""
AWS Lambda handler to run the stdio-based MCP server and expose it behind
Bedrock AgentCore Gateway using the AWS "run-mcp-servers-with-aws-lambda"
adapter.

This spins up the stdio MCP server defined in `server.py` as a child process
per invocation and bridges the Gateway's request to the server. Environment
variables are explicitly passed to the subprocess to ensure proper configuration.

Environment:
- Provide GOOGLE_API_KEY and GOOGLE_CX as Lambda environment variables.
- Optionally GOOGLE_LOG_LEVEL and GOOGLE_LOG_QUERIES for logging configuration.
- Optionally DYNACONF_DOTENV_PATH if you want to load a .env in development.
"""

from __future__ import annotations

import os
import sys

from mcp.client.stdio import StdioServerParameters


def handler(event, context):
    """AWS Lambda entrypoint for Bedrock AgentCore Gateway target.

    Imports the AWS adapter lazily so local dev/tests don't require the
    package. Configure Lambda with `run-mcp-servers-with-aws-lambda` installed.
    """
    # Simple health check for CLI smoke tests
    try:
        if isinstance(event, dict) and (event.get("ping") or event.get("health")):
            return {
                "status": "ok",
                "handler": "lambda",
                "python": sys.version.split()[0],
            }
    except Exception:
        # If event is not a dict, ignore and continue
        pass
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
    # Explicitly pass environment variables to ensure subprocess inherits them
    env_vars = {
        # Google API credentials (required)
        "GOOGLE_API_KEY": os.environ.get("GOOGLE_API_KEY"),
        "GOOGLE_CX": os.environ.get("GOOGLE_CX"),
        # Optional logging configuration
        "GOOGLE_LOG_LEVEL": os.environ.get("GOOGLE_LOG_LEVEL"),
        "GOOGLE_LOG_QUERIES": os.environ.get("GOOGLE_LOG_QUERIES"),
        "GOOGLE_LOG_QUERY_TEXT": os.environ.get("GOOGLE_LOG_QUERY_TEXT"),
        "GOOGLE_LOG_FILE": os.environ.get("GOOGLE_LOG_FILE"),
        # Optional domain allowlist and dotenv path
        "GOOGLE_ALLOW_DOMAINS": os.environ.get("GOOGLE_ALLOW_DOMAINS"),
        "DYNACONF_DOTENV_PATH": os.environ.get("DYNACONF_DOTENV_PATH"),
        # Essential system environment variables
        "PATH": os.environ.get("PATH", ""),
        "PYTHONPATH": os.environ.get("PYTHONPATH", ""),
    }
    # Filter out None values to avoid passing empty environment variables
    env_vars = {k: v for k, v in env_vars.items() if v is not None}

    server_params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "server"],
        env=env_vars,
    )

    request_handler = StdioServerAdapterRequestHandler(server_params)
    event_handler = BedrockAgentCoreGatewayTargetHandler(request_handler)
    return event_handler.handle(event, context)
