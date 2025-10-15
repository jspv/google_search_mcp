#!/usr/bin/env bash
set -euo pipefail

# Automate AgentCore Gateway setup via AWS CLI.
# Uses the Bedrock AgentCore Control Plane commands:
# - aws bedrock-agentcore-control create-gateway
# - aws bedrock-agentcore-control create-gateway-target
#
# Usage:
#   ./deploy_aws_agentcore_auth0/deploy_gateway.sh [function-arn]
#
# Notes:
# - If .deploy.env exists next to this script, its values (e.g., STACK_NAME, REGION, LAMBDA_FUNCTION_ARN)
#   are used as defaults. The positional function-arn argument overrides these.
#
# Prerequisites:
#   - AWS CLI configured with appropriate permissions
#   - Bedrock AgentCore Gateway service available in region

# ---------- temp file utilities & cleanup trap ----------
TMPFILES=()
_cleanup() {
  # Remove any tmp files we registered (ignore unset/nonexistent)
  local f
  for f in "${TMPFILES[@]:-}"; do
    [[ -n "${f:-}" && -e "$f" ]] && rm -f -- "$f" || true
  done
}
trap _cleanup EXIT
_mktemp() { local f; f="$(mktemp)"; TMPFILES+=("$f"); printf '%s' "$f"; }

# Repo root and persisted deploy settings
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_ENV="$SCRIPT_DIR/.deploy.env"
if [[ -f "$DEPLOY_ENV" ]]; then
  echo "Loading deploy defaults from $DEPLOY_ENV"
  # shellcheck disable=SC1090
  source "$DEPLOY_ENV"
fi

# Parse CLI arguments
AUTO_CREATE_ROLE=false
FORCE_INTERACTIVE=false
POSITIONAL=()
usage() {
  echo "Usage: $0 [--interactive|-i] [--auto-create-role|-a] [function-arn]" >&2
  echo "  --interactive, -i       Force prompting for inputs even if defaults exist in .deploy.env." >&2
  echo "  --auto-create-role, -a  Create IAM role automatically if a new gateway requires it." >&2
  echo "  function-arn            Optional Lambda ARN; otherwise resolved from STACK_NAME/.deploy.env." >&2
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interactive)
      FORCE_INTERACTIVE=true
      shift
      ;;
    -a|--auto-create-role)
      AUTO_CREATE_ROLE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

# Merge positional arg over persisted/default values
if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
  FUNCTION_ARN="${POSITIONAL[0]}"
else
  FUNCTION_ARN="${LAMBDA_FUNCTION_ARN:-}"
fi
STACK_NAME="${STACK_NAME:-}"
REGION="${REGION:-}"

# Load .env if present (API config)
if [[ -f "$REPO_ROOT/.env" ]]; then
  echo "Loading environment from $REPO_ROOT/.env"
  set -a
  # shellcheck disable=SC1090
  source "$REPO_ROOT/.env"
  set +a
fi

# AWS CLI command with region
AWSCMD=(aws)
if [[ -n "$REGION" ]]; then
  AWSCMD+=("--region" "$REGION")
fi
export AWS_PAGER=""

echo "=== AgentCore Gateway API Automation ==="

# Gateway readiness helper: wait until status is READY (or until timeout seconds)
wait_gateway_ready() {
  local gid="$1"; local timeout="${2:-90}"; local start now status url url_raw
  start=$(date +%s)
  echo -n "Waiting for gateway to be READY" >&2
  while true; do
    status=$("${AWSCMD[@]}" bedrock-agentcore-control list-gateways \
      --query "items[?gatewayId=='$gid'].status | [0]" \
      --output text 2>/dev/null || true)
    [[ "$status" == "None" || "$status" == "null" ]] && status=""
    if [[ "$status" == "READY" ]]; then
      # refresh URL as well and require non-empty (use get-gateway; list-gateways doesn't include URL)
      url_raw=$("${AWSCMD[@]}" bedrock-agentcore-control get-gateway \
        --gateway-identifier "$gid" \
        --query "gatewayUrl" \
        --output text 2>/dev/null || true)
      url="$url_raw"
      [[ "$url" == "None" || "$url" == "null" ]] && url=""
      if [[ -n "$url" ]]; then
        GATEWAY_URL="$url"
        echo " -> READY" >&2
        return 0
      fi
    fi
    now=$(date +%s)
    if (( now - start >= timeout )); then
      echo " -> timeout (${timeout}s)" >&2
      return 1
    fi
    echo -n "." >&2
    sleep 2
  done
}

# Step 1: Generate tool schema (prerequisite)
echo "Step 1: Generating tool schema..."
if ! "$SCRIPT_DIR/gen_tool_schema.sh"; then
  echo "ERROR: Failed to generate tool schema." >&2
  exit 1
fi

# Step 2: Get Lambda function ARN (prefer persisted value if available)
if [[ -z "$FUNCTION_ARN" ]]; then
  echo "Step 2: Getting Lambda function ARN from CloudFormation..."
  if [[ -z "${STACK_NAME:-}" ]]; then
    if [[ -t 0 && -t 1 ]]; then
      read -r -p "No function ARN provided. Enter Lambda Function ARN (or press Enter to resolve via STACK_NAME): " _fn || true
      if [[ -n "${_fn:-}" ]]; then
        FUNCTION_ARN="$_fn"
      else
        while [[ -z "${STACK_NAME:-}" ]]; do
          read -r -p "Enter CloudFormation STACK_NAME to resolve FunctionArn: " STACK_NAME || true
        done
      fi
    fi
  fi
  if [[ -z "$FUNCTION_ARN" ]]; then
    if [[ -z "${STACK_NAME:-}" ]]; then
      echo "ERROR: STACK_NAME not set and no function ARN provided. Set STACK_NAME (or pass function ARN)." >&2
      exit 1
    fi
    FUNCTION_ARN=$("${AWSCMD[@]}" cloudformation describe-stacks \
      --stack-name "$STACK_NAME" \
      --query 'Stacks[0].Outputs[?OutputKey==`FunctionArn`].OutputValue' \
      --output text 2>/dev/null || echo "")
  fi

  if [[ -z "$FUNCTION_ARN" ]]; then
    echo "ERROR: Could not get function ARN. Provide it manually:" >&2
    echo "  $0 arn:aws:lambda:REGION:ACCOUNT:function:FUNCTION_NAME" >&2
    exit 1
  fi
