# Deploy to AWS Lambda using a ZIP package (AgentCore Gateway front)

This packages the stdio MCP server for Lambda using the AWS adapter library
(run-mcp-servers-with-aws-lambda) and exposes it behind Bedrock AgentCore Gateway.

## Prereqs
- AWS CLI configured with permissions to create/update a Lambda function
- Python 3.12 on your build machine
- A Lambda function created with runtime `python3.12` (or create one with the CLI)

## Build the ZIP

Use the helper shell script:

```bash
./deploy/build_zip.sh
```

This creates `dist/google_search_mcp_lambda.zip` containing:
- Third-party deps: run-mcp-servers-with-aws-lambda, mcp, httpx[http2], dynaconf
- Your source: server.py and lambda_handler.py

## Create/Update the Lambda function

Replace placeholders with your values.

```bash
# Create (one-time)
aws lambda create-function \
  --function-name google-search-mcp \
  --runtime python3.12 \
  --role arn:aws:iam::<ACCOUNT_ID>:role/<LambdaExecutionRole> \
  --handler lambda_handler.handler \
  --timeout 60 \
  --memory-size 512 \
  --zip-file fileb://dist/google_search_mcp_lambda.zip

# Update code (subsequent deploys)
aws lambda update-function-code \
  --function-name google-search-mcp \
  --zip-file fileb://dist/google_search_mcp_lambda.zip

# Configure environment
aws lambda update-function-configuration \
  --function-name google-search-mcp \
  --environment "Variables={GOOGLE_API_KEY=xxxxx,GOOGLE_CX=xxxxx,GOOGLE_LOG_LEVEL=INFO,GOOGLE_LOG_QUERIES=true}"
```

Note: Leave the function outside a VPC unless you provide NAT egress; Google CSE requires outbound internet.

## Register in Bedrock AgentCore Gateway

1) Generate your tool schema locally (placeholders are fine):

```bash
# Set placeholders so server starts
export GOOGLE_API_KEY=placeholder
export GOOGLE_CX=placeholder

# Using your module entrypoint
npx @modelcontextprotocol/inspector --cli --method tools/list \
  uvx --from . google-search-mcp > tool-schema.json
```

2) In the Gateway, add a Lambda target:
- Lambda ARN: arn:aws:lambda:<region>:<account>:function:google-search-mcp
- Paste `tool-schema.json` as the tools schema
- Configure OAuth provider for the Gateway per your environment

Clients connect to the Gateway URL; the Gateway invokes your Lambda per request.

## Troubleshooting
- Missing module `mcp_lambda`: ensure the ZIP includes the `run-mcp-servers-with-aws-lambda` package (see build script output).
- Timeouts: bump Lambda timeout to 60s and ensure outbound internet works.
- Google API errors: verify GOOGLE_API_KEY and GOOGLE_CX.
