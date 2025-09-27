"""
Tests that logging works when configuration is supplied via a .env file.

We create a temporary .env that includes the Google API key, CX, and logging
flags (including a LOG_FILE). We then launch a clean Python subprocess that
imports the server, patches out the network call, triggers a search, and
asserts the log file was written.

This proves that: DYNACONF_DOTENV_PATH is honored, and file logging works with
.env-driven configuration at import time.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def test_logging_with_dotenv(tmp_path: Path, monkeypatch):
    # Prepare .env content and log file path
    log_path = tmp_path / "google_search_mcp_dotenv.log"
    dotenv_path = tmp_path / ".env"

    dotenv_path.write_text(
        "\n".join(
            [
                "GOOGLE_API_KEY=dummy-key",
                "GOOGLE_CX=dummy-cx",
                # Enable logging and set file path
                "GOOGLE_LOG_QUERIES=1",
                "GOOGLE_LOG_QUERY_TEXT=1",
                "GOOGLE_LOG_LEVEL=INFO",
                f"GOOGLE_LOG_FILE={log_path}",
            ]
        )
    )

    # Build a clean env for the subprocess: ensure no GOOGLE_* from parent override .env
    env = os.environ.copy()
    for k in list(env.keys()):
        if k.startswith("GOOGLE_"):
            env.pop(k)

    # Ensure the repo root is importable even when cwd is tmp_path
    env["PYTHONPATH"] = f"{Path.cwd()}:{env.get('PYTHONPATH', '')}"

    # Minimal script: import server, patch network, run a search
    code = r"""
import asyncio
import server

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
    await server.search("dotenv logging", num=1)

asyncio.run(main())
"""

    proc = subprocess.run(
        [sys.executable, "-c", code],
        # Change cwd to where the .env lives so Dynaconf finds it automatically
        cwd=str(tmp_path),
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
    )

    assert proc.returncode == 0, (
        "Subprocess failed: rc="
        f"{proc.returncode}\nstdout={proc.stdout}\nstderr={proc.stderr}"
    )

    # Verify the file exists and includes an expected marker
    assert log_path.exists(), "Expected log file to be created via .env"
    contents = log_path.read_text()
    assert "search q_hash=" in contents, (
        "Expected 'search q_hash=' in log file contents"
    )