fi

echo "✔ Lambda function ARN: $FUNCTION_ARN"

# If forcing interactive, allow changing the function ARN even if it was set
if [[ -t 0 && -t 1 && "$FORCE_INTERACTIVE" == "true" ]]; then
  read -r -p "Lambda Function ARN [${FUNCTION_ARN}]: " _fn2 || true
  if [[ -n "${_fn2:-}" ]]; then
    FUNCTION_ARN="$_fn2"
    echo "✔ Updated Lambda function ARN: $FUNCTION_ARN"
  fi
fi

# Helper to persist latest deploy/gateway info back to .deploy.env
save_deploy_env() {
  {
    echo "# Auto-generated by deploy_gateway.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -n "${STACK_NAME:-}" ]] && echo "STACK_NAME=\"$STACK_NAME\""
    [[ -n "${REGION:-}" ]] && echo "REGION=\"$REGION\""
    # Carry over existing bucket/prefix if previously set
    [[ -n "${S3_BUCKET:-}" ]] && echo "S3_BUCKET=\"$S3_BUCKET\""
    [[ -n "${S3_PREFIX:-}" ]] && echo "S3_PREFIX=\"$S3_PREFIX\""
    [[ -n "${FUNCTION_ARN:-}" ]] && echo "LAMBDA_FUNCTION_ARN=\"$FUNCTION_ARN\""
    [[ -n "${GATEWAY_ROLE_NAME:-}" ]] && echo "GATEWAY_ROLE_NAME=\"$GATEWAY_ROLE_NAME\""
    [[ -n "${GATEWAY_ROLE_ARN:-}" ]] && echo "GATEWAY_ROLE_ARN=\"$GATEWAY_ROLE_ARN\""
    # Preserve user inputs as well so they don't get lost on subsequent runs
    [[ -n "${GATEWAY_NAME:-}" ]] && echo "GATEWAY_NAME=\"$GATEWAY_NAME\""
    [[ -n "${GATEWAY_AUTHORIZER_TYPE:-}" ]] && echo "GATEWAY_AUTHORIZER_TYPE=\"$GATEWAY_AUTHORIZER_TYPE\""
    [[ -n "${AUTH_DISCOVERY_URL:-}" ]] && echo "AUTH_DISCOVERY_URL=\"$AUTH_DISCOVERY_URL\""
    [[ -n "${AUTH_ALLOWED_AUDIENCE:-}" ]] && echo "AUTH_ALLOWED_AUDIENCE=\"$AUTH_ALLOWED_AUDIENCE\""
    [[ -n "${AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL:-}" ]] && echo "AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL=\"$AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL\""
    # New AgentCore Gateway artifacts
    local _GW_ID="${GATEWAY_ID:-}" _GW_URL="${GATEWAY_URL:-}" _GW_ARN="${GATEWAY_ARN:-}" _GW_TGT="${GATEWAY_TARGET_ID:-}"
    [[ "$_GW_URL" == "None" || "$_GW_URL" == "null" ]] && _GW_URL=""
    [[ "$_GW_ARN" == "None" || "$_GW_ARN" == "null" ]] && _GW_ARN=""
    [[ "$_GW_ID" == "None" || "$_GW_ID" == "null" ]] && _GW_ID=""
    [[ "$_GW_TGT" == "None" || "$_GW_TGT" == "null" ]] && _GW_TGT=""
    [[ -n "$_GW_ID" ]] && echo "GATEWAY_ID=\"$_GW_ID\""
    [[ -n "$_GW_URL" ]] && echo "GATEWAY_URL=\"$_GW_URL\""
    [[ -n "$_GW_ARN" ]] && echo "GATEWAY_ARN=\"$_GW_ARN\""
    [[ -n "$_GW_TGT" ]] && echo "GATEWAY_TARGET_ID=\"$_GW_TGT\""
  } > "$DEPLOY_ENV"
  echo "Saved gateway deploy info to $DEPLOY_ENV"
}

