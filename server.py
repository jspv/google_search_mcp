#!/usr/bin/env python3
"""
MCP server that exposes a Google Programmable Search (CSE) tool.

Key characteristics:
- Uses a single global httpx.AsyncClient with HTTP/2 enabled for performance.
- Wraps Google API errors as RuntimeError with useful, sanitized detail.
- Supports optional domain allowlist filtering via ALLOW_DOMAINS.
- Exposes a single MCP tool: `search`.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import random
import time
from typing import Any

import httpx
from dynaconf import Dynaconf
from mcp.server.fastmcp import FastMCP

_dotenv_hint = os.environ.get("DYNACONF_DOTENV_PATH") or os.environ.get("DOTENV_PATH")

settings = Dynaconf(
    envvar_prefix="GOOGLE",
    load_dotenv=True,
    dotenv_path=_dotenv_hint,
)

GOOGLE_CSE_ENDPOINT = "https://www.googleapis.com/customsearch/v1"
GOOGLE_CSE_SITERESTRICT_ENDPOINT = (
    "https://www.googleapis.com/customsearch/v1/siterestrict"
)

mcp = FastMCP(name="google-search")

# --- Validate config early
GOOGLE_API_KEY = settings.get("API_KEY")
GOOGLE_CX = settings.get("CX")
if not GOOGLE_API_KEY or not GOOGLE_CX:
    raise RuntimeError("Missing GOOGLE_API_KEY or GOOGLE_CX. Provide via env or .env")

# Optional compliance guard: comma-separated list of allowed domains
ALLOW_DOMAINS = {
    d.strip().lower()
    for d in (settings.get("ALLOW_DOMAINS") or "").split(",")
    if d.strip()
}


# --- Logging configuration (opt-in)
def _as_bool(val: Any) -> bool:
    if isinstance(val, bool):
        return val
    if val is None:
        return False
    if isinstance(val, (int, float)):
        return bool(val)
    if isinstance(val, str):
        return val.strip().lower() in {"1", "true", "yes", "on"}
    return False


LOG_QUERIES = _as_bool(settings.get("LOG_QUERIES"))
LOG_QUERY_TEXT = _as_bool(settings.get("LOG_QUERY_TEXT"))
LOG_LEVEL = (settings.get("LOG_LEVEL") or "INFO").upper()
LOG_FILE = settings.get("LOG_FILE")


_logger = logging.getLogger("google_search_mcp")
if not _logger.handlers:
    formatter = logging.Formatter(
        fmt="%(asctime)s %(levelname)s %(name)s: %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
    )
    # Default to stderr, which is safe with MCP stdio
    stderr_handler = logging.StreamHandler()
    stderr_handler.setFormatter(formatter)
    _logger.addHandler(stderr_handler)
    # Optionally also log to a file if configured
    if LOG_FILE:
        file_handler = logging.FileHandler(LOG_FILE)
        file_handler.setFormatter(formatter)
        _logger.addHandler(file_handler)
_logger.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))

# --- Reuse a single Async HTTP client (faster + fewer sockets)
_http = httpx.AsyncClient(
    http2=True,
    timeout=httpx.Timeout(connect=5.0, read=20.0, write=10.0, pool=5.0),
    limits=httpx.Limits(max_keepalive_connections=20, max_connections=100),
    headers={"User-Agent": "mcp-google-search/1.0"},
)


def _normalize(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Transform raw Google CSE `items` into a concise result list.

    Applies optional domain allowlist filtering (ALLOW_DOMAINS) and returns
    dictionaries with shape: {title, url, snippet, rank}.
    """
    results: list[dict[str, Any]] = []
    for i, it in enumerate(items or [], start=1):
        url = it.get("link")
        if ALLOW_DOMAINS:
            # Skip results outside the allowlist
            from urllib.parse import urlparse

            host = (urlparse(url).netloc or "").lower()
            if not any(host.endswith(dom) for dom in ALLOW_DOMAINS):
                continue
        results.append(
            {
                "title": it.get("title"),
                "url": url,
                "snippet": it.get("snippet"),
                "rank": i,
            }
        )
    return results


