# ==============================================================================
# SCRIPT 2: 2-deploy-new.ps1
# Purpose: Clean fresh deployment of the entire NexOps infrastructure
# ==============================================================================

$ErrorActionPreference = "Stop"
$Region = "us-east-1"
$Prefix = "nexops-dev"

Write-Host "`n[1/3] Initializing Terraform..." -ForegroundColor Cyan
terraform init -reconfigure

Write-Host "`n[2/3] Deploying Infrastructure (this takes ~10 mins for RDS & ALB)..." -ForegroundColor Cyan
terraform apply -auto-approve

Write-Host "`n[3/3] Deployment Complete! Fetching Direct Access URLs..." -ForegroundColor Green
terraform output

$albDns = aws elbv2 describe-load-balancers --region $Region --query "LoadBalancers[?contains(LoadBalancerName, '$Prefix')].DNSName" --output text
if ($albDns -and $albDns -ne "None") {
    Write-Host "`n========================================================" -ForegroundColor Green
    Write-Host " APPLICATION LIVE URL : http://$albDns" -ForegroundColor Yellow
    Write-Host " HEALTH CHECK URL     : http://$albDns/api/health" -ForegroundColor Yellow
    Write-Host "========================================================" -ForegroundColor Green
}