# Persist user-provided inputs (so they become defaults next run)
save_inputs_env() {
  {
    echo "# Saved inputs by deploy_gateway.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -n "${STACK_NAME:-}" ]] && echo "STACK_NAME=\"$STACK_NAME\""
    [[ -n "${REGION:-}" ]] && echo "REGION=\"$REGION\""
    [[ -n "${S3_BUCKET:-}" ]] && echo "S3_BUCKET=\"$S3_BUCKET\""
    [[ -n "${S3_PREFIX:-}" ]] && echo "S3_PREFIX=\"$S3_PREFIX\""
    [[ -n "${FUNCTION_ARN:-}" ]] && echo "LAMBDA_FUNCTION_ARN=\"$FUNCTION_ARN\""
    # Inputs gathered interactively or provided via env
    [[ -n "${GATEWAY_NAME:-}" ]] && echo "GATEWAY_NAME=\"$GATEWAY_NAME\""
    [[ -n "${GATEWAY_AUTHORIZER_TYPE:-}" ]] && echo "GATEWAY_AUTHORIZER_TYPE=\"$GATEWAY_AUTHORIZER_TYPE\""
    [[ -n "${AUTH_DISCOVERY_URL:-}" ]] && echo "AUTH_DISCOVERY_URL=\"$AUTH_DISCOVERY_URL\""
    [[ -n "${AUTH_ALLOWED_AUDIENCE:-}" ]] && echo "AUTH_ALLOWED_AUDIENCE=\"$AUTH_ALLOWED_AUDIENCE\""
    [[ -n "${AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL:-}" ]] && echo "AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL=\"$AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL\""
    [[ -n "${GATEWAY_ROLE_NAME:-}" ]] && echo "GATEWAY_ROLE_NAME=\"$GATEWAY_ROLE_NAME\""
    [[ -n "${GATEWAY_ROLE_ARN:-}" ]] && echo "GATEWAY_ROLE_ARN=\"$GATEWAY_ROLE_ARN\""
    # Carry through any existing gateway artifacts so we don't lose them
    [[ -n "${GATEWAY_ID:-}" ]] && echo "GATEWAY_ID=\"$GATEWAY_ID\""
    [[ -n "${GATEWAY_URL:-}" ]] && echo "GATEWAY_URL=\"$GATEWAY_URL\""
    [[ -n "${GATEWAY_ARN:-}" ]] && echo "GATEWAY_ARN=\"$GATEWAY_ARN\""
    [[ -n "${GATEWAY_TARGET_ID:-}" ]] && echo "GATEWAY_TARGET_ID=\"$GATEWAY_TARGET_ID\""
  } > "$DEPLOY_ENV"
  echo "Saved inputs to $DEPLOY_ENV"
}

# Step 3: Attempt Gateway automation if required env vars are provided
echo ""
echo "=== Checking for automation prerequisites ==="

gateway_schema_path="$REPO_ROOT/dist/schema/tool-schema.json"
if [[ ! -f "$gateway_schema_path" ]]; then
  echo "ERROR: Schema not found at $gateway_schema_path; cannot automate target creation." >&2
  do_automation=false
else
  do_automation=true
fi

# Required inputs
GATEWAY_NAME="${GATEWAY_NAME:-}"
GATEWAY_ROLE_ARN="${GATEWAY_ROLE_ARN:-}"
# Default authorizer to CUSTOM_JWT if not provided
GATEWAY_AUTHORIZER_TYPE="${GATEWAY_AUTHORIZER_TYPE:-CUSTOM_JWT}"
# Option to derive CUSTOM_JWT audience from the gateway URL post-creation
AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL="${AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL:-false}"

# Optional: resolve role ARN from role name if provided
if [[ -z "$GATEWAY_ROLE_ARN" && -n "${GATEWAY_ROLE_NAME:-}" ]]; then
  GATEWAY_ROLE_ARN=$("${AWSCMD[@]}" iam get-role \
    --role-name "$GATEWAY_ROLE_NAME" \
    --query 'Role.Arn' --output text 2>/dev/null || true)
fi

# Optional: detect existing gateway by name (allows automation without role ARN)
EXISTING_GATEWAY_ID=""
if [[ -n "$GATEWAY_NAME" ]]; then
  EXISTING_GATEWAY_ID=$("${AWSCMD[@]}" bedrock-agentcore-control list-gateways \
    --query "items[?name=='$GATEWAY_NAME'].gatewayId | [0]" \
    --output text 2>/dev/null || true)
  [[ "$EXISTING_GATEWAY_ID" == "None" || "$EXISTING_GATEWAY_ID" == "null" ]] && EXISTING_GATEWAY_ID=""
fi

