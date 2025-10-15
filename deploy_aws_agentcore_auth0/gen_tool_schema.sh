#!/usr/bin/env bash
set -euo pipefail

# Generate an MCP tool schema (for AWS AgentCore Gateway) by connecting to a
# stdio MCP server. Configure the server command via env or args.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "Generating tool schema..."

# Choose Python runner for the helper script
if command -v uv >/dev/null 2>&1; then
	PYRUN=(uv run -q python)
else
	PYRUN=(python3)
fi

# Choose default MCP server launch if not provided: run the local server module directly
if [[ -z "${DUMP_MCP_COMMAND:-}" && -z "${DUMP_MCP_ARGS:-}" ]]; then
	CMD="python3"
	ARGS="-c 'import server as m; m.main()'"
else
	# Allow callers to override command/args entirely
	CMD="${DUMP_MCP_COMMAND:-python3}"
	ARGS="${DUMP_MCP_ARGS:--c 'import server as m; m.main()'}"
fi

# Provide placeholder env so the server can import for schema listing
# Provide placeholder env for any required server settings
export GOOGLE_API_KEY="${GOOGLE_API_KEY:-}"
export GOOGLE_CX="${GOOGLE_CX:-}"

# Produce a raw schema payload using the Python helper
RAW_OUT="dist/schema/tool-schema-raw.json"
FINAL_OUT="dist/schema/tool-schema.json"
mkdir -p dist/schema
"${PYRUN[@]}" scripts/dump_tool_schema.py --command "$CMD" --args "$ARGS" --out "$RAW_OUT"

# Convert to AWS AgentCore format (tools array; flatten anyOf)
python3 - <<'PY'
import json, sys
with open('dist/schema/tool-schema-raw.json') as f:
	schema = json.load(f)

def fix_property(prop):
	if isinstance(prop, dict) and 'anyOf' in prop:
		for item in prop['anyOf']:
			if item.get('type') != 'null':
				res = {'type': item.get('type')}
				for k in ('default','title'):
					if k in prop:
						res[k] = prop[k]
				return res
		return {'type':'string','title':prop.get('title',''), 'default':prop.get('default')}
	return prop

tools = schema.get('tools', []) if isinstance(schema, dict) else schema
for tool in tools:
	inp = tool.get('inputSchema', {})
	props = inp.get('properties', {})
	for k in list(props.keys()):
		props[k] = fix_property(props[k])
with open('dist/schema/tool-schema.json','w') as f:
	json.dump(tools, f, indent=2)
print(f'✔ Converted {len(tools)} tools to AWS AgentCore Gateway format')
PY

# Validate JSON
python3 -m json.tool dist/schema/tool-schema.json >/dev/null

# Summary
TOOL_COUNT=$(python3 - <<'PY'
import json
try:
	with open('dist/schema/tool-schema.json') as f:
		data = json.load(f)
	print(len(data) if isinstance(data, list) else len(data.get('tools', [])))
except Exception:
	print('unknown')
PY
)
echo "✔ Schema contains $TOOL_COUNT tools -> $FINAL_OUT"