def _hash_q(q: str) -> str:
    """Stable, short hash for tracing queries in logs/telemetry."""
    return hashlib.sha256(q.encode("utf-8")).hexdigest()[:8]


async def _cse_get(endpoint: str, params: dict[str, Any]) -> dict[str, Any]:
    """Issue a GET to the Google CSE endpoint with small retries.

    Retries up to 3 times on common transient errors (429/5xx), with capped
    exponential backoff and jitter. Raises RuntimeError with status/text for
    non-retryable HTTP errors and wraps httpx exceptions on network errors.
    """
    # Retry small: 3 attempts on 429/5xx with jitter
    for attempt in range(3):
        try:
            r = await _http.get(endpoint, params=params)
            # Log status at DEBUG for observability (avoid logging params with secrets)
            if _logger.isEnabledFor(logging.DEBUG):
                _logger.debug(
                    "cse_get attempt=%d status=%s", attempt + 1, r.status_code
                )
            r.raise_for_status()
            return r.json()
        except httpx.HTTPStatusError as e:
            status = e.response.status_code
            retryable = status in (429, 500, 502, 503, 504) and attempt < 2
            # Respect Retry-After if present, else use capped backoff with jitter
            delay = None
            if retryable:
                ra = e.response.headers.get("Retry-After")
                if ra:
                    try:
                        delay = max(0.0, float(ra))
                    except ValueError:
                        delay = None
                if delay is None:
                    delay = (0.2 + random.random() * 0.4) * (2**attempt)
                if _logger.isEnabledFor(logging.DEBUG):
                    _logger.debug(
                        "cse_get retrying attempt=%d http_status=%s delay=%.2fs",
                        attempt + 1,
                        status,
                        delay,
                    )
                await asyncio.sleep(delay)
                continue
            # Bubble up a clean MCP error string
            detail = e.response.text[:500]
            raise RuntimeError(f"CSE request failed ({status}): {detail}") from e
        except httpx.HTTPError as e:
            if attempt < 2:
                delay = (0.2 + random.random() * 0.4) * (2**attempt)
                if _logger.isEnabledFor(logging.DEBUG):
                    _logger.debug(
                        "cse_get network error attempt=%d delay=%.2fs error=%s",
                        attempt + 1,
                        delay,
                        str(e),
                    )
                await asyncio.sleep(delay)
                continue
            raise RuntimeError(f"Network error contacting CSE: {e!s}") from e