# If running interactively, prompt for any missing required values
if [[ -t 0 && -t 1 ]]; then
  # Prompt for gateway name if missing
  if [[ -z "$GATEWAY_NAME" || "$FORCE_INTERACTIVE" == "true" ]]; then
    while true; do
      if [[ -n "${GATEWAY_NAME:-}" ]]; then
        read -r -p "Enter Gateway name [${GATEWAY_NAME}]: " _gw || true
        GATEWAY_NAME="${_gw:-$GATEWAY_NAME}"
      else
        read -r -p "Enter Gateway name: " GATEWAY_NAME || true
      fi
      [[ -n "${GATEWAY_NAME:-}" ]] && break
      echo "Gateway name cannot be empty." >&2
    done
    # Re-resolve existing gateway by name after prompting
    EXISTING_GATEWAY_ID=$("${AWSCMD[@]}" bedrock-agentcore-control list-gateways \
      --query "items[?name=='$GATEWAY_NAME'].gatewayId | [0]" \
      --output text 2>/dev/null || true)
    [[ "$EXISTING_GATEWAY_ID" == "None" || "$EXISTING_GATEWAY_ID" == "null" ]] && EXISTING_GATEWAY_ID=""
  fi

  # If creating a new gateway OR forcing interactive, ensure auth fields are provided
  if [[ -z "$EXISTING_GATEWAY_ID" || "$FORCE_INTERACTIVE" == "true" ]]; then
    # Allow user to override authorizer type if desired
    if [[ -z "${_USER_CONFIRMED_AUTH_TYPE:-}" || "$FORCE_INTERACTIVE" == "true" ]]; then
      read -r -p "Authorizer type [CUSTOM_JWT/AWS_IAM] (default CUSTOM_JWT): " _auth_type || true
      _auth_type=${_auth_type:-CUSTOM_JWT}
      _auth_type=$(printf '%s' "$_auth_type" | tr '[:lower:]' '[:upper:]')
      case "$_auth_type" in
        CUSTOM_JWT|AWS_IAM)
          GATEWAY_AUTHORIZER_TYPE="$_auth_type"
          ;;
        *)
          echo "Unrecognized authorizer '$_auth_type', using CUSTOM_JWT" >&2
          GATEWAY_AUTHORIZER_TYPE="CUSTOM_JWT"
          ;;
      esac
      _USER_CONFIRMED_AUTH_TYPE=1
    fi

    if [[ "$GATEWAY_AUTHORIZER_TYPE" == "CUSTOM_JWT" ]]; then
      if [[ -z "${AUTH_DISCOVERY_URL:-}" || "$FORCE_INTERACTIVE" == "true" ]]; then
        if [[ -n "${AUTH_DISCOVERY_URL:-}" ]]; then
          read -r -p "OIDC discovery URL (e.g., https://issuer.example/.well-known/openid-configuration) [${AUTH_DISCOVERY_URL}]: " _disc || true
          AUTH_DISCOVERY_URL="${_disc:-$AUTH_DISCOVERY_URL}"
        else
          read -r -p "OIDC discovery URL (e.g., https://issuer.example/.well-known/openid-configuration): " AUTH_DISCOVERY_URL || true
        fi
      fi
      if [[ -z "${AUTH_ALLOWED_AUDIENCE:-}" || "$FORCE_INTERACTIVE" == "true" ]]; then
        echo "Audience can be set to the gateway URL after creation."
        default_use_url="Y"; [[ "${AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL:-false}" == "false" && -n "${AUTH_ALLOWED_AUDIENCE:-}" ]] && default_use_url="n"
        read -r -p "Use gateway URL as audience? - note: required for Auth0 [Y/n] (default ${default_use_url}): " _use_url || true
        _use_url=${_use_url:-$default_use_url}
        case "${_use_url:-}" in
          n|N|no|NO)
            if [[ -n "${AUTH_ALLOWED_AUDIENCE:-}" ]]; then
              read -r -p "Allowed audience (comma-separated, e.g., aud-1,aud-2) [${AUTH_ALLOWED_AUDIENCE}]: " _aud || true
              AUTH_ALLOWED_AUDIENCE="${_aud:-$AUTH_ALLOWED_AUDIENCE}"
            else
              read -r -p "Allowed audience (comma-separated, e.g., aud-1,aud-2): " AUTH_ALLOWED_AUDIENCE || true
            fi
            AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL=false
            ;;
          *)
            AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL=true
            ;;
        esac
      fi
    fi

    # Role: if creating new or forcing interactive, prompt for role/auto-create
    if [[ ( -z "${GATEWAY_ROLE_ARN:-}" && "$AUTO_CREATE_ROLE" != "true" ) || "$FORCE_INTERACTIVE" == "true" ]]; then
      while [[ -z "${GATEWAY_ROLE_ARN:-}" && "$AUTO_CREATE_ROLE" != "true" ]]; do
        if [[ -n "${GATEWAY_ROLE_ARN:-}" && "$FORCE_INTERACTIVE" == "true" ]]; then
          read -r -p "Update IAM role? Auto-create if needed? [y/N]: " _ans || true
        else
          read -r -p "No IAM role provided. Auto-create role now? [y/N]: " _ans || true
        fi
        case "${_ans:-}" in
          y|Y|yes|YES)
            AUTO_CREATE_ROLE=true
            break
            ;;
          *)
            if [[ -n "${GATEWAY_ROLE_ARN:-}" ]]; then
              read -r -p "Enter IAM role ARN (or role name to resolve) [${GATEWAY_ROLE_ARN}]: " _role_input || true
              _role_input="${_role_input:-$GATEWAY_ROLE_ARN}"
            else
              read -r -p "Enter IAM role ARN (or role name to resolve): " _role_input || true
            fi
            if [[ -z "${_role_input:-}" ]]; then
              echo "Please provide an IAM role ARN or name, or choose auto-create." >&2
              continue
            fi
            # Reject clear misinputs: Lambda ARNs are not IAM role ARNs
            if [[ "$_role_input" == arn:aws:lambda:* ]]; then
              echo "That looks like a Lambda Function ARN. Please provide an IAM role ARN (arn:aws:iam::...) or a role name, or choose auto-create." >&2
              continue
            fi
            if [[ "$_role_input" == arn:aws:iam::* ]]; then
              GATEWAY_ROLE_ARN="$_role_input"
              break
            else
              # Try to resolve role name to ARN
              GATEWAY_ROLE_ARN=$("${AWSCMD[@]}" iam get-role \
                --role-name "$_role_input" \
                --query 'Role.Arn' --output text 2>/dev/null || true)
              if [[ -z "${GATEWAY_ROLE_ARN:-}" ]]; then
                echo "Could not resolve role name '$_role_input' to an ARN. Try again or choose auto-create." >&2
                continue
              else
                GATEWAY_ROLE_NAME="$_role_input"
                break
              fi
            fi
            ;;
        esac
      done
    fi
  fi
fi

# After interactive prompts, persist inputs so next run uses them as defaults
if [[ -t 0 && -t 1 ]]; then
  save_inputs_env
fi

# Track missing prerequisites for helpful diagnostics
missing=()
[[ -f "$gateway_schema_path" ]] || missing+=("tool-schema($gateway_schema_path)")
[[ -n "$GATEWAY_NAME" ]] || missing+=("GATEWAY_NAME")
if [[ -z "$GATEWAY_ROLE_ARN" && -z "$EXISTING_GATEWAY_ID" && "$AUTO_CREATE_ROLE" != "true" ]]; then
  if [[ -n "$GATEWAY_NAME" ]]; then
    missing+=("GATEWAY_ROLE_ARN or existing Gateway named '$GATEWAY_NAME'")
  else
    missing+=("GATEWAY_ROLE_ARN or existing Gateway (set GATEWAY_NAME)")
  fi
fi
if [[ -z "$EXISTING_GATEWAY_ID" ]]; then
  [[ -n "$GATEWAY_AUTHORIZER_TYPE" ]] || missing+=("GATEWAY_AUTHORIZER_TYPE")
fi

