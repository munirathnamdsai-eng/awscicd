param(
    [string]$Environment = "dev",
    [string]$ProjectName = "twin"
)
$ErrorActionPreference = "Stop"

Write-Host "Deploying $ProjectName to $Environment ..." -ForegroundColor Green

# Move to project root
Set-Location (Split-Path $PSScriptRoot -Parent)

# 1. Build Lambda package
Write-Host "Building Lambda package..." -ForegroundColor Yellow
Set-Location backend
uv run deploy.py
Set-Location ..

# 2. Terraform init, workspace & apply
Set-Location terraform

$awsAccountId = aws sts get-caller-identity --query Account --output text
$awsRegion = if ($env:DEFAULT_AWS_REGION) { $env:DEFAULT_AWS_REGION } else { "us-east-1" }

# ✅ Use TF_STATE_BUCKET secret if available
$tfStateBucket = if ($env:TF_STATE_BUCKET) { $env:TF_STATE_BUCKET } else { "twin-terraform-state-$awsAccountId" }

Write-Host "Initializing Terraform backend..." -ForegroundColor Yellow
terraform init -input=false `
  -backend-config="bucket=$tfStateBucket" `
  -backend-config="key=$Environment/terraform.tfstate" `
  -backend-config="region=$awsRegion" `
  -backend-config="encrypt=true" `
  -reconfigure

# ✅ Create workspace if not exists
$workspaces = terraform workspace list
if ($workspaces | Select-String $Environment) {
    Write-Host "Selecting workspace: $Environment" -ForegroundColor Yellow
    terraform workspace select $Environment
} else {
    Write-Host "Creating new workspace: $Environment" -ForegroundColor Yellow
    terraform workspace new $Environment
}

Write-Host "Applying Terraform..." -ForegroundColor Yellow
if ($Environment -eq "prod" -and (Test-Path "prod.tfvars")) {
    terraform apply -var-file=prod.tfvars `
                   -var="project_name=$ProjectName" `
                   -var="environment=$Environment" `
                   -auto-approve
} else {
    terraform apply -var="project_name=$ProjectName" `
                   -var="environment=$Environment" `
                   -auto-approve
}

$ApiUrl         = terraform output -raw api_gateway_url
$FrontendBucket = terraform output -raw s3_frontend_bucket
try { $CustomUrl = terraform output -raw custom_domain_url } catch { $CustomUrl = "" }

# 3. Build + deploy frontend
Set-Location ..\frontend

Write-Host "Setting API URL..." -ForegroundColor Yellow
"NEXT_PUBLIC_API_URL=$ApiUrl" | Out-File .env.production -Encoding utf8

npm install
npm run build

Write-Host "Uploading frontend to S3..." -ForegroundColor Yellow
aws s3 sync .\out "s3://$FrontendBucket/" --delete
Set-Location ..

# 4. Final summary
$CfUrl = terraform -chdir=terraform output -raw cloudfront_url
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "CloudFront URL : $CfUrl" -ForegroundColor Cyan
if ($CustomUrl) {
    Write-Host "Custom domain  : $CustomUrl" -ForegroundColor Cyan
}
Write-Host "API Gateway    : $ApiUrl" -ForegroundColor Cyan