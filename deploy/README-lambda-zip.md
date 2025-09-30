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

After deploying the Lambda, use the automation script to attempt full automation or get console instructions:

### Option 1: Attempt Full Automation (Recommended First Try)

```bash
# Try full API-based automation
./deploy/automate_gateway.sh

# This script will:
# 1. Generate tool schema automatically
# 2. Test if AgentCore APIs are available  
# 3. Create compute target and MCP provider if APIs work
# 4. Fall back to console instructions if APIs unavailable
```

### Option 2: Console-Based Setup

If the automation script reports that APIs are not available, use the setup guidance:

```bash
# Generate schema and setup guidance
./deploy/setup_gateway.sh

# Or with explicit function ARN
./deploy/setup_gateway.sh arn:aws:lambda:us-east-1:123456789:function:google-search-mcp
```

This will:
1. Generate `tool-schema.json` with placeholder credentials
2. Extract your Lambda ARN from CloudFormation 
3. Create `gateway-config.json` template
4. Provide step-by-step console instructions

### Manual Gateway Configuration

Follow the printed instructions to:
1. Create a Lambda compute target in AgentCore Gateway
2. Create an MCP provider with the generated tool schema
3. Configure OAuth/authentication as needed

**Note**: As of current AWS service availability, AgentCore Gateway compute targets and MCP providers require manual console configuration. The automation scripts provide maximum automation where APIs permit.

### Test the Gateway

Once configured, test the endpoint:

```bash
python3 deploy/test_gateway.py https://YOUR_GATEWAY_URL/mcp/google-search-mcp client-id client-secret token-url
```

This validates both the tools/list and a sample search query.

## Troubleshooting

### Common Issues
- Missing module `mcp_lambda`: ensure the ZIP includes the `run-mcp-servers-with-aws-lambda` package (see build script output).
- Timeouts: bump Lambda timeout to 60s and ensure outbound internet works.
- Google API errors: verify GOOGLE_API_KEY and GOOGLE_CX.
- Smoke-test ping: you can call the Lambda directly with `{ "ping": true }` to get `{ "status": "ok" }` without a full Gateway event shape.

### Known Issue: Environment Variable Inheritance

**Problem**: Tool calls fail with "Missing GOOGLE_API_KEY or GOOGLE_CX" errors even when environment variables are correctly set in Lambda.

**Root Cause**: The MCP Lambda adapter (`run-mcp-servers-with-aws-lambda`) starts the MCP server as a subprocess that doesn't inherit the Lambda process environment variables.

**Symptoms**:
- Tool listing works correctly (returns proper schema)
- Tool execution fails with missing environment variable errors
- Environment variables are visible in Lambda main process but not in MCP server subprocess

**Current Status**: Under investigation. Consider alternative configuration approaches or subprocess environment passing modifications.

**Workaround**: None currently available. This affects AgentCore Gateway integration specifically.

## Deploy with CloudFormation (optional)

You can deploy the Lambda using the provided template `deploy/cloudformation-lambda.yaml`.

1) Build and upload the ZIP (the helper uses a timestamped S3 key so CloudFormation always detects changes)

```bash
./deploy/build_zip.sh
aws s3 cp dist/google_search_mcp_lambda.zip s3://YOUR_BUCKET/path/google_search_mcp_lambda.zip
```

2) Deploy the stack (creates role if RoleArn is blank)

```bash
aws cloudformation deploy \
  --stack-name google-search-mcp \
  --template-file deploy/cloudformation-lambda.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    FunctionName=google-search-mcp \
    S3Bucket=YOUR_BUCKET \
    S3Key=path/google_search_mcp_lambda.zip \
    GoogleApiKey=YOUR_GOOGLE_API_KEY \
    GoogleCx=YOUR_CX \
    GoogleLogLevel=INFO \
    GoogleLogQueries=false \
    GoogleLogQueryText=false
```

To use an existing role, add `RoleArn=arn:aws:iam::<ACCOUNT_ID>:role/<LambdaExecRole>` to `--parameter-overrides`.

Outputs from the stack include the function name and ARN.

### One-command helper (build + upload + deploy)

Use the helper script to do all the above in one go. It will auto-load env vars from a `.env` file at the repo root if present.

```bash
# Option 1: Put these in .env at the repo root (auto-loaded by the script)
# GOOGLE_API_KEY=YOUR_GOOGLE_API_KEY
# GOOGLE_CX=YOUR_CX
# GOOGLE_LOG_LEVEL=INFO
# GOOGLE_LOG_QUERIES=false
# GOOGLE_LOG_QUERY_TEXT=false

# Option 2: export variables in the shell (if not using .env)
export GOOGLE_API_KEY=YOUR_GOOGLE_API_KEY
export GOOGLE_CX=YOUR_CX

# optional env vars
export FUNCTION_NAME=google-search-mcp
export TIMEOUT=60
export MEMORY=512
export LOG_RETENTION=14

# run: ./deploy/cfn_deploy.sh <stack-name> <s3-bucket> [s3-prefix] [region]
./deploy/cfn_deploy.sh google-search-mcp my-artifacts-bucket path/to us-west-2
```

Notes:
- If you already have an execution role, set `ROLE_ARN` before running.
- If you see a permissions error running the script, you can either run `chmod +x deploy/cfn_deploy.sh` or invoke it with `bash deploy/cfn_deploy.sh ...`.