if [[ -z "$GATEWAY_NAME" ]]; then
  do_automation=false
fi

# Only require CUSTOM_JWT extras if we need to create a new gateway (no existing one)
if [[ -z "$EXISTING_GATEWAY_ID" && "$GATEWAY_AUTHORIZER_TYPE" == "CUSTOM_JWT" ]]; then
  if [[ -z "${AUTH_DISCOVERY_URL:-}" ]]; then
    do_automation=false
    missing+=("AUTH_DISCOVERY_URL")
  fi
  # AUTH_ALLOWED_AUDIENCE can be postponed if using gateway URL
  if [[ -z "${AUTH_ALLOWED_AUDIENCE:-}" && "${AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL}" != "true" ]]; then
    do_automation=false
    missing+=("AUTH_ALLOWED_AUDIENCE or set AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL=true")
  fi
fi

if [[ "$do_automation" == "true" ]]; then
  echo "Automation prerequisites satisfied. Proceeding…"

  # 3a. Create or find Gateway
  echo "Looking up gateway named '$GATEWAY_NAME'..."
  GATEWAY_ID="$EXISTING_GATEWAY_ID"
  if [[ -n "$GATEWAY_ID" ]]; then
    echo "✔ Found existing gateway: $GATEWAY_ID"
    # If forcing interactive, offer to update gateway configuration (role/authorizer)
    if [[ -t 0 && -t 1 && "$FORCE_INTERACTIVE" == "true" ]]; then
      # Ensure URL for audience substitution if requested
      [[ -z "${GATEWAY_URL:-}" ]] && GATEWAY_URL=$("${AWSCMD[@]}" bedrock-agentcore-control get-gateway \
        --gateway-identifier "$GATEWAY_ID" \
        --query "gatewayUrl" --output text 2>/dev/null || true)

      if [[ "$GATEWAY_AUTHORIZER_TYPE" == "CUSTOM_JWT" ]]; then
        # Build authorizer-configuration JSON when CUSTOM_JWT
        local_aud=""
        if [[ "${AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL}" == "true" && -n "${GATEWAY_URL:-}" ]]; then
          local_aud='"allowedAudience": ["'"${GATEWAY_URL}"'"]'
        elif [[ -n "${AUTH_ALLOWED_AUDIENCE:-}" ]]; then
          local_aud=$(printf '%s' "${AUTH_ALLOWED_AUDIENCE}" | awk -F',' '{printf "\"allowedAudience\": ["; for(i=1;i<=NF;i++){gsub(/^ *| *$/,"",$i); printf "%s\"%s\"", (i>1?",":""), $i} printf "]"}')
        fi
        auth_cfg='{ "customJWTAuthorizer": { '
        if [[ -n "${AUTH_DISCOVERY_URL:-}" ]]; then auth_cfg+="\"discoveryUrl\": \"${AUTH_DISCOVERY_URL}\""; fi
        if [[ -n "$local_aud" && -n "${AUTH_DISCOVERY_URL:-}" ]]; then auth_cfg+=', '; fi
        if [[ -n "$local_aud" ]]; then auth_cfg+="$local_aud"; fi
        auth_cfg+=' } }'

        # update-gateway requires role-arn; resolve from API if missing
        if [[ -z "${GATEWAY_ROLE_ARN:-}" ]]; then
          GATEWAY_ROLE_ARN=$("${AWSCMD[@]}" bedrock-agentcore-control get-gateway \
            --gateway-identifier "$GATEWAY_ID" \
            --query "roleArn" \
            --output text 2>/dev/null || true)
          [[ "$GATEWAY_ROLE_ARN" == "None" || "$GATEWAY_ROLE_ARN" == "null" ]] && GATEWAY_ROLE_ARN=""
        fi

        if [[ -z "${GATEWAY_ROLE_ARN:-}" ]]; then
          echo "NOTE: Skipping update-gateway because role ARN is unknown. Set GATEWAY_ROLE_ARN to update authorizer settings." >&2
        else
          "${AWSCMD[@]}" bedrock-agentcore-control update-gateway \
            --gateway-identifier "$GATEWAY_ID" \
            --name "$GATEWAY_NAME" \
            --role-arn "$GATEWAY_ROLE_ARN" \
            --protocol-type MCP \
            --authorizer-type CUSTOM_JWT \
            --authorizer-configuration "$auth_cfg" >/dev/null 2>&1 || true
        fi
      else
        # Non-CUSTOM_JWT update path
        if [[ -z "${GATEWAY_ROLE_ARN:-}" ]]; then
          GATEWAY_ROLE_ARN=$("${AWSCMD[@]}" bedrock-agentcore-control get-gateway \
            --gateway-identifier "$GATEWAY_ID" \
            --query "roleArn" \
            --output text 2>/dev/null || true)
          [[ "$GATEWAY_ROLE_ARN" == "None" || "$GATEWAY_ROLE_ARN" == "null" ]] && GATEWAY_ROLE_ARN=""
        fi
        if [[ -n "${GATEWAY_ROLE_ARN:-}" ]]; then
          "${AWSCMD[@]}" bedrock-agentcore-control update-gateway \
            --gateway-identifier "$GATEWAY_ID" \
            --name "$GATEWAY_NAME" \
            --role-arn "$GATEWAY_ROLE_ARN" \
            --protocol-type MCP \
            --authorizer-type "$GATEWAY_AUTHORIZER_TYPE" >/dev/null 2>&1 || true
        fi
      fi
    fi
  else
    echo "Creating gateway '$GATEWAY_NAME'..."
    # Ensure role exists if not provided and auto-create is enabled via CLI
    if [[ -z "$GATEWAY_ROLE_ARN" && "$AUTO_CREATE_ROLE" == "true" ]]; then
      # Derive a safe role name if not provided
      if [[ -z "${GATEWAY_ROLE_NAME:-}" ]]; then
        safe_name=$(printf '%s' "$GATEWAY_NAME" | tr -c 'A-Za-z0-9+=,.@_- ' '-' | tr ' ' '-')
        GATEWAY_ROLE_NAME="AgentCoreGatewayRole-${safe_name}"
      fi
      echo "Creating IAM role '$GATEWAY_ROLE_NAME' for AgentCore Gateway..."
      trust_principal="${GATEWAY_TRUST_PRINCIPAL:-bedrock-agentcore.amazonaws.com}"
      trust_file=$(_mktemp)
      policy_file=$(_mktemp)
      cat > "$trust_file" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": ["$trust_principal"] },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
      if ! ROLE_CREATE_OUT=$("${AWSCMD[@]}" iam create-role \
        --role-name "$GATEWAY_ROLE_NAME" \
        --assume-role-policy-document file://"$trust_file" \
        --description "Role assumed by Bedrock AgentCore Gateway to invoke Lambda targets" \
        --output json 2>/dev/null); then
        echo "Failed to create role '$GATEWAY_ROLE_NAME'. If it already exists, set GATEWAY_ROLE_NAME or GATEWAY_ROLE_ARN." >&2
        exit 1
      fi
      # Resolve ARN (whether created just now or pre-existing)
      GATEWAY_ROLE_ARN=$("${AWSCMD[@]}" iam get-role --role-name "$GATEWAY_ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || true)
      if [[ -n "$GATEWAY_ROLE_ARN" ]]; then
        cat > "$policy_file" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InvokeLambda",
      "Effect": "Allow",
      "Action": ["lambda:InvokeFunction"],
      "Resource": ["$FUNCTION_ARN", "$FUNCTION_ARN:*"]
    }
  ]
}
EOF
        echo "Attaching inline Lambda invoke policy to role '$GATEWAY_ROLE_NAME'..."
        "${AWSCMD[@]}" iam put-role-policy \
          --role-name "$GATEWAY_ROLE_NAME" \
          --policy-name "AgentCoreGatewayLambdaInvoke" \
          --policy-document file://"$policy_file" >/dev/null 2>&1 || true
        echo "✔ Role ready: $GATEWAY_ROLE_ARN"
      else
        echo "ERROR: Could not resolve role ARN for '$GATEWAY_ROLE_NAME'." >&2
        exit 1
      fi
    fi

    AUTH_ARGS=()
    if [[ "$GATEWAY_AUTHORIZER_TYPE" == "CUSTOM_JWT" ]]; then
      if [[ -n "${AUTH_ALLOWED_AUDIENCE:-}" ]]; then
        # Use provided audience at creation time
        aud_json=$(printf '%s' "${AUTH_ALLOWED_AUDIENCE}" | awk -F',' '{printf "["; for(i=1;i<=NF;i++){gsub(/^ *| *$/,"",$i); printf "%s\"%s\"", (i>1?",":""), $i} printf "]"}')
        auth_cfg='{ "customJWTAuthorizer": { "discoveryUrl": "'"${AUTH_DISCOVERY_URL}"'", "allowedAudience": '"${aud_json}"' } }'
        AUTH_ARGS=(--authorizer-configuration "$auth_cfg")
      elif [[ "${AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL}" == "true" ]]; then
        # Some control planes require allowedAudience at creation. Use a temporary placeholder and update later.
        PLACEHOLDER_AUD="${AUTH_ALLOWED_AUDIENCE_PLACEHOLDER:-urn:temp:aud}"
        auth_cfg='{ "customJWTAuthorizer": { "discoveryUrl": "'"${AUTH_DISCOVERY_URL}"'", "allowedAudience": ["'"${PLACEHOLDER_AUD}"'"] } }'
        AUTH_ARGS=(--authorizer-configuration "$auth_cfg")
        echo "NOTE: Using temporary allowedAudience '${PLACEHOLDER_AUD}' for creation; will update to gateway URL after creation." >&2
      else
        # Fallback (if API allows missing audience)
        auth_cfg='{ "customJWTAuthorizer": { "discoveryUrl": "'"${AUTH_DISCOVERY_URL}"'" } }'
        AUTH_ARGS=(--authorizer-configuration "$auth_cfg")
      fi
    fi

    errfile=$(_mktemp)
    if OUT_JSON=$("${AWSCMD[@]}" bedrock-agentcore-control create-gateway \
      --name "$GATEWAY_NAME" \
      --role-arn "$GATEWAY_ROLE_ARN" \
      --protocol-type MCP \
      --authorizer-type "$GATEWAY_AUTHORIZER_TYPE" \
      "${AUTH_ARGS[@]}" \
      --output json 2>"$errfile"); then
      # Retrieve identifiers using list-gateways to avoid jq dependency
      GATEWAY_ID=$("${AWSCMD[@]}" bedrock-agentcore-control list-gateways \
        --query "items[?name=='$GATEWAY_NAME'].gatewayId | [0]" \
        --output text 2>/dev/null || true)
      GATEWAY_URL=$("${AWSCMD[@]}" bedrock-agentcore-control get-gateway \
        --gateway-identifier "$GATEWAY_ID" \
        --query "gatewayUrl" \
        --output text 2>/dev/null || true)
      [[ "$GATEWAY_URL" == "None" || "$GATEWAY_URL" == "null" ]] && GATEWAY_URL=""
      GATEWAY_ARN=$("${AWSCMD[@]}" bedrock-agentcore-control get-gateway \
        --gateway-identifier "$GATEWAY_ID" \
        --query "gatewayArn" \
        --output text 2>/dev/null || true)
      [[ "$GATEWAY_ARN" == "None" || "$GATEWAY_ARN" == "null" ]] && GATEWAY_ARN=""
      echo "✔ Created gateway: ${GATEWAY_ID:-<unknown>}"

      # If requested, set allowedAudience to the gateway URL post-creation
      if [[ "$GATEWAY_AUTHORIZER_TYPE" == "CUSTOM_JWT" && "$AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL" == "true" ]]; then
        # Ensure the gateway is READY and has a non-empty URL before updating
        wait_gateway_ready "$GATEWAY_ID" 180 || true
        if [[ -n "${GATEWAY_URL:-}" ]]; then
          # Ensure role-arn for update
          if [[ -z "${GATEWAY_ROLE_ARN:-}" ]]; then
            GATEWAY_ROLE_ARN=$("${AWSCMD[@]}" bedrock-agentcore-control get-gateway \
              --gateway-identifier "$GATEWAY_ID" \
              --query "roleArn" \
              --output text 2>/dev/null || true)
            [[ "$GATEWAY_ROLE_ARN" == "None" || "$GATEWAY_ROLE_ARN" == "null" ]] && GATEWAY_ROLE_ARN=""
          fi
          if [[ -n "${GATEWAY_ROLE_ARN:-}" ]]; then
            auth_cfg='{ "customJWTAuthorizer": { "discoveryUrl": "'"${AUTH_DISCOVERY_URL}"'", "allowedAudience": ["'"${GATEWAY_URL}"'"] } }'
            upd_err=$(_mktemp)
            if ! "${AWSCMD[@]}" bedrock-agentcore-control update-gateway \
              --gateway-identifier "$GATEWAY_ID" \
              --name "$GATEWAY_NAME" \
              --role-arn "$GATEWAY_ROLE_ARN" \
              --protocol-type MCP \
              --authorizer-type CUSTOM_JWT \
              --authorizer-configuration "$auth_cfg" >/dev/null 2>"$upd_err"; then
              echo "NOTE: update-gateway failed when setting allowedAudience to gateway URL." >&2
              echo "--- AWS CLI error (update-gateway) ---" >&2
              cat "$upd_err" >&2 || true
              echo "--------------------------------------" >&2
              echo "Authorizer configuration sent:" >&2
              echo "$auth_cfg" >&2
            else
              echo "✔ Updated allowedAudience to gateway URL." >&2
            fi
          else
            echo "NOTE: Unable to update gateway audience automatically because role ARN is unknown. You can update it manually via CLI/Console." >&2
          fi
        else
          echo "NOTE: Gateway URL not available to set as audience; skipping audience update." >&2
        fi
      fi
    else
      echo "ERROR: Failed to create gateway via AWS CLI." >&2
      if [[ -s "$errfile" ]]; then
        echo "--- AWS CLI error ---" >&2
        cat "$errfile" >&2 || true
        echo "---------------------" >&2
      fi
      exit 1
    fi
  fi

  # 3b. Create Gateway Target (Lambda + tool schema)
  if [[ -n "${GATEWAY_ID:-}" ]]; then
    GATEWAY_TARGET_NAME="${GATEWAY_TARGET_NAME:-lambda-target}"
    # Idempotence: if a target with this name already exists, reuse it
    existing_target_id=$("${AWSCMD[@]}" bedrock-agentcore-control list-gateway-targets \
      --gateway-identifier "$GATEWAY_ID" \
      --query "items[?name=='$GATEWAY_TARGET_NAME'].targetId | [0]" \
      --output text 2>/dev/null || true)
    if [[ "$existing_target_id" != "None" && -n "$existing_target_id" && "$existing_target_id" != "null" ]]; then
      GATEWAY_TARGET_ID="$existing_target_id"
      echo "✔ Found existing gateway target '$GATEWAY_TARGET_NAME': $GATEWAY_TARGET_ID"
      save_deploy_env
      printf "\nGateway automation complete.\n"
      echo "Gateway ID: ${GATEWAY_ID}"
      [[ -n "${GATEWAY_URL:-}" ]] && echo "Gateway URL: ${GATEWAY_URL}"
      exit 0
    fi

    echo "Creating gateway target '$GATEWAY_TARGET_NAME' for Lambda ARN..."

    # Clean tool schema to match Gateway expectations (strip unsupported keys like title, default, icons, etc.)
    cleaned_schema=$(_mktemp)
    python3 - "$gateway_schema_path" "$cleaned_schema" <<'PY' || {
import json, sys

def clean_schema(node):
    allowed = {"type", "properties", "required", "items", "description"}
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if k == "properties" and isinstance(v, dict):
                out[k] = {pk: clean_schema(pv) for pk, pv in v.items()}
            elif k == "items":
                out[k] = clean_schema(v)
            elif k in allowed:
                out[k] = clean_schema(v)
        return out
    elif isinstance(node, list):
        return [clean_schema(x) for x in node]
    else:
        return node

def clean_tool(tool):
    kept = {k: tool.get(k) for k in ("name", "description", "inputSchema", "outputSchema") if k in tool}
    if "inputSchema" in kept:
        kept["inputSchema"] = clean_schema(kept["inputSchema"])
    if "outputSchema" in kept:
        kept["outputSchema"] = clean_schema(kept["outputSchema"])
    return kept

inp, outp = sys.argv[1], sys.argv[2]
with open(inp, "r") as f:
    data = json.load(f)
if not isinstance(data, list):
    raise SystemExit("tool-schema must be a list of tools")
cleaned = [clean_tool(t) for t in data]
with open(outp, "w") as f:
    json.dump(cleaned, f, separators=(",", ":"))
PY
      echo "ERROR: Failed to sanitize tool schema for gateway target." >&2
      exit 1
    }

    # Credential provider will use the gateway's IAM role; no extra role details are provided here per CLI contract

    # Create the gateway target using the known-good configuration (lambda + inline toolSchema, GATEWAY_IAM_ROLE)
    errfile2=$(_mktemp)
  schema_json=$(cat "$cleaned_schema")
  TARGET_CFG=$(printf '{ "mcp": { "lambda": { "lambdaArn": "%s", "toolSchema": { "inlinePayload": %s } } } }' "$FUNCTION_ARN" "$schema_json")
  CRED_CFG='[ { "credentialProviderType": "GATEWAY_IAM_ROLE" } ]'
    if GATEWAY_TARGET_ID=$("${AWSCMD[@]}" bedrock-agentcore-control create-gateway-target \
      --gateway-identifier "$GATEWAY_ID" \
      --name "$GATEWAY_TARGET_NAME" \
      --credential-provider-configurations "$CRED_CFG" \
      --target-configuration "$TARGET_CFG" \
      --query 'targetId' --output text 2>"$errfile2"); then
      echo "✔ Created gateway target: $GATEWAY_TARGET_ID"
      save_deploy_env
      printf "\nGateway automation complete.\n"
      echo "Gateway ID: ${GATEWAY_ID}"
      [[ -n "${GATEWAY_URL:-}" ]] && echo "Gateway URL: ${GATEWAY_URL}"
      exit 0
    else
      echo "ERROR: Failed to create gateway target." >&2
      if [[ -s "$errfile2" ]]; then
        echo "--- AWS CLI error (create-gateway-target) ---" >&2
        cat "$errfile2" >&2 || true
        echo "--------------------------------------------" >&2
      fi
      echo "Target configuration (primary) sent:" >&2
      echo "$TARGET_CFG" >&2
      echo "Credential provider configurations (primary) sent:" >&2
      echo "$CRED_CFG" >&2
      exit 1
    fi
  fi
