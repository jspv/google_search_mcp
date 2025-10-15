#!/bin/bash
# Deploy Google Search MCP as containerized service

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration
SERVICE_NAME="${1:-google-search-mcp}"
REGION="${2:-us-east-1}"
ACCOUNT_ID="${3:-$(aws sts get-caller-identity --query Account --output text)}"
DEPLOYMENT_TYPE="${4:-ecs-fargate}"  # ecs-fargate, ecs-ec2, or standalone
IMAGE_TAG="${5:-latest}"

echo "🐳 Deploying Google Search MCP Container Service"
echo "Service Name: $SERVICE_NAME"
echo "Region: $REGION"
echo "Account ID: $ACCOUNT_ID"
echo "Deployment Type: $DEPLOYMENT_TYPE"
echo "Image Tag: $IMAGE_TAG"
echo

cd "$PROJECT_ROOT"

# Step 1: Build container image
echo "📦 Building MCP container image..."
docker build -f Dockerfile.mcp -t "$SERVICE_NAME:$IMAGE_TAG" .

# Step 2: Create ECR repository if needed
echo "🏗️  Setting up ECR repository..."
ECR_REPOSITORY="$SERVICE_NAME-mcp"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPOSITORY}"

aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" --region "$REGION" >/dev/null 2>&1 || {
    echo "Creating ECR repository: $ECR_REPOSITORY"
    aws ecr create-repository --repository-name "$ECR_REPOSITORY" --region "$REGION"
}

# Step 3: Push to ECR
echo "📤 Pushing image to ECR..."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR_URI"
docker tag "$SERVICE_NAME:$IMAGE_TAG" "$ECR_URI:$IMAGE_TAG"
docker push "$ECR_URI:$IMAGE_TAG"

echo "✅ Image pushed to: $ECR_URI:$IMAGE_TAG"

# Step 4: Deploy based on type
case "$DEPLOYMENT_TYPE" in
    "ecs-fargate")
        echo "🚀 Deploying to ECS Fargate..."
        ./deploy/deploy_ecs_fargate.sh "$SERVICE_NAME" "$ECR_URI:$IMAGE_TAG" "$REGION"
        ;;
    "ecs-ec2")
        echo "🚀 Deploying to ECS EC2..."
        ./deploy/deploy_ecs_ec2.sh "$SERVICE_NAME" "$ECR_URI:$IMAGE_TAG" "$REGION"
        ;;
    "standalone")
        echo "🚀 Container ready for standalone deployment"
        echo "Run locally with:"
        echo "docker run -p 8000:8000 -e GOOGLE_API_KEY=your_key -e GOOGLE_CX=your_cx $SERVICE_NAME:$IMAGE_TAG"
        ;;
    *)
        echo "❌ Unknown deployment type: $DEPLOYMENT_TYPE"
        echo "Supported types: ecs-fargate, ecs-ec2, standalone"
        exit 1
        ;;
esac

echo
echo "🎉 MCP Container deployment complete!"
echo
echo "📋 Container Details:"
echo "  Image: $ECR_URI:$IMAGE_TAG"
echo "  Deployment: $DEPLOYMENT_TYPE"
echo
echo "🔧 Available MCP Modes (set MCP_MODE env var):"
echo "  stdio      - Pure MCP over stdin/stdout"
echo "  http       - REST API endpoints"
echo "  http-stream - Server-Sent Events MCP"
echo
echo "🧪 Test the container locally:"
echo "docker run -p 8000:8000 \\"
echo "  -e GOOGLE_API_KEY=your_api_key \\"
echo "  -e GOOGLE_CX=your_cx_id \\"
echo "  -e MCP_MODE=http-stream \\"
echo "  $ECR_URI:$IMAGE_TAG"