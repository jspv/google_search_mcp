# OAuth 2.0 Dynamic Client Registration (DCR) for AgentCore Gateway

This Lambda implements RFC 7591-style Dynamic Client Registration backed by
Amazon Cognito User Pools. It is optional and independent from your MCP Lambda.

## What it does

1. Accepts POST /register requests with client metadata (grant_types, scope, etc.)
2. Creates a Cognito App Client matching the request (code/client_credentials)
3. Returns client_id and client_secret (when appropriate)

## Build and Deploy

```bash
# Build zip
./deploy/build_dcr_zip.sh

# Upload to S3
aws s3 cp dist/oauth_dcr_lambda.zip s3://YOUR_BUCKET/path/oauth_dcr_lambda.zip

# Deploy CFN
aws cloudformation deploy \
  --stack-name google-search-mcp-dcr \
  --template-file deploy/cloudformation-dcr.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    FunctionName=google-search-mcp-dcr \
    UserPoolId=us-east-1_XXXXXXXXX \
    InitialAccessToken=YOUR_DCR_SHARED_SECRET \
    RequireInitialAccessToken=true \
    DefaultScopes="openid" \
    AllowAuthCode=false \
    AllowClientCredentials=true \
    CorsAllowOrigin='*' \
    S3Bucket=YOUR_BUCKET \
    S3Key=path/oauth_dcr_lambda.zip
```

Outputs will include `DcrFunctionUrl` which you can use as your /register endpoint.

## Register a Client (client_credentials)

```bash
DCR_URL=$(aws cloudformation describe-stacks \
  --stack-name google-search-mcp-dcr \
  --query 'Stacks[0].Outputs[?OutputKey==`DcrFunctionUrl`].OutputValue' \
  --output text)

curl -sS -X POST "$DCR_URL" \
  -H "Authorization: Bearer YOUR_DCR_SHARED_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "client_name": "mcp-client",
    "grant_types": ["client_credentials"],
    "scope": "openid"
  }'
```

Response example:

```json
{
  "client_id": "abc123",
  "client_secret": "shh-its-a-secret",
  "client_id_issued_at": 1728000000,
  "grant_types": ["client_credentials"],
  "scope": "openid"
}
```

## Get a Token from Cognito

```bash
COGNITO_DOMAIN="your-domain.auth.us-east-1.amazoncognito.com"

curl -sS -X POST "https://$COGNITO_DOMAIN/oauth2/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u CLIENT_ID:CLIENT_SECRET \
  -d "grant_type=client_credentials&scope=openid"
```

## Call AgentCore Gateway MCP Endpoint

Pass the access token in the Authorization header when calling your Gateway MCP
endpoint. Configure AgentCore auth to use your Cognito User Pool issuer and
JWKS; point token URL at your Cognito domain as above.

---

Notes:
- DCR Lambda is optional; you can create app clients via console or IaC instead.
- If you want authorization_code flow for web apps, set AllowAuthCode=true and
  provide redirect_uris in the DCR request.
- The build script vendors boto3 into the ZIP to avoid relying on the runtime-provided
  AWS SDK. This ensures compatibility with the Cognito API calls. The unzipped package
  may exceed the direct upload limit, so this template deploys code from S3.