fi

# Final retry: if audience-to-URL was requested but earlier skipped due to missing URL, try one last time now
if [[ -n "${GATEWAY_ID:-}" && "${GATEWAY_AUTHORIZER_TYPE:-}" == "CUSTOM_JWT" && "${AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL:-}" == "true" ]]; then
  if [[ -z "${GATEWAY_URL:-}" ]]; then
    wait_gateway_ready "$GATEWAY_ID" 60 || true
  fi
  if [[ -n "${GATEWAY_URL:-}" && -n "${GATEWAY_ROLE_ARN:-}" ]]; then
    auth_cfg='{ "customJWTAuthorizer": { "discoveryUrl": "'"${AUTH_DISCOVERY_URL}"'", "allowedAudience": ["'"${GATEWAY_URL}"'"] } }'
    upd_err=$(_mktemp)
    if ! "${AWSCMD[@]}" bedrock-agentcore-control update-gateway \
      --gateway-identifier "$GATEWAY_ID" \
      --name "$GATEWAY_NAME" \
      --role-arn "$GATEWAY_ROLE_ARN" \
      --protocol-type MCP \
      --authorizer-type CUSTOM_JWT \
      --authorizer-configuration "$auth_cfg" >/dev/null 2>"$upd_err"; then
      echo "NOTE: Final audience update attempt failed." >&2
      echo "--- AWS CLI error (update-gateway final) ---" >&2
      cat "$upd_err" >&2 || true
      echo "-------------------------------------------" >&2
    else
      echo "Updated allowedAudience to gateway URL after readiness." >&2
    fi
  fi
