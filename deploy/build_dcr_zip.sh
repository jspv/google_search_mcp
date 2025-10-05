#!/usr/bin/env bash
set -euo pipefail

# Build a ZIP for the OAuth 2.0 DCR Lambda containing only the handler.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$REPO_ROOT/.build_dcr"
STAGE="$WORK_DIR/stage"
DIST_DIR="$REPO_ROOT/dist"

rm -rf "$WORK_DIR" "$DIST_DIR/oauth_dcr_lambda.zip" || true
mkdir -p "$STAGE" "$DIST_DIR"

# Place handler at the root of the zip (Lambda requirement for module import path)
cp "$SCRIPT_DIR/oauth_dcr_handler.py" "$STAGE/"

# Vendor boto3 so the function doesn't rely on runtime-provided SDK versions
if command -v python3 >/dev/null 2>&1; then
	python3 -m pip --version >/dev/null 2>&1 || python3 -m ensurepip --upgrade || true
	python3 -m pip install --upgrade pip >/dev/null
	python3 -m pip install boto3 -t "$STAGE" >/dev/null
else
	echo "WARNING: python3 not found; boto3 will not be vendored. Ensure runtime has boto3." >&2
fi

pushd "$STAGE" >/dev/null
zip -q -r "$DIST_DIR/oauth_dcr_lambda.zip" .
popd >/dev/null

echo "Built $DIST_DIR/oauth_dcr_lambda.zip"