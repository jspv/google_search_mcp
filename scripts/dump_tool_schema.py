import argparse
import asyncio
import json
import os
import shlex

import anyio
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


def parse_args():
    p = argparse.ArgumentParser(description="Dump MCP tool schema via stdio")
    p.add_argument("--command", default=os.environ.get("DUMP_MCP_COMMAND", "uvx"))
    p.add_argument(
        "--args",
        default=os.environ.get("DUMP_MCP_ARGS", "--from . google-search-mcp"),
        help="Command arguments as a single string",
    )
    p.add_argument("--out", default="dist/schema/tool-schema-raw.json")
    return p.parse_args()


async def main() -> None:
    args = parse_args()
    cmd = args.command
    argv = shlex.split(args.args or "")
    env = os.environ.copy()

    # Ensure output directory exists
    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    server = StdioServerParameters(command=cmd, args=argv, env=env)

    async with stdio_client(server) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools_resp = await session.list_tools()
            try:
                payload = tools_resp.model_dump(by_alias=True)
            except TypeError:
                payload = tools_resp.model_dump()

            data = json.dumps(payload, ensure_ascii=False, indent=2)
            async with await anyio.open_file(args.out, "w", encoding="utf-8") as f:
                await f.write(data)


if __name__ == "__main__":
    asyncio.run(main())
