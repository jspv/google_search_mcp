"""
Tests for logging behavior: prove that setting env vars results in a log file
being written when a search runs. This uses a subprocess to ensure a clean
module import so logging configuration (handlers) is applied at import time.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def test_logging_writes_file(tmp_path: Path, monkeypatch):
    # Prepare a dedicated log file path and required Google env vars
    log_path = tmp_path / "google_search_mcp_test.log"

    env = os.environ.copy()
    env.update(
        {
            # Dynaconf config
            "GOOGLE_API_KEY": "dummy-key",
            "GOOGLE_CX": "dummy-cx",
            # Logging flags
            "GOOGLE_LOG_QUERIES": "1",
            "GOOGLE_LOG_QUERY_TEXT": "1",
            "GOOGLE_LOG_LEVEL": "INFO",
            "GOOGLE_LOG_FILE": str(log_path),
        }
    )

    # Run a small one-off Python program that patches out network and invokes search
    code = r"""
import asyncio
import server

# Patch network layer to avoid external calls
async def fake_cse_get(endpoint, params):
    return {
        "items": [
            {"title": "Example", "link": "https://example.com", "snippet": "Snippet"}
        ],
        "queries": {"nextPage": [{"startIndex": 2}]},
        "searchInformation": {"searchTime": 0.01, "totalResults": "1"},
        "kind": "customsearch#search",
    }

server._cse_get = fake_cse_get

async def main():
    # Trigger a single search which should emit a log line
    await server.search("hello world", num=1)

asyncio.run(main())
"""

    # Execute the snippet in a clean interpreter with our env
    result = subprocess.run(
        [sys.executable, "-c", code],
        cwd=str(Path.cwd()),
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
    )

    assert result.returncode == 0, (
        "Subprocess failed: rc="
        f"{result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
    )

    # Verify the log file exists and contains an expected marker
    assert log_path.exists(), "Expected log file to be created"
    contents = log_path.read_text()
    assert "search q_hash=" in contents, f"Expected log line in file, got: {contents!r}"
