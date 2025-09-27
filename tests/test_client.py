#!/usr/bin/env python3
"""
Test client for the Google Search MCP server.

Demonstrates MCP client workflow: server startup, protocol handshake,
tool discovery, and result processing.

Usage: python test_client.py
"""

import asyncio
import json
import logging

from mcp import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


async def test_google_search():
    """Test Google Search MCP server via stdio communication."""
    logger.info("Starting MCP server connection test...")

    # Configure MCP server subprocess
    server_params = StdioServerParameters(
        command=".venv/bin/python",
        args=["server.py"],
    )
    logger.info(
        f"Starting server with: {server_params.command} {' '.join(server_params.args)}"
    )

    try:
        # Start MCP server and establish stdio communication
        async with stdio_client(server_params) as (read, write):
            logger.info("Server started, creating MCP session...")

            # Create MCP client session
            async with ClientSession(read, write) as session:
                logger.info("Initializing MCP session...")

                # Initialize protocol handshake
                await session.initialize()
                logger.info("Session initialized successfully!")

                # Discover available tools
                logger.info("Requesting available tools...")
                tools = await session.list_tools()
                tool_names = [tool.name for tool in tools.tools]
                logger.info(f"Available tools: {tool_names}")

                # Test the search tool
                if tools.tools:
                    search_tool = tools.tools[0]
                    logger.info(f"Testing tool: {search_tool.name}")

                    # Call search tool with test query
                    logger.info(
                        "Calling search tool with query 'Python programming'..."
                    )
                    result = await session.call_tool(
                        name=search_tool.name,
                        arguments={"q": "Python programming", "num": 3},
                    )

                    # Process and display results
                    logger.info("Search completed! Results:")

                    for content_item in result.content:
                        if hasattr(content_item, "text"):
                            try:
                                # Parse and pretty-print JSON response
                                search_data = json.loads(content_item.text)
                                logger.info(json.dumps(search_data, indent=2))
                            except json.JSONDecodeError:
                                logger.info(content_item.text)
                        else:
                            # Handle non-text content types
                            logger.info(f"Content type: {type(content_item)}")
                            logger.info(str(content_item))
                else:
                    logger.warning("No tools found!")

    except Exception as e:
        logger.error(f"Error during test: {e}")
        raise


if __name__ == "__main__":
    asyncio.run(test_google_search())
