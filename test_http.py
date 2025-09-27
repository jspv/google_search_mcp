#!/usr/bin/env python3
"""
Test client for the Google Search MCP server over HTTP/SSE.

Usage:
  1) In one terminal, start the web-based MCP server:
       uv run google-search-mcp-http
  2) In another terminal, run this client:
       uv run python test_http.py

You can override the SSE URL with MCP_HTTP_SSE_URL env var (default http://127.0.0.1:8000/sse).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os

from mcp import ClientSession
from mcp.client.sse import sse_client

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


async def test_google_search_sse():
    url = os.environ.get("MCP_HTTP_SSE_URL", "http://127.0.0.1:8000/sse")
    logger.info("Connecting to MCP SSE at %s", url)

    # Establish SSE transport and create MCP session
    async with sse_client(url) as (read, write):
        async with ClientSession(read, write) as session:
            logger.info("Initializing MCP session...")
            await session.initialize()
            logger.info("Session initialized.")

            # Discover available tools
            tools = await session.list_tools()
            tool_names = [tool.name for tool in tools.tools]
            logger.info("Available tools: %s", tool_names)

            if not tools.tools:
                logger.warning("No tools found!")
                return

            # Use the `search` tool if present (fallback to first tool)
            chosen = next(
                (t for t in tools.tools if t.name == "search"), tools.tools[0]
            )
            logger.info("Testing tool: %s", chosen.name)

            result = await session.call_tool(
                name=chosen.name,
                arguments={"q": "Python programming", "num": 3},
            )

            # Print out the content items
            for content_item in result.content:
                if hasattr(content_item, "text"):
                    try:
                        data = json.loads(content_item.text)
                        logger.info(json.dumps(data, indent=2))
                    except json.JSONDecodeError:
                        logger.info(content_item.text)
                else:
                    logger.info("Content type: %s", type(content_item))
                    logger.info(str(content_item))


if __name__ == "__main__":
    asyncio.run(test_google_search_sse())
