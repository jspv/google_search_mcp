#!/bin/bash
# Deploy MCP service to ECS Fargate

set -euo pipefail

SERVICE_NAME="$1"
IMAGE_URI="$2"
REGION="$3"
CLUSTER_NAME="${SERVICE_NAME}-cluster"
TASK_FAMILY="${SERVICE_NAME}-task"
SERVICE_NAME_ECS="${SERVICE_NAME}-service"

echo "🚀 Deploying to ECS Fargate..."
echo "Service: $SERVICE_NAME"
echo "Image: $IMAGE_URI"
echo "Region: $REGION"

# Create ECS cluster
echo "📋 Creating ECS cluster..."
aws ecs create-cluster \
    --cluster-name "$CLUSTER_NAME" \
    --capacity-providers FARGATE \
    --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
    --region "$REGION" >/dev/null || echo "Cluster already exists"

# Create IAM role for ECS task execution
echo "🔐 Creating ECS task execution role..."
EXECUTION_ROLE_NAME="${SERVICE_NAME}-execution-role"
TASK_ROLE_NAME="${SERVICE_NAME}-task-role"

# Task execution role
EXECUTION_TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}'

aws iam create-role \
    --role-name "$EXECUTION_ROLE_NAME" \
    --assume-role-policy-document "$EXECUTION_TRUST_POLICY" \
    --region "$REGION" 2>/dev/null || echo "Execution role exists"

aws iam attach-role-policy \
    --role-name "$EXECUTION_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" \
    --region "$REGION" 2>/dev/null || echo "Policy already attached"

# Task role (for the container itself)
aws iam create-role \
    --role-name "$TASK_ROLE_NAME" \
    --assume-role-policy-document "$EXECUTION_TRUST_POLICY" \
    --region "$REGION" 2>/dev/null || echo "Task role exists"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
EXECUTION_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$EXECUTION_ROLE_NAME"
TASK_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$TASK_ROLE_NAME"

# Wait for role propagation
sleep 10

# Create task definition
echo "📝 Creating ECS task definition..."
TASK_DEFINITION='{
  "family": "'$TASK_FAMILY'",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "'$EXECUTION_ROLE_ARN'",
  "taskRoleArn": "'$TASK_ROLE_ARN'",
  "containerDefinitions": [
    {
      "name": "'$SERVICE_NAME'",
      "image": "'$IMAGE_URI'",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8000,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "MCP_MODE",
          "value": "http-stream"
        },
        {
          "name": "HOST",
          "value": "0.0.0.0"
        },
        {
          "name": "PORT",
          "value": "8000"
        }
      ],
      "secrets": [
        {
          "name": "GOOGLE_API_KEY",
          "valueFrom": "/google-search-mcp/api-key"
        },
        {
          "name": "GOOGLE_CX",
          "valueFrom": "/google-search-mcp/cx"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/'$SERVICE_NAME'",
          "awslogs-region": "'$REGION'",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": [
          "CMD-SHELL",
          "curl -sf -X OPTIONS -H 'Origin: http://localhost' -H 'Access-Control-Request-Method: POST' http://localhost:8000/messages || exit 1"
        ],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ]
}'

# Create CloudWatch log group
aws logs create-log-group \
    --log-group-name "/ecs/$SERVICE_NAME" \
    --region "$REGION" 2>/dev/null || echo "Log group exists"

echo "$TASK_DEFINITION" > /tmp/task-definition.json
aws ecs register-task-definition \
    --cli-input-json file:///tmp/task-definition.json \
    --region "$REGION" >/dev/null

# Get default VPC and subnets
echo "🌐 Getting VPC configuration..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text --region "$REGION")
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0:2].SubnetId' --output text --region "$REGION" | tr '\t' ',')

# Create security group
echo "🔒 Creating security group..."
SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name "$SERVICE_NAME-sg" \
    --description "Security group for $SERVICE_NAME MCP service" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' \
    --output text 2>/dev/null || aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$SERVICE_NAME-sg" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region "$REGION")

# Add ingress rule for port 8000
aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp \
    --port 8000 \
    --cidr 0.0.0.0/0 \
    --region "$REGION" 2>/dev/null || echo "Ingress rule exists"

# Create ECS service
echo "🚀 Creating ECS service..."
aws ecs create-service \
    --cluster "$CLUSTER_NAME" \
    --service-name "$SERVICE_NAME_ECS" \
    --task-definition "$TASK_FAMILY" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
    --region "$REGION" >/dev/null || echo "Service already exists"

echo "✅ ECS Fargate deployment complete!"
echo
echo "📋 Service Details:"
echo "  Cluster: $CLUSTER_NAME"
echo "  Service: $SERVICE_NAME_ECS"
echo "  Task Definition: $TASK_FAMILY"
echo
echo "🔍 Check service status:"
echo "aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME_ECS --region $REGION"
echo
echo "📝 View logs:"
echo "aws logs tail /ecs/$SERVICE_NAME --follow --region $REGION"
echo
echo "⚠️  Note: Configure secrets in AWS Systems Manager Parameter Store:"
echo "aws ssm put-parameter --name '/google-search-mcp/api-key' --value 'YOUR_API_KEY' --type 'SecureString' --region $REGION"
echo "aws ssm put-parameter --name '/google-search-mcp/cx' --value 'YOUR_CX_ID' --type 'SecureString' --region $REGION"