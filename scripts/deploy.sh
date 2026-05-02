#!/bin/bash
set -e

ENVIRONMENT=${1:-dev}
PROJECT_NAME=${2:-twin}

echo "🚀 Deploying $PROJECT_NAME to $ENVIRONMENT ..."

# Move to project root
cd "$(dirname "$0")/.."

# ─────────────────────────────────────────
# 1. Build Lambda package
# ─────────────────────────────────────────
echo "📦 Building Lambda package..."
cd backend
uv run deploy.py
cd ..

# ─────────────────────────────────────────
# 2. Terraform init, workspace & apply
# ─────────────────────────────────────────
cd terraform

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}

echo "🔧 Initializing Terraform backend..."
terraform init -input=false \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true" \
  -reconfigure

# Create or select workspace
if terraform workspace list | grep -q "$ENVIRONMENT"; then
  terraform workspace select "$ENVIRONMENT"
else
  terraform workspace new "$ENVIRONMENT"
fi

echo "🏗️ Applying Terraform..."
if [ "$ENVIRONMENT" = "prod" ]; then
  terraform apply \
    -var-file=prod.tfvars \
    -var="project_name=$PROJECT_NAME" \
    -var="environment=$ENVIRONMENT" \
    -auto-approve
else
  terraform apply \
    -var="project_name=$PROJECT_NAME" \
    -var="environment=$ENVIRONMENT" \
    -auto-approve
fi

API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)
CUSTOM_URL=$(terraform output -raw custom_domain_url 2>/dev/null || echo "")

cd ..

# ─────────────────────────────────────────
# 3. Build + deploy frontend
# ──────────────────────