#!/usr/bin/env bash
set -euo pipefail

# Build a Lambda deployment ZIP with deps + source
# Uses an available Python interpreter and installs into a staging folder
# via pip --target to avoid touching system site-packages.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
WORK_DIR="$ROOT_DIR/.build_lambda"
STAGE="$WORK_DIR/stage"

rm -rf "$WORK_DIR" "$DIST_DIR"
mkdir -p "$WORK_DIR" "$DIST_DIR" "$STAGE"

cleanup() {
  # Remove the temporary staging after packaging
  rm -rf "$WORK_DIR" || true
}
trap cleanup EXIT

# Determine build strategy: use Docker on non-Linux hosts (or if FORCE_DOCKER=1)
UNAME_S="$(uname -s || echo unknown)"
USE_DOCKER="${FORCE_DOCKER:-}"
# Build architecture (affects Docker platform only). Valid: x86_64, arm64
ARCH="${ARCH:-x86_64}"
if [[ "$ARCH" == "x86_64" ]]; then
  DOCKER_PLATFORM="linux/amd64"
elif [[ "$ARCH" == "arm64" ]]; then
  DOCKER_PLATFORM="linux/arm64"
else
  echo "Invalid ARCH='$ARCH'. Use 'x86_64' or 'arm64'." >&2
  exit 2
fi
if [[ -z "$USE_DOCKER" ]]; then
  if [[ "$UNAME_S" != "Linux" ]]; then
    USE_DOCKER=1
  else
    USE_DOCKER=0
  fi
fi

if [[ "$USE_DOCKER" == "1" ]]; then
  echo "Using Docker to build Linux $ARCH-compatible wheels for Lambda..."

  # Pick a container CLI
  DOCKER_CLI_BIN="${DOCKER_CLI:-}"
  if [[ -z "$DOCKER_CLI_BIN" ]]; then
    if command -v docker >/dev/null 2>&1; then
      DOCKER_CLI_BIN="docker"
    elif command -v podman >/dev/null 2>&1; then
      DOCKER_CLI_BIN="podman"
    elif [[ -x "/opt/homebrew/bin/docker" ]]; then
      DOCKER_CLI_BIN="/opt/homebrew/bin/docker"
    elif [[ -x "/usr/local/bin/docker" ]]; then
      DOCKER_CLI_BIN="/usr/local/bin/docker"
    fi
  fi
  if [[ -z "$DOCKER_CLI_BIN" ]]; then
    echo "Container CLI not found. Install Docker Desktop or Podman, or set DOCKER_CLI to the binary path." >&2
    echo "Example: DOCKER_CLI=/opt/homebrew/bin/docker ./deploy/build_zip.sh" >&2
    exit 2
  fi

  # Verify the daemon is reachable
  if ! "$DOCKER_CLI_BIN" info >/dev/null 2>&1; then
    echo "'$DOCKER_CLI_BIN' is installed but the daemon isn't reachable. Start Docker Desktop / Podman and try again." >&2
    exit 2
  fi

  echo "Using container CLI: $DOCKER_CLI_BIN"
  # Use Lambda Python 3.12 base with x86_64 platform to match the CFN template
  DOCKER_IMAGE="public.ecr.aws/lambda/python:3.12"
  "$DOCKER_CLI_BIN" run --rm \
    --platform="$DOCKER_PLATFORM" \
    --entrypoint /bin/bash \
    -v "$ROOT_DIR":/workspace \
    -w /workspace \
    "$DOCKER_IMAGE" \
    -lc "python -m pip install --upgrade pip && \
      python -m pip install run-mcp-servers-with-aws-lambda mcp 'httpx[http2]' dynaconf rpds-py -t .build_lambda/stage"
  # Verify native modules present
  echo "Verifying native modules in $STAGE ..."
  if ! ls "$STAGE"/rpds/rpds*.so >/dev/null 2>&1; then
    echo "ERROR: rpds native module not found in ZIP staging. Install likely failed." >&2
    find "$STAGE/rpds" -maxdepth 2 -type f 2>/dev/null || true
    exit 2
  fi

  # Import smoke test inside the same container platform
  echo "Running import smoke test inside container..."
  "$DOCKER_CLI_BIN" run --rm \
    --platform="$DOCKER_PLATFORM" \
    --entrypoint python \
    -v "$ROOT_DIR":/workspace \
    -w /workspace \
    "$DOCKER_IMAGE" \
    -c "import sys; sys.path.insert(0, '/workspace/.build_lambda/stage'); import rpds, pydantic_core, mcp, jsonschema, referencing; print('Imports OK')"
  if ! ls "$STAGE"/pydantic_core/*.so >/dev/null 2>&1; then
    echo "ERROR: pydantic_core native module not found in ZIP staging. Install likely failed." >&2
    find "$STAGE/pydantic_core" -maxdepth 1 -type f 2>/dev/null || true
    exit 2
  fi
else
  echo "Building on Linux host without Docker..."
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

  # Core deps installed into target directory (STAGE)
  "$VENV_PY" -m pip install \
    run-mcp-servers-with-aws-lambda \
    mcp \
    "httpx[http2]" \
    dynaconf \
    rpds-py \
    -t "$STAGE"
  # Verify native modules present
  echo "Verifying native modules in $STAGE ..."
  if ! ls "$STAGE"/rpds/rpds*.so >/dev/null 2>&1; then
    echo "ERROR: rpds native module not found in ZIP staging. Install likely failed." >&2
    find "$STAGE/rpds" -maxdepth 2 -type f 2>/dev/null || true
    exit 2
  fi
  if ! ls "$STAGE"/pydantic_core/*.so >/dev/null 2>&1; then
    echo "ERROR: pydantic_core native module not found in ZIP staging. Install likely failed." >&2
    find "$STAGE/pydantic_core" -maxdepth 1 -type f 2>/dev/null || true
    exit 2
  fi
fi

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
