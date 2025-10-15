# AWS AgentCore Gateway + Auth0 deployment

This folder contains the Lambda and AgentCore Gateway deployment assets for the
Google Search MCP server when using Auth0 for inbound authentication.

What’s here
- cloudformation-lambda.yaml: Lambda stack template (ZIP-based deploy)
- build_zip.sh: Build Lambda ZIP for linux/amd64 or linux/arm64
- deploy_lambda.sh: Build, upload to S3, and deploy the CloudFormation stack
- gen_tool_schema.sh: Generate the MCP tools schema for AgentCore
  
- deploy_gateway.sh: Best-effort automation using AgentCore control-plane APIs
- test_gateway_auth0.py: End-to-end test against the Gateway using Auth0

Notes
- Scripts compute repo root dynamically; run them from anywhere.
- arm64 is supported and is the default in the template; build with ARCH=arm64.

Gateway automation and role creation
- Reuse an existing Gateway by setting GATEWAY_NAME; the script will only create a target.
- Create a new Gateway by setting:
	- GATEWAY_NAME
	- GATEWAY_AUTHORIZER_TYPE=CUSTOM_JWT or AWS_IAM
	- For CUSTOM_JWT: AUTH_DISCOVERY_URL and AUTH_ALLOWED_AUDIENCE
	- Provide either GATEWAY_ROLE_ARN or GATEWAY_ROLE_NAME, or pass --auto-create-role to let the script create a role named AgentCoreGatewayRole-<GATEWAY_NAME>.

Environment variables
- REGION: AWS region (e.g., us-east-1)
- GATEWAY_NAME: Gateway to reuse or create
- GATEWAY_AUTHORIZER_TYPE: CUSTOM_JWT | AWS_IAM (required when creating a new Gateway)
- AUTH_DISCOVERY_URL, AUTH_ALLOWED_AUDIENCE: required for CUSTOM_JWT (new Gateway)
- GATEWAY_ROLE_ARN: IAM role ARN Gateway will assume (new Gateway)
- GATEWAY_ROLE_NAME: If set, the script resolves ARN via aws iam get-role (new Gateway)
- GATEWAY_TRUST_PRINCIPAL: Service principal for trust policy (default bedrock-agentcore.amazonaws.com)
CLI flags
- --auto-create-role, -a: Auto-create IAM role when a new Gateway requires it (alternative to providing GATEWAY_ROLE_ARN/NAME)