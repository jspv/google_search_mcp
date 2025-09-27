#!/usr/bin/env python3
"""
Google Search MCP Server

Provides Google Custom Search Engine functionality via Model Context Protocol.
Exposes a 'search' tool that queries Google CSE API and returns normalized results.

Configuration via dynaconf supports both .env files and environment variables,
with environment variables taking precedence.
"""

from typing import Any

import httpx
from dynaconf import Dynaconf
from mcp.server.fastmcp import FastMCP

# Configuration management with dynaconf
# Supports .env files with environment variable override
settings = Dynaconf(
    envvar_prefix="GOOGLE",
    settings_files=[".env"],
    load_dotenv=True,
)

# Google Custom Search API endpoints
GOOGLE_CSE_ENDPOINT = "https://www.googleapis.com/customsearch/v1"
GOOGLE_CSE_SITERESTRICT_ENDPOINT = (
    "https://www.googleapis.com/customsearch/v1/siterestrict"
)

# Initialize FastMCP server
mcp = FastMCP(name="google-search")

# Load API credentials from configuration
GOOGLE_API_KEY = settings.API_KEY
GOOGLE_CX = settings.CX


def _normalize(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Normalize Google CSE results to consistent format with rank numbers."""
    results = []
    for i, it in enumerate(items or [], start=1):
        results.append(
            {
                "title": it.get("title"),
                "url": it.get("link"),
                "snippet": it.get("snippet"),
                "rank": i,
            }
        )
    return results


@mcp.tool()
async def search(
    q: str,
    num: int = 5,
    start: int = 1,
    siteSearch: str | None = None,
    safe: str | None = None,  # "off" | "medium" | "high"
    gl: str | None = None,  # country code, e.g., "us"
    hl: str | None = None,  # UI language, e.g., "en"
    lr: str | None = None,  # language restrict, e.g., "lang_en"
    useSiteRestrict: bool = False,  # use stricter site-only endpoint
) -> dict[str, Any]:
    """
    Search Google Custom Search Engine and return normalized results.

    Args:
        q: Search query string
        num: Number of results to return (1-10)
        start: 1-based starting index for pagination
        siteSearch: Restrict search to specific site
        safe: Safe search level ("off", "medium", "high")
        gl: Country code for geolocation
        hl: Interface language code
        lr: Language restriction
        useSiteRestrict: Use stricter site-only search endpoint

    Returns:
        Normalized search results with metadata
    """
    # Select appropriate endpoint based on site restriction preference
    endpoint = (
        GOOGLE_CSE_SITERESTRICT_ENDPOINT if useSiteRestrict else GOOGLE_CSE_ENDPOINT
    )

    # Build base API parameters
    params = {
        "key": GOOGLE_API_KEY,
        "cx": GOOGLE_CX,
        "q": q,
        "num": num,
        "start": start,
    }

    # Add optional parameters if provided
    if siteSearch:
        params["siteSearch"] = siteSearch
    if safe:
        params["safe"] = safe
    if gl:
        params["gl"] = gl
    if hl:
        params["hl"] = hl
    if lr:
        params["lr"] = lr

    # Execute Google CSE API request
    async with httpx.AsyncClient(timeout=20) as client:
        r = await client.get(endpoint, params=params)
        r.raise_for_status()
        data = r.json()

    # Process and normalize search results
    items = data.get("items", [])
    return {
        "provider": "google-cse",
        "query": {"q": q, **{k: v for k, v in params.items() if k not in ("key",)}},
        "searchInfo": data.get("searchInformation", {}),
        "nextPage": (data.get("queries", {}).get("nextPage") or [{}])[0].get(
            "startIndex"
        ),
        "results": _normalize(items),
        "raw": {"kind": data.get("kind")},
    }


if __name__ == "__main__":
    # Run MCP server over stdio (default transport)
    mcp.run()
