# Auth0 setup for AWS Bedrock AgentCore Gateway + this MCP server

This guide documents the exact configuration that worked for authenticating to an AWS Bedrock AgentCore Gateway using Auth0 (client credentials) and calling this MCP server over JSON‑RPC.  Auth0 currently supports Dynamic Client Registration which Cognito does not, so it's currently a better fit for adding MCP Connectors to ChatGPT, Claude web client, etc.

## Overview
- Identity Provider: Auth0 (Machine‑to‑Machine using Client Credentials)
- Gateway authorizer: CUSTOM_JWT (Auth0 uses Audience‑based validation)
- Audience to use in Auth0: the gateway’s own resource URL, matching what is advertised at `/.well-known/oauth-protected-resource` at the AgentCore Gatway domain.
- No `allowedClients` required for Auth0 (use audience validation instead)

**Important** - we use the Gateway URL for the audience because in theory when that resource is requested from Auth0, it will match that resource and auto-populate the the audience.  This is described [here](https://github.com/awslabs/amazon-bedrock-agentcore-samples/blob/238d5ffd3ab73190fed69605cc50be14f2f1e27b/02-use-cases/SRE-agent/docs/auth.md).  **In practice with ChatGPT and ClaudeCode** this is *not* happening and the only way I've been able to get it to work is to force the audience to be set in Auth0's tennant-wide settings.  This is less than ideal as you're stuck with only one audience setting for all your MCP servers.  


## Prerequisites
- AWS CLI configured for the account/region hosting the gateway
- An existing AgentCore Gateway setup with:
   - For Inbound Auth:
     -   Use JSON Web Tokens (JWT)
     -   Use Existing Identity Provider configurations
     -   Discovery URL set to `https://<your auth0 domain>/.well_known/openid-configuration`
     -   Allowed Audiences set to the Gateway's own Resource URL (from Gateway Details see #1 below)
     -   Allowed Clients is empty

- Auth0 tenant with admin permissions
- Python for local tests

## 1) Discover your gateway resource URL
The gateway advertises its resource identifier, the Gateway Resource URL -- which we will use as the audience, both in the AWS Console in Gateway Details shoudl be validated in the ./well-known/oauth-protcted-resrouce path here:

```bash
curl https://<gateway-host>/.well-known/oauth-protected-resource | jq .
```

Expected example response:
```json
{
  "authorization_servers": ["https://<your-auth0-domain>"],
  "resource": "https://<gateway-host>/mcp"
}
```

Use the `resource` value exactly as your audience and as the Auth0 API Identifier.

## 2) Auth0 configuration
1. Create an API 
   - Identifier: `https://<gateway-host>/mcp` (the exact `resource` string)
   - Signing Algorithm: RS256
2. Create a Machine‑to‑Machine Application. 
   
   **JSP - not sure #2 is needed if we're hardcoding the audience with tenant wide settings which is the only way I've gotten this to work**
   - In Auth0 Settings->API Authorization Settings->Default Audience
      - set to your Idenfier in #1 `https://<gateway-host>/mcp`
  
   Machine-to-Machine Applicaiton (**JSP - not currently being used**)
   - Choose the API you just created and Authorize it
   - Verify the Client Credentials grant are selected (Application → Settings → Advanced Settings → Grant Types) - this should be the default
3. Collect settings:
   - AUTH0_DOMAIN: `https://<your-tenant>.us.auth0.com`
   - AUTH0_CLIENT_ID: `<your_m2m_client_id>`
   - AUTH0_CLIENT_SECRET: `<your_m2m_client_secret>`
   - AUTH0_AUDIENCE: `https://<gateway-host>/mcp`


## 3) Configure the gateway authorizer if not already done in console, below are AWS CLI steps for those so inclined.
Configure the gateway to validate Auth0 tokens by audience only (no client list needed for Auth0)

Identify your agentcore gateway if you don't already know the ID

```bash
aws bedrock-agentcore-control list-gateways \
  --query 'items[].{Id:gatewayId,Name:name,Status:status}' \
  --output table
```

Identify your gateway and role

```bash
aws bedrock-agentcore-control get-gateway \
  --gateway-identifier <gateway-id>
```

Update authorizer: discoveryUrl + allowedAudience (resource URL)
```bash
aws bedrock-agentcore-control update-gateway \
  --gateway-identifier <gateway-id> \
  --name <gateway-name> \
  --role-arn <role-arn-from-get-gateway> \
  --protocol-type MCP \
  --authorizer-type CUSTOM_JWT \
  --authorizer-configuration '{
    "customJWTAuthorizer": {
      "discoveryUrl": "https://<your-tenant>.us.auth0.com/.well-known/openid-configuration",
      "allowedAudience": [
        "https://<gateway-host>/mcp"
      ]
    }
  }'
```

Tips
- Ensure `allowedAudience` matches your token `aud` exactly (no extra slash differences).
- For Auth0, omit `allowedClients` to avoid unintended AND checks.

## 4) VERIFY - Mint a token (client credentials)
```bash
TOKEN=`curl -s --request POST \
  --url "https://<your-tenant>.us.auth0.com/oauth/token" \
  --header 'content-type: application/json' \
  --data '{
    "client_id": "<AUTH0_CLIENT_ID>",
    "client_secret": "<AUTH0_CLIENT_SECRET>",
    "audience": "https://<gateway-host>/mcp",
    "grant_type": "client_credentials"
  }' | jq -r .access_token`
