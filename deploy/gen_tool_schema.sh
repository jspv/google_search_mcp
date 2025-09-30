#!/usr/bin/env bash
set -euo pipefail

# Generate tool schema for AWS AgentCore Gateway from the local stdio MCP server.
# Uses the MCP Inspector to directly extract tool schemas in the correct format.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v npx >/dev/null 2>&1; then
  echo "npx not found. Install Node.js/npm." >&2
  exit 2
fi

# Allow user to override env; defaults are placeholders
export GOOGLE_API_KEY="${GOOGLE_API_KEY:-placeholder}"
export GOOGLE_CX="${GOOGLE_CX:-placeholder}"

echo "Generating tool schema..."

# Generate tool schema using MCP Inspector, then convert to AWS AgentCore Gateway format
npx @modelcontextprotocol/inspector --cli --method tools/list \
  uvx --from . google-search-mcp > tool-schema-raw.json

# Convert to AWS AgentCore Gateway format
# - Extract tools array from {"tools": [...]} wrapper
# - Flatten anyOf patterns (AWS doesn't support them)
# - Result format matches AWS documentation examples
python3 -c "
import json

with open('tool-schema-raw.json') as f:
    schema = json.load(f)

def fix_property(prop):
    '''Convert anyOf patterns to simple types for AWS compatibility'''
    if 'anyOf' in prop:
        # Find the non-null type
        for item in prop['anyOf']:
            if item.get('type') != 'null':
                # Use the non-null type, preserve other properties
                result = {'type': item['type']}
                for key in ['default', 'title']:
                    if key in prop:
                        result[key] = prop[key]
                return result
        # Fallback to string if only null types found
        return {'type': 'string', 'title': prop.get('title', ''), 'default': prop.get('default')}
    return prop

# Process the tools
tools = schema.get('tools', [])
for tool in tools:
    if 'inputSchema' in tool and 'properties' in tool['inputSchema']:
        properties = tool['inputSchema']['properties']
        for prop_name in properties:
            properties[prop_name] = fix_property(properties[prop_name])

# Save in AWS AgentCore Gateway format (just the tools array)
with open('tool-schema.json', 'w') as f:
    json.dump(tools, f, indent=2)

print(f'✓ Converted {len(tools)} tools to AWS AgentCore Gateway format')
print('✓ Flattened anyOf patterns for AWS compatibility')
"

# Cleanup
rm -f tool-schema-raw.json

echo "✓ Generated tool-schema.json (AWS AgentCore Gateway compatible)"

# Validate the schema is valid JSON
if ! python3 -m json.tool tool-schema.json >/dev/null 2>&1; then
  echo "ERROR: Generated schema is not valid JSON" >&2
  exit 1
fi

# Show summary
TOOL_COUNT=$(python3 -c "import json; schema = json.load(open('tool-schema.json')); print(len(schema.get('tools', [])))" 2>/dev/null || echo "unknown")
echo "✓ Schema contains $TOOL_COUNT tools"