fi
if [[ "$do_automation" != "true" ]]; then
  echo ""
  echo "Automation prerequisites missing:"
  if [[ ${#missing[@]} -gt 0 ]]; then
    for _item in "${missing[@]}"; do
      echo "  - ${_item}"
    done
  else
    echo "  - One or more required variables are unset."
  fi
  echo ""
  echo "Provide variables and re-run this script:"
  echo "  Always:"
  echo "    - GATEWAY_NAME: Name for the AgentCore Gateway (existing to reuse, or new to create)"
  echo "  When creating a NEW gateway (no existing gateway with that name):"
  echo "    - GATEWAY_ROLE_ARN: IAM role ARN that the Gateway will assume (or set GATEWAY_ROLE_NAME to resolve)"
  echo "    - GATEWAY_AUTHORIZER_TYPE: CUSTOM_JWT (default) or AWS_IAM"
  echo "  Alternatives:"
  echo "    - GATEWAY_ROLE_NAME: Resolve the role ARN via 'aws iam get-role'"
  echo "    - Reuse an existing gateway by setting only GATEWAY_NAME; role/auth not required in that case"
  if [[ "${GATEWAY_AUTHORIZER_TYPE:-CUSTOM_JWT}" == "CUSTOM_JWT" || -z "${GATEWAY_AUTHORIZER_TYPE:-}" ]]; then
    echo "  If using CUSTOM_JWT authorizer:"
    echo "    - AUTH_DISCOVERY_URL: OIDC discovery URL (.well-known/openid-configuration)"
    echo "    - AUTH_ALLOWED_AUDIENCE: Comma-separated audience values"
    echo "      or set AUTH_ALLOWED_AUDIENCE_USE_GATEWAY_URL=true to use the gateway URL after creation"
  fi
  echo ""
  echo "Example:"
  echo "  export REGION=${REGION:-<region>}"
  echo "  export GATEWAY_NAME=\"my-mcp-gateway\""
  echo "  export GATEWAY_ROLE_ARN=\"arn:aws:iam::<account-id>:role/<AgentCoreGatewayRole>\""
  echo "  export GATEWAY_AUTHORIZER_TYPE=CUSTOM_JWT"
  echo "  export AUTH_DISCOVERY_URL=\"https://issuer.example/.well-known/openid-configuration\""
  echo "  export AUTH_ALLOWED_AUDIENCE=\"aud-1,aud-2\""
  echo "  $0 ${FUNCTION_ARN}"
  exit 1
fi