```

Optional: verify claims: decode the JWT and check `iss`, `aud`, `sub`, `azp`, `exp`, `gty`.
```bash
# Assuming TOKEN contains your access token
TOKEN=$TOKEN python - <<'PY'
import os, json, base64, sys, time
tok = os.environ.get('TOKEN')
if not tok:
    sys.exit('Set TOKEN env var to your JWT first')
h,p,*_ = tok.split('.')
def b64url(s): s += '=' * (-len(s) % 4); return base64.urlsafe_b64decode(s)
hdr = json.loads(b64url(h).decode())
pld = json.loads(b64url(p).decode())
print('Header:', json.dumps(hdr, indent=2, sort_keys=True))
print('Payload:', json.dumps(pld, indent=2, sort_keys=True))
if 'exp' in pld:
    print('exp (UTC):', time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(pld['exp'])))
PY
```

### Call the gateway (JSON‑RPC 2.0)
List tools:
```bash
TOKEN="<access_token>"

curl -sS -X POST \
  https://<gateway-host>/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data-raw '{
    "jsonrpc": "2.0",
    "id": "1",
    "method": "tools/list",
    "params": {}
  }'
```

Call the tool (the example search tool used here)
```bash
curl -sS -X POST \
  https://<gateway-host>/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data-raw '{
    "jsonrpc": "2.0",
    "id": "2",
    "method": "tools/call",
    "params": {
      "name": "search",
      "arguments": { "q": "aws bedrock agentcore mcp" }
    }
  }'
```

## 6) Troubleshooting
Common errors and fixes:

- 401 `Invalid Bearer token` (gateway)
  - Audience mismatch: token `aud` must equal the gateway `allowedAudience` exactly.
  - Discovery URL: ensure it points to your Auth0 OIDC configuration.
  - JWKS/Signature: keep RS256; the token header must have a `kid` present in Auth0 JWKS.
  - Client gating accidentally enabled: remove `allowedClients` for Auth0.

- 401 `access_denied` from Auth0 `/oauth/token`
  - The application is not authorized for the API (audience). Authorize it on the API’s “Machine to Machine Applications” tab.
  - Client Credentials grant not enabled on the application.
  - Audience not registered as an API Identifier in Auth0 (create API first).

- Malformed JSON‑RPC (-32600)
  - The gateway expects a valid JSON‑RPC 2.0 body on POST; include `jsonrpc`, `id`, `method`, and `params`.

Gateway logs (optional, for deep debug):
```bash
LOG_GROUP="/aws/vendedlogs/bedrock-agentcore/gateway/APPLICATION_LOGS/<gateway-id>"
LOG_STREAM=$(aws logs describe-log-streams \
  --log-group-name "$LOG_GROUP" --order-by LastEventTime --descending --max-items 1 \
  --query 'logStreams[0].logStreamName' --output text)

aws logs get-log-events \
  --log-group-name "$LOG_GROUP" \
  --log-stream-name "$LOG_STREAM" \
  --start-time $(( $(date -u +%s) - 600 ))000 \
  --output json | jq -r '.events[] | (.timestamp/1000|todateiso8601) + " " + .message'

Note: On macOS (BSD `date`), the `-u` flag must come before the format string. Using `date +%s -u` yields “illegal time format,” which can result in a negative `--start-time`. The corrected form `date -u +%s` works on both macOS and GNU/Linux.
```

## 7) Environment variables (local testing)
Set these in your shell (do not commit secrets):
```bash
export AUTH0_DOMAIN="https://<your-tenant>.us.auth0.com"
export AUTH0_CLIENT_ID="<client_id>"
export AUTH0_CLIENT_SECRET="<client_secret>"
export AUTH0_AUDIENCE="https://<gateway-host>/mcp"
export GATEWAY_URL="https://<gateway-host>/mcp"
```

Then run the included script:
```bash
uv run python test_gateway_auth0_final.py
```

You should see a 200 response and the `search` tool listed.

## Notes
- Keep secrets out of source control; prefer environment variables or a secrets manager.
- If you must support multiple gateways, set audience per gateway using the corresponding resource URL.
- If migrating from a legacy URN audience, keep both audiences temporarily in `allowedAudience`, then remove the URN once clients are updated.