@mcp.tool()
async def search(
    q: str,
    num: int = 5,
    start: int = 1,
    siteSearch: str | None = None,
    siteSearchFilter: str | None = None,  # "i" include | "e" exclude
    safe: str | None = None,  # "off" | "active" (CSE)
    gl: str | None = None,
    hl: str | None = None,
    lr: str | None = None,
    useSiteRestrict: bool = False,
    dateRestrict: str | None = None,  # e.g. "d7", "m3", "y1"
    exactTerms: str | None = None,
    orTerms: str | None = None,
    excludeTerms: str | None = None,
    cxOverride: str | None = None,
    lean_fields: bool = True,  # shrink Google payload
) -> dict[str, Any]:
    """Google Programmable Search (CSE) via MCP.

    Parameters:
        q: Query string. Trimmed; required.
        num: Number of results to return (1..10; clamped).
        start: 1-based index for pagination start (clamped to >=1).
        siteSearch: Limit results to a site (or domain) per CSE rules.
        siteSearchFilter: "i" to include or "e" to exclude `siteSearch`.
        safe: SafeSearch level: "off" or "active".
        gl: Geolocation/country code.
        hl: UI language.
        lr: Language restrict (e.g., "lang_en").
        useSiteRestrict: Use the siterestrict endpoint variant.
        dateRestrict: Time filter (e.g., "d7", "m3", "y1").
        exactTerms, orTerms, excludeTerms: Query modifiers.
        cxOverride: Override the configured CSE ID (avoid echoing to clients).
        lean_fields: If True, request a smaller response via fields projection.

    Returns:
        A dict with keys: provider, query (sanitized), searchInfo, nextPage,
        latency_ms, results (normalized), raw (subset), trace (q hash).

    Raises:
        ValueError: For invalid parameter values (e.g., unsupported safe).
        RuntimeError: For Google API errors or network failures.
    """
    # --- Input hygiene
    q = q.strip()
    num = max(1, min(10, int(num)))
    start = max(1, int(start))
    if safe and safe not in {"off", "active"}:
        raise ValueError('safe must be "off" or "active" for Google CSE')

    # Endpoint selection
    endpoint = (
        GOOGLE_CSE_SITERESTRICT_ENDPOINT if useSiteRestrict else GOOGLE_CSE_ENDPOINT
    )

    # Base params
    params: dict[str, Any] = {
        "key": GOOGLE_API_KEY,
        "cx": cxOverride or GOOGLE_CX,
        "q": q,
        "num": num,
        "start": start,
    }
    # Optional params
    if siteSearch:
        params["siteSearch"] = siteSearch
    if siteSearchFilter:
        params["siteSearchFilter"] = siteSearchFilter  # "i" or "e"
    if safe:
        params["safe"] = safe
    if gl:
        params["gl"] = gl
    if hl:
        params["hl"] = hl
    if lr:
        params["lr"] = lr
    if dateRestrict:
        params["dateRestrict"] = dateRestrict
    if exactTerms:
        params["exactTerms"] = exactTerms
    if orTerms:
        params["orTerms"] = orTerms
    if excludeTerms:
        params["excludeTerms"] = excludeTerms

    # Lean response projection to save bandwidth (smaller payloads)
    if lean_fields:
        params["fields"] = (
            "items(title,link,snippet),"
            "queries(nextPage(startIndex)),"
            "searchInformation(searchTime,totalResults),"
            "kind"
        )

    t0 = time.perf_counter()
    data = await _cse_get(endpoint, params)
    dt = round((time.perf_counter() - t0) * 1000)

    # Optional query/latency logging (no secrets)
    if LOG_QUERIES:
        endpoint_name = (
            "siterestrict" if endpoint == GOOGLE_CSE_SITERESTRICT_ENDPOINT else "cse"
        )
        parts = [
            f"q_hash={_hash_q(q)}",
            f"dt_ms={dt}",
            f"num={num}",
            f"start={start}",
            f"safe={safe or '-'}",
            f"endpoint={endpoint_name}",
        ]
        if LOG_QUERY_TEXT:
            parts.append(f'q="{q}"')
        _logger.info("search %s", " ".join(parts))

    items = data.get("items") or []
    next_page = (data.get("queries", {}).get("nextPage") or [{}])[0].get("startIndex")

    # Avoid leaking secrets (e.g., API key/cx) in the echoed query payload
    echoed_query = {
        "q": q,
        "num": num,
        "start": start,
        "safe": safe,
        "gl": gl,
        "hl": hl,
        "lr": lr,
        "siteSearch": siteSearch,
        "siteSearchFilter": siteSearchFilter,
        "dateRestrict": dateRestrict,
        "exactTerms": exactTerms,
        "orTerms": orTerms,
        "excludeTerms": excludeTerms,
        # "cx": (cxOverride or GOOGLE_CX),  # omit unless you want it visible
    }

    return {
        "provider": "google-cse",
        "query": echoed_query,
        "searchInfo": data.get("searchInformation", {}),
        "nextPage": next_page,
        "latency_ms": dt,
        "results": _normalize(items),
        "raw": {"kind": data.get("kind")},
        "trace": {"q_hash": _hash_q(q)},
    }


if __name__ == "__main__":
    mcp.run()


def main() -> None:
    """Console-script entry point for running the MCP server via uvx or pipx.

    Allows invoking the server as an installed script, e.g.:
    uvx --from /path/to/google_search_mcp google-search-mcp
    """
    mcp.run()
