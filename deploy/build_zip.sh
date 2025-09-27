#!/usr/bin/env bash
set -euo pipefail

# Build a Lambda deployment ZIP with deps + source
# Uses an available Python interpreter and installs into a staging folder
# via pip --target to avoid touching system site-packages.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
WORK_DIR="$ROOT_DIR/.build_lambda"

rm -rf "$WORK_DIR" "$DIST_DIR"
mkdir -p "$WORK_DIR" "$DIST_DIR"

cleanup() {
  # Remove the temporary staging after packaging
  rm -rf "$WORK_DIR" || true
}
trap cleanup EXIT

# Choose a Python interpreter (prefer uv's 3.12 if available)
PY_BIN="${PYTHON:-}"
if [[ -z "$PY_BIN" ]] && command -v uv >/dev/null 2>&1; then
  PY_BIN="$(uv python find 3.12 2>/dev/null || true)"
fi
if [[ -z "$PY_BIN" ]]; then
  if command -v python3.12 >/dev/null 2>&1; then
    PY_BIN="python3.12"
  elif command -v python3 >/dev/null 2>&1; then
    PY_BIN="python3"
  elif command -v python >/dev/null 2>&1; then
    PY_BIN="python"
  else
    echo "No Python interpreter found (tried uv, python3.12, python3, python)." >&2
    exit 2
  fi
fi

# Create a transient venv to ensure a working pip, but still install to STAGE
"$PY_BIN" -m venv "$WORK_DIR/venv" || { echo "Failed to create venv with $PY_BIN" >&2; exit 2; }
VENV_PY="$WORK_DIR/venv/bin/python"

# Bootstrap/upgrade pip inside the venv (handle cases where pip isn't present)
"$VENV_PY" -m pip --version >/dev/null 2>&1 || "$VENV_PY" -m ensurepip --upgrade || true
"$VENV_PY" -m pip install --upgrade pip

# Install runtime dependencies into a staging dir (no site-packages pollution)
STAGE="$WORK_DIR/stage"
mkdir -p "$STAGE"

# Core deps installed into target directory (STAGE)
"$VENV_PY" -m pip install \
  run-mcp-servers-with-aws-lambda \
  mcp \
  "httpx[http2]" \
  dynaconf \
  -t "$STAGE"

# Strip tests/metadata to shrink package (best-effort)
find "$STAGE" -type d -name tests -prune -exec rm -rf {} + || true
find "$STAGE" -type d -name "__pycache__" -prune -exec rm -rf {} + || true

# Copy our source files
cp "$ROOT_DIR/server.py" "$STAGE/"
cp "$ROOT_DIR/lambda_handler.py" "$STAGE/"

# Create ZIP
( cd "$STAGE" && zip -r9 "$DIST_DIR/google_search_mcp_lambda.zip" . >/dev/null )

# Show result
ls -lh "$DIST_DIR/google_search_mcp_lambda.zip"

echo "\nZIP ready: $DIST_DIR/google_search_mcp_lambda.zip"
