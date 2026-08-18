<#
====================================================================
 NEXOPS - COMPLETE DEPLOY / APPLY
====================================================================

Run from PROJECT ROOT:

    .\ops\deploy.ps1

Example:

    PS C:\...\enterprise-aws-terraform-infrastructure-2> .\ops\deploy.ps1

PURPOSE
-------
Deploy the complete NEXOPS development environment.

HANDLES
-------
1. Terraform availability
2. AWS CLI availability
3. AWS credentials
4. AWS region
5. AWS API DNS stability
6. Local Terraform process detection
7. Terraform init
8. Terraform validation
9. Terraform planning
10. Terraform apply
11. Stale Terraform LockID detection
12. Safe automatic force-unlock when no local Terraform process exists
13. Route53 hosted-zone discovery
14. Display of exact GoDaddy nameservers
15. Public DNS delegation check
16. ACM certificate status
17. RDS status
18. Secrets Manager status
19. ALB status
20. Auto Scaling Group status
21. EC2 instance status
22. ALB target health
23. Application URL check
24. /api/health check
25. Useful final Terraform outputs

IMPORTANT
---------
This script does NOT:
- create fake database passwords
- overwrite DATABASE_URL
- overwrite DIRECT_URL
- modify GoDaddy
- disable Terraform safety mechanisms
- force-unlock while another Terraform process is running

DATABASE
--------
Your Terraform infrastructure is responsible for creating the
database credentials and Secrets Manager configuration.

The script only verifies that the infrastructure is producing
the expected resources.

DNS
---
This script displays the Route53 nameservers.

You must put those nameservers into GoDaddy for nitesh.shop.

The script cannot modify GoDaddy automatically.

====================================================================
#>

$ErrorActionPreference = "Continue"

# ================================================================
# CONFIGURATION
# ================================================================

$AwsRegion = "us-east-1"

$DomainName = "nitesh.shop"

$MaxRetries = 5

$RetryDelaySeconds = 20

$DnsPasses = 5

$DnsDelaySeconds = 2

$ProjectRoot = Split-Path -Parent $PSScriptRoot

$DevDir = Join-Path $ProjectRoot "environments\dev"

$BootstrapDir = Join-Path $ProjectRoot "bootstrap\state-backend"

$PlanFile = Join-Path $DevDir "tfplan"

$AwsHosts = @(
    "ec2.us-east-1.amazonaws.com",
    "s3.us-east-1.amazonaws.com",
    "rds.us-east-1.amazonaws.com",
    "acm.us-east-1.amazonaws.com",
    "secretsmanager.us-east-1.amazonaws.com",
    "route53.amazonaws.com",
    "sts.amazonaws.com"
)

# ================================================================
# DISPLAY HELPERS
# ================================================================

function Write-Step {

    param(
        [string]$Message
    )

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
}

function Success {

    param(
        [string]$Message
    )

    Write-Host $Message -ForegroundColor Green
}

function Warning {

    param(
        [string]$Message
    )

    Write-Host $Message -ForegroundColor Yellow
}

function Failure {

    param(
        [string]$Message
    )

    Write-Host $Message -ForegroundColor Red
}

function Info {

    param(
        [string]$Message
    )

    Write-Host $Message -ForegroundColor White
}

# ================================================================
# COMMAND CHECK
# ================================================================

function Test-CommandExists {

    param(
        [string]$CommandName
    )

    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {

        Failure ""
        Failure "Required command is not installed:"
        Failure "    $CommandName"
        Failure ""

        return $false
    }

    Success "Found command: $CommandName"

    return $true
}

# ================================================================
# AWS CREDENTIAL CHECK
# ================================================================

function Test-AwsCredentials {

    Write-Step "CHECKING AWS CREDENTIALS"

    $identityOutput = aws sts get-caller-identity 2>&1

    $exitCode = $LASTEXITCODE

    $identityOutput | Write-Host

    if ($exitCode -ne 0) {

        Failure ""
        Failure "AWS credentials are not working."
        Failure ""
        Failure "Check:"
        Failure "    aws configure"
        Failure ""
        Failure "or your AWS environment/profile."
        Failure ""

        return $false
    }

    Success ""
    Success "AWS credentials are valid."

    return $true
}

# ================================================================
# AWS DNS
# ================================================================

function Test-AwsDns {

    Write-Step "CHECKING AWS API DNS"

    for ($pass = 1; $pass -le $DnsPasses; $pass++) {

        Write-Host ""
        Write-Host "DNS stability pass $pass / $DnsPasses" -ForegroundColor Cyan

        foreach ($hostName in $AwsHosts) {

            try {

                Resolve-DnsName `
                    -Name $hostName `
                    -ErrorAction Stop |
                    Out-Null

                Write-Host "  OK  $hostName" -ForegroundColor Green

            }
            catch {

                Failure ""
                Failure "DNS FAILED:"
                Failure "    $hostName"
                Failure ""

                Warning "Try:"
                Warning "    ipconfig /flushdns"
                Warning ""

                return $false
            }
        }

        Start-Sleep -Seconds $DnsDelaySeconds
    }

    Success ""
    Success "AWS API DNS is stable."

    return $true
}

# ================================================================
# LOCAL TERRAFORM PROCESS
# ================================================================

function Test-TerraformProcess {

    $processes = @(Get-Process terraform -ErrorAction SilentlyContinue)

    if ($processes.Count -gt 0) {

        Warning ""
        Warning "Terraform process is already running."

        foreach ($process in $processes) {

            Warning "PID: $($process.Id)"
        }

        return $true
    }

    return $false
}

# ================================================================
# LOCK ID EXTRACTION
# ================================================================

function Get-LockId {

    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {

        return $null
    }

    $patterns = @(
        "ID:\s+([a-fA-F0-9-]{36})",
        "Lock ID[:\s]+([a-fA-F0-9-]{36})",
        "LockID[:\s]+([a-fA-F0-9-]{36})"
    )

    foreach ($pattern in $patterns) {

        $match = [regex]::Match(
            $Text,
            $pattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if ($match.Success) {

            return $match.Groups[1].Value
        }
    }

    return $null
}

# ================================================================
# HANDLE TERRAFORM LOCK
# ================================================================

function Handle-TerraformLock {

    param(
        [string]$OutputText,
        [string]$WorkingDirectory
    )

    $lockId = Get-LockId $OutputText

    if (-not $lockId) {

        return $false
    }

    Write-Host ""
    Warning "============================================================"
    Warning "TERRAFORM STATE LOCK DETECTED"
    Warning "============================================================"
    Warning ""
    Warning "LockID:"
    Warning "    $lockId"
    Warning ""

    # ------------------------------------------------------------
    # NEVER force-unlock if another Terraform process is running.
    # ------------------------------------------------------------

    if (Test-TerraformProcess) {

        Failure ""
        Failure "Another Terraform process is currently running."
        Failure ""
        Failure "Automatic force-unlock has been BLOCKED."
        Failure ""
        Failure "Close the other Terraform process first."
        Failure ""

        return $false
    }

    Warning "No local Terraform process is running."
    Warning "The lock appears stale."
    Warning ""
    Warning "Attempting automatic force-unlock..."

    Push-Location $WorkingDirectory

    try {

        terraform force-unlock -force $lockId

        if ($LASTEXITCODE -eq 0) {

            Success ""
            Success "Terraform state lock successfully removed."
            Success ""

            Start-Sleep -Seconds 5

            return $true
        }

        Failure ""
        Failure "Automatic force-unlock failed."
        Failure ""

        return $false
    }
    finally {

        Pop-Location
    }
}

# ================================================================
# RUN TERRAFORM COMMAND AND CAPTURE OUTPUT
# ================================================================

function Invoke-TerraformCommand {

    param(
        [string]$WorkingDirectory,
        [string[]]$Arguments,
        [string]$Description
    )

    Push-Location $WorkingDirectory

    try {

        Write-Host ""
        Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
        Write-Host $Description -ForegroundColor Cyan
        Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan

        $logFile = Join-Path `
            $env:TEMP `
            "nexops-terraform-$([guid]::NewGuid()).log"

        & terraform @Arguments 2>&1 |
            Tee-Object -FilePath $logFile |
            Write-Host

        $exitCode = $LASTEXITCODE

        $outputText = ""

        if (Test-Path $logFile) {

            $outputText = Get-Content $logFile -Raw
        }

        Remove-Item $logFile -Force -ErrorAction SilentlyContinue

        return [PSCustomObject]@{
            ExitCode = $exitCode
            Output   = $outputText
        }
    }
    finally {

        Pop-Location
    }
}

# ================================================================
# TERRAFORM INIT
# ================================================================

function Initialize-Terraform {

    Write-Step "TERRAFORM INIT"

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {

        Write-Host ""
        Write-Host "terraform init attempt $attempt / $MaxRetries" -ForegroundColor Cyan

        $result = Invoke-TerraformCommand `
            -WorkingDirectory $DevDir `
            -Arguments @(
                "init",
                "-reconfigure"
            ) `
            -Description "terraform init -reconfigure"

        if ($result.ExitCode -eq 0) {

            Success ""
            Success "Terraform initialization successful."

            return $true
        }

        if (Handle-TerraformLock $result.Output $DevDir) {

            continue
        }

        if ($attempt -lt $MaxRetries) {

            Warning ""
            Warning "Terraform init failed."
            Warning "Retrying in $RetryDelaySeconds seconds..."

            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    Failure ""
    Failure "Terraform init failed after $MaxRetries attempts."

    return $false
}

# ================================================================
# TERRAFORM VALIDATE
# ================================================================

function Validate-Terraform {

    Write-Step "TERRAFORM VALIDATE"

    $result = Invoke-TerraformCommand `
        -WorkingDirectory $DevDir `
        -Arguments @(
            "validate"
        ) `
        -Description "terraform validate"

    if ($result.ExitCode -ne 0) {

        Failure ""
        Failure "Terraform configuration validation failed."
        Failure ""
        Failure "This is a Terraform configuration problem."
        Failure "It is NOT safe to solve this by force-unlocking."
        Failure ""

        return $false
    }

    Success ""
    Success "Terraform configuration is valid."

    return $true
}

# ================================================================
# BOOTSTRAP OUTPUT
# ================================================================

function Show-BootstrapInformation {

    Write-Step "CHECKING BOOTSTRAP STATE BACKEND"

    if (-not (Test-Path $BootstrapDir)) {

        Warning "Bootstrap directory not found:"
        Warning "    $BootstrapDir"

        return
    }

    Push-Location $BootstrapDir

    try {

        terraform init -reconfigure 2>&1 | Out-Null

        if ($LASTEXITCODE -ne 0) {

            Warning "Bootstrap Terraform initialization failed."
            return
        }

        $bucket = terraform output -raw state_bucket_name 2>$null

        if ($LASTEXITCODE -eq 0 -and
            -not [string]::IsNullOrWhiteSpace($bucket)) {

            Success "Terraform state bucket:"
            Info "    $($bucket.Trim())"
        }

        $lockTable = terraform output -raw dynamodb_table_name 2>$null

        if ($LASTEXITCODE -eq 0 -and
            -not [string]::IsNullOrWhiteSpace($lockTable)) {

            Success "Terraform lock table:"
            Info "    $($lockTable.Trim())"
        }
    }
    finally {

        Pop-Location
    }
}

# ================================================================
# ROUTE53 HOSTED ZONE
# ================================================================

function Get-Route53Zone {

    Write-Step "CHECKING ROUTE53 HOSTED ZONE"

    $zoneJson = aws route53 list-hosted-zones-by-name `
        --dns-name "$DomainName." `
        --region $AwsRegion `
        --output json 2>$null

    if ($LASTEXITCODE -ne 0) {

        Failure "Unable to query Route53."

        return $null
    }

    try {

        $data = $zoneJson | ConvertFrom-Json
    }
    catch {

        Failure "Unable to parse Route53 response."

        return $null
    }

    if ($null -eq $data.HostedZones) {

        Failure "No Route53 hosted zone response."

        return $null
    }

    foreach ($zone in @($data.HostedZones)) {

        $zoneName = $zone.Name.TrimEnd(".")

        if ($zoneName -eq $DomainName) {

            $zoneId = $zone.Id -replace "^/hostedzone/", ""

            Success ""
            Success "Route53 hosted zone found:"
            Info "    Domain : $zoneName"
            Info "    Zone ID: $zoneId"

            return $zoneId
        }
    }

    Warning ""
    Warning "Route53 hosted zone for $DomainName was not found."

    return $null
}

# ================================================================
# SHOW NAMESERVERS
# ================================================================

function Show-Nameservers {

    param(
        [string]$ZoneId
    )

    if ([string]::IsNullOrWhiteSpace($ZoneId)) {

        return $false
    }

    Write-Step "ROUTE53 NAMESERVERS FOR GODADDY"

    $delegationJson = aws route53 get-hosted-zone `
        --id $ZoneId `
        --region $AwsRegion `
        --output json 2>$null

    if ($LASTEXITCODE -ne 0) {

        Failure "Unable to retrieve Route53 nameservers."

        return $false
    }

    try {

        $delegation = $delegationJson | ConvertFrom-Json
    }
    catch {

        Failure "Unable to parse Route53 nameserver response."

        return $false
    }

    $nameservers = @(
        $delegation.DelegationSet.NameServers
    )

    if ($nameservers.Count -eq 0) {

        Failure "Route53 returned no nameservers."

        return $false
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "UPDATE THESE NAMESERVERS IN GODADDY" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""

    $counter = 1

    foreach ($ns in $nameservers) {

        Write-Host "    Nameserver $counter : $ns" -ForegroundColor White

        $counter++
    }

    Write-Host ""

    Warning "GoDaddy domain:"
    Info "    $DomainName"

    Write-Host ""

    Warning "At GoDaddy:"
    Info "    Domain → DNS / Nameservers"
    Info "    Choose custom nameservers"
    Info "    Replace the existing nameservers"
    Info "    Enter the four nameservers above"
    Info "    Save"

    Write-Host ""

    return $true
}

# ================================================================
# CHECK PUBLIC DNS DELEGATION
# ================================================================

function Test-PublicDomainDns {

    Write-Step "CHECKING PUBLIC DNS DELEGATION"

    try {

        $nsRecords = Resolve-DnsName `
            -Name $DomainName `
            -Type NS `
            -Server "8.8.8.8" `
            -ErrorAction Stop
    }
    catch {

        Warning ""
        Warning "Public DNS does not currently return NS records for:"
        Warning "    $DomainName"
        Warning ""
        Warning "This usually means the GoDaddy nameserver delegation"
        Warning "has not propagated yet."
        Warning ""

        return $false
    }

    $records = @(
        $nsRecords |
        Where-Object {
            $_.Type -eq "NS"
        }
    )

    if ($records.Count -eq 0) {

        Warning "No public NS records were returned."

        return $false
    }

    Success "Public DNS is returning NS records."

    foreach ($record in $records) {

        Info "    $($record.NameHost)"
    }

    return $true
}

# ================================================================
# CHECK ROUTE53 + DOMAIN
# ================================================================

function Check-DnsBeforeApply {

    $zoneId = Get-Route53Zone

    if ($null -eq $zoneId) {

        Warning ""
        Warning "The Route53 hosted zone does not exist yet."
        Warning "Terraform may create it during apply."
        Warning ""

        return $true
    }

    Show-Nameservers $zoneId | Out-Null

    Write-Host ""

    if (-not (Test-PublicDomainDns)) {

        Warning ""
        Warning "IMPORTANT:"
        Warning "Public delegation for $DomainName is not confirmed yet."
        Warning ""
        Warning "Terraform can still create the infrastructure,"
        Warning "but ACM/domain HTTPS validation may not complete"
        Warning "until the GoDaddy nameservers are updated."
        Warning ""
    }

    return $true
}

# ================================================================
# TERRAFORM PLAN
# ================================================================

function Create-TerraformPlan {

    Write-Step "TERRAFORM PLAN"

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {

        Write-Host ""
        Write-Host "terraform plan attempt $attempt / $MaxRetries" -ForegroundColor Cyan

        if (Test-Path $PlanFile) {

            Remove-Item $PlanFile -Force -ErrorAction SilentlyContinue
        }

        $result = Invoke-TerraformCommand `
            -WorkingDirectory $DevDir `
            -Arguments @(
                "plan",
                "-out=$PlanFile"
            ) `
            -Description "terraform plan"

        if ($result.ExitCode -eq 0) {

            Success ""
            Success "Terraform plan completed successfully."

            return $true
        }

        if (Handle-TerraformLock $result.Output $DevDir) {

            continue
        }

        Warning ""

        if ($result.Output -match "Could not resolve host" -or
            $result.Output -match "no such host" -or
            $result.Output -match "network" -or
            $result.Output -match "timeout" -or
            $result.Output -match "connection") {

            Warning "A network/transient error was detected."
        }

        if ($attempt -lt $MaxRetries) {

            Warning "Waiting $RetryDelaySeconds seconds before retry..."

            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    Failure ""
    Failure "Terraform plan failed."

    return $false
}

# ================================================================
# TERRAFORM APPLY
# ================================================================

function Apply-TerraformPlan {

    Write-Step "TERRAFORM APPLY"

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {

        Write-Host ""
        Write-Host "terraform apply attempt $attempt / $MaxRetries" -ForegroundColor Cyan

        if (-not (Test-Path $PlanFile)) {

            Failure "Terraform plan file does not exist."

            return $false
        }

        $result = Invoke-TerraformCommand `
            -WorkingDirectory $DevDir `
            -Arguments @(
                "apply",
                $PlanFile
            ) `
            -Description "terraform apply"

        if ($result.ExitCode -eq 0) {

            Success ""
            Success "Terraform apply completed successfully."

            return $true
        }

        if (Handle-TerraformLock $result.Output $DevDir) {

            # ----------------------------------------------------
            # A saved plan can become invalid after state changes.
            # Re-create the plan instead of blindly reusing it.
            # ----------------------------------------------------

            Warning ""
            Warning "Lock was cleared."
            Warning "The Terraform plan will be recreated."

            if (-not (Create-TerraformPlan)) {

                return $false
            }

            continue
        }

        Warning ""

        if ($result.Output -match "Could not resolve host" -or
            $result.Output -match "no such host" -or
            $result.Output -match "timeout" -or
            $result.Output -match "connection reset" -or
            $result.Output -match "connection refused" -or
            $result.Output -match "InternalError" -or
            $result.Output -match "RequestLimitExceeded") {

            Warning "A transient AWS/network error appears to have occurred."
        }
        else {

            Warning "Terraform apply failed."
            Warning ""
            Warning "The failure may be a real configuration/resource error."
        }

        if ($attempt -lt $MaxRetries) {

            Warning ""
            Warning "Waiting $RetryDelaySeconds seconds before retry..."

            Start-Sleep -Seconds $RetryDelaySeconds

            # Recreate plan before retry.
            if (-not (Create-TerraformPlan)) {

                return $false
            }
        }
    }

    Failure ""
    Failure "Terraform apply failed after $MaxRetries attempts."

    return $false
}

# ================================================================
# TERRAFORM OUTPUTS
# ================================================================

function Show-TerraformOutputs {

    Write-Step "TERRAFORM OUTPUTS"

    Push-Location $DevDir

    try {

        terraform output

        if ($LASTEXITCODE -ne 0) {

            Warning "Terraform outputs could not be read."
        }
    }
    finally {

        Pop-Location
    }
}

# ================================================================
# RDS CHECK
# ================================================================

function Test-Rds {

    Write-Step "CHECKING RDS"

    $instances = aws rds describe-db-instances `
        --region $AwsRegion `
        --query "DBInstances[?contains(DBInstanceIdentifier, 'nexops')].[DBInstanceIdentifier,DBInstanceStatus,Endpoint.Address,Endpoint.Port]" `
        --output text 2>$null

    if ($LASTEXITCODE -ne 0) {

        Warning "Unable to query RDS."

        return $false
    }

    if ([string]::IsNullOrWhiteSpace($instances)) {

        Warning "No nexops RDS instance was found yet."

        return $false
    }

    Write-Host $instances

    $available = $false

    foreach ($line in ($instances -split "`r?`n")) {

        if ($line -match "available") {

            $available = $true
        }
    }

    if ($available) {

        Success "RDS is AVAILABLE."

        return $true
    }

    Warning "RDS exists but is not yet AVAILABLE."

    return $false
}

# ================================================================
# SECRETS MANAGER CHECK
# ================================================================

function Test-SecretsManager {

    Write-Step "CHECKING SECRETS MANAGER"

    $secrets = aws secretsmanager list-secrets `
        --region $AwsRegion `
        --query "SecretList[?contains(Name, 'nexops')].Name" `
        --output text 2>$null

    if ($LASTEXITCODE -ne 0) {

        Warning "Unable to query Secrets Manager."

        return $false
    }

    if ([string]::IsNullOrWhiteSpace($secrets)) {

        Warning "No nexops Secrets Manager secret was found."

        return $false
    }

    Success "NexOps Secrets Manager secret(s) found."

    foreach ($secret in ($secrets -split "`t")) {

        if (-not [string]::IsNullOrWhiteSpace($secret)) {

            Info "    $secret"
        }
    }

    return $true
}

# ================================================================
# ALB CHECK
# ================================================================

function Test-LoadBalancer {

    Write-Step "CHECKING APPLICATION LOAD BALANCER"

    $alb = aws elbv2 describe-load-balancers `
        --region $AwsRegion `
        --query "LoadBalancers[?contains(LoadBalancerName, 'nexops')].[LoadBalancerName,State.Code,DNSName]" `
        --output text 2>$null

    if ($LASTEXITCODE -ne 0) {

        Warning "Unable to query ALB."

        return $false
    }

    if ([string]::IsNullOrWhiteSpace($alb)) {

        Warning "NexOps ALB was not found."

        return $false
    }

    Write-Host $alb

    if ($alb -match "active") {

        Success "ALB is ACTIVE."

        return $true
    }

    Warning "ALB exists but is not active."

    return $false
}

# ================================================================
# ASG CHECK
# ================================================================

function Test-AutoScaling {

    Write-Step "CHECKING AUTO SCALING GROUP"

    $asg = aws autoscaling describe-auto-scaling-groups `
        --region $AwsRegion `
        --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'nexops')].[AutoScalingGroupName,DesiredCapacity,MinSize,MaxSize,Instances[].LifecycleState]" `
        --output text 2>$null

    if ($LASTEXITCODE -ne 0) {

        Warning "Unable to query Auto Scaling."

        return $false
    }

    if ([string]::IsNullOrWhiteSpace($asg)) {

        Warning "NexOps Auto Scaling Group was not found."

        return $false
    }

    Write-Host $asg

    Success "Auto Scaling Group found."

    return $true
}

# ================================================================
# TARGET HEALTH
# ================================================================

function Test-TargetHealth {

    Write-Step "CHECKING ALB TARGET HEALTH"

    $targetGroups = aws elbv2 describe-target-groups `
        --region $AwsRegion `
        --query "TargetGroups[?contains(TargetGroupName, 'nexops')].[TargetGroupArn,TargetGroupName]" `
        --output text 2>$null

    if ($LASTEXITCODE -ne 0) {

        Warning "Unable to query target groups."

        return $false
    }

    if ([string]::IsNullOrWhiteSpace($targetGroups)) {

        Warning "No NexOps target group found."

        return $false
    }

    $healthy = $false

    foreach ($line in ($targetGroups -split "`r?`n")) {

        if ([string]::IsNullOrWhiteSpace($line)) {

            continue
        }

        $parts = $line -split "`t"

        if ($parts.Count -lt 1) {

            continue
        }

        $arn = $parts[0]

        $health = aws elbv2 describe-target-health `
            --target-group-arn $arn `
            --region $AwsRegion `
            --query "TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]" `
            --output text 2>$null

        if ($LASTEXITCODE -eq 0) {

            Write-Host $health

            if ($health -match "healthy") {

                $healthy = $true
            }
        }
    }

    if ($healthy) {

        Success "At least one ALB target is HEALTHY."

        return $true
    }

    Warning "No healthy ALB target was confirmed yet."

    return $false
}

# ================================================================
# PUBLIC APPLICATION URL
# ================================================================

function Test-ApplicationUrl {

    Write-Step "CHECKING APPLICATION URL"

    $url = "https://$DomainName"

    try {

        $response = Invoke-WebRequest `
            -Uri $url `
            -Method Get `
            -UseBasicParsing `
            -TimeoutSec 20 `
            -ErrorAction Stop

        Success ""
        Success "HTTPS application is reachable."
        Info "    URL    : $url"
        Info "    Status : $($response.StatusCode)"

        return $true
    }
    catch {

        Warning ""
        Warning "HTTPS application is not reachable yet."
        Warning "    $url"
        Warning ""
        Warning "This can be normal immediately after infrastructure creation."
        Warning "ACM, DNS, ALB and EC2 bootstrap may still be converging."

        return $false
    }
}

# ================================================================
# API HEALTH
# ================================================================

function Test-ApiHealth {

    Write-Step "CHECKING API HEALTH"

    $urls = @(
        "https://$DomainName/api/health"
    )

    foreach ($url in $urls) {

        try {

            $response = Invoke-WebRequest `
                -Uri $url `
                -Method Get `
                -UseBasicParsing `
                -TimeoutSec 20 `
                -ErrorAction Stop

            Success ""
            Success "API health endpoint responded."
            Info "    URL    : $url"
            Info "    Status : $($response.StatusCode)"

            return $true
        }
        catch {

            Warning "API health endpoint is not responding yet:"
            Warning "    $url"
        }
    }

    return $false
}

# ================================================================
# FINAL HEALTH REPORT
# ================================================================

function Show-FinalHealthReport {

    Write-Step "FINAL NEXOPS DEPLOYMENT REPORT"

    Write-Host ""
    Write-Host "Project:" -ForegroundColor Gray
    Write-Host "    $ProjectRoot" -ForegroundColor White

    Write-Host ""
    Write-Host "AWS Region:" -ForegroundColor Gray
    Write-Host "    $AwsRegion" -ForegroundColor White

    Write-Host ""
    Write-Host "Domain:" -ForegroundColor Gray
    Write-Host "    https://$DomainName" -ForegroundColor White

    Write-Host ""

    Write-Host "Terraform:" -ForegroundColor Green
    Write-Host "    APPLY COMPLETED" -ForegroundColor White

    Write-Host ""

    Show-TerraformOutputs

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "DEPLOYMENT COMMAND FINISHED" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
}

# ================================================================
# MAIN
# ================================================================

Clear-Host

Write-Host ""
Write-Host "################################################################" -ForegroundColor Green
Write-Host "#                                                              #" -ForegroundColor Green
Write-Host "#              NEXOPS COMPLETE AWS DEPLOY                     #" -ForegroundColor Green
Write-Host "#                                                              #" -ForegroundColor Green
Write-Host "################################################################" -ForegroundColor Green
Write-Host ""

Write-Host "Project root:" -ForegroundColor Gray
Write-Host "    $ProjectRoot" -ForegroundColor White

Write-Host ""

Write-Host "Environment:" -ForegroundColor Gray
Write-Host "    $DevDir" -ForegroundColor White

Write-Host ""

Write-Host "AWS Region:" -ForegroundColor Gray
Write-Host "    $AwsRegion" -ForegroundColor White

Write-Host ""

Write-Host "Domain:" -ForegroundColor Gray
Write-Host "    $DomainName" -ForegroundColor White

# ================================================================
# REQUIRED COMMANDS
# ================================================================

if (-not (Test-CommandExists "terraform")) {

    exit 1
}

if (-not (Test-CommandExists "aws")) {

    exit 1
}

# ================================================================
# DIRECTORY CHECK
# ================================================================

if (-not (Test-Path $DevDir)) {

    Failure ""
    Failure "Terraform environment directory does not exist:"
    Failure "    $DevDir"
    Failure ""

    exit 1
}

# ================================================================
# PREVENT MULTIPLE TERRAFORM PROCESSES
# ================================================================

if (Test-TerraformProcess) {

    Failure ""
    Failure "Terraform is already running."
    Failure ""
    Failure "Close the other Terraform process before starting deploy."
    Failure ""

    exit 1
}

# ================================================================
# AWS CREDENTIALS
# ================================================================

if (-not (Test-AwsCredentials)) {

    exit 1
}

# ================================================================
# AWS DNS
# ================================================================

if (-not (Test-AwsDns)) {

    exit 1
}

# ================================================================
# BOOTSTRAP INFORMATION
# ================================================================

Show-BootstrapInformation

# ================================================================
# DNS / GODADDY INFORMATION
# ================================================================

Check-DnsBeforeApply

# ================================================================
# TERRAFORM INIT
# ================================================================

if (-not (Initialize-Terraform)) {

    exit 1
}

# ================================================================
# TERRAFORM VALIDATE
# ================================================================

if (-not (Validate-Terraform)) {

    exit 1
}

# ================================================================
# FINAL PRE-APPLY DISPLAY
# ================================================================

Write-Step "PRE-APPLY SUMMARY"

Write-Host ""
Write-Host "Terraform environment:" -ForegroundColor Gray
Write-Host "    $DevDir" -ForegroundColor White

Write-Host ""
Write-Host "Domain:" -ForegroundColor Gray
Write-Host "    $DomainName" -ForegroundColor White

Write-Host ""
Write-Host "AWS Region:" -ForegroundColor Gray
Write-Host "    $AwsRegion" -ForegroundColor White

Write-Host ""

Warning "Terraform will now create/update AWS infrastructure."

Write-Host ""

$confirmation = Read-Host "Type APPLY to continue"

if ($confirmation -ne "APPLY") {

    Warning ""
    Warning "Deployment cancelled."

    exit 0
}

# ================================================================
# PLAN
# ================================================================

if (-not (Create-TerraformPlan)) {

    exit 1
}

# ================================================================
# APPLY
# ================================================================

if (-not (Apply-TerraformPlan)) {

    exit 1
}

# ================================================================
# POST APPLY WAIT
# ================================================================

Write-Step "WAITING FOR AWS RESOURCES TO CONVERGE"

Write-Host ""
Write-Host "Waiting 20 seconds before health checks..." -ForegroundColor Yellow

Start-Sleep -Seconds 20

# ================================================================
# POST APPLY CHECKS
# ================================================================

$rdsOk = Test-Rds

$secretOk = Test-SecretsManager

$albOk = Test-LoadBalancer

$asgOk = Test-AutoScaling

$targetOk = Test-TargetHealth

# ================================================================
# SHOW CURRENT NAMESERVERS AGAIN
# ================================================================

$zoneId = Get-Route53Zone

if ($null -ne $zoneId) {

    Show-Nameservers $zoneId | Out-Null

    Write-Host ""

    Test-PublicDomainDns | Out-Null
}

# ================================================================
# APPLICATION CHECKS
# ================================================================

$appOk = Test-ApplicationUrl

$apiOk = Test-ApiHealth

# ================================================================
# FINAL REPORT
# ================================================================

Write-Step "DEPLOYMENT RESULT"

Write-Host ""

Write-Host "Terraform apply        : " -NoNewline

if ($true) {
    Write-Host "SUCCESS" -ForegroundColor Green
}

Write-Host "RDS                    : " -NoNewline

if ($rdsOk) {
    Write-Host "AVAILABLE" -ForegroundColor Green
}
else {
    Write-Host "NOT CONFIRMED" -ForegroundColor Yellow
}

Write-Host "Secrets Manager        : " -NoNewline

if ($secretOk) {
    Write-Host "FOUND" -ForegroundColor Green
}
else {
    Write-Host "NOT CONFIRMED" -ForegroundColor Yellow
}

Write-Host "ALB                    : " -NoNewline

if ($albOk) {
    Write-Host "ACTIVE" -ForegroundColor Green
}
else {
    Write-Host "NOT CONFIRMED" -ForegroundColor Yellow
}

Write-Host "Auto Scaling           : " -NoNewline

if ($asgOk) {
    Write-Host "FOUND" -ForegroundColor Green
}
else {
    Write-Host "NOT CONFIRMED" -ForegroundColor Yellow
}

Write-Host "ALB target health      : " -NoNewline

if ($targetOk) {
    Write-Host "HEALTHY" -ForegroundColor Green
}
else {
    Write-Host "NOT HEALTHY YET" -ForegroundColor Yellow
}

Write-Host "HTTPS application      : " -NoNewline

if ($appOk) {
    Write-Host "REACHABLE" -ForegroundColor Green
}
else {
    Write-Host "NOT REACHABLE YET" -ForegroundColor Yellow
}

Write-Host "API /api/health        : " -NoNewline

if ($apiOk) {
    Write-Host "HEALTHY" -ForegroundColor Green
}
else {
    Write-Host "NOT HEALTHY YET" -ForegroundColor Yellow
}

Write-Host ""

# ================================================================
# FINAL OUTPUT
# ================================================================

Show-FinalHealthReport

Write-Host ""

if ($apiOk -and $targetOk) {

    Write-Host "################################################################" -ForegroundColor Green
    Write-Host "#                                                              #" -ForegroundColor Green
    Write-Host "#             NEXOPS DEPLOYMENT HEALTHY                       #" -ForegroundColor Green
    Write-Host "#                                                              #" -ForegroundColor Green
    Write-Host "################################################################" -ForegroundColor Green

}
else {

    Write-Host "################################################################" -ForegroundColor Yellow
    Write-Host "#                                                              #" -ForegroundColor Yellow
    Write-Host "#       INFRASTRUCTURE APPLIED - HEALTH CHECK INCOMPLETE       #" -ForegroundColor Yellow
    Write-Host "#                                                              #" -ForegroundColor Yellow
    Write-Host "################################################################" -ForegroundColor Yellow

    Write-Host ""
    Warning "Terraform successfully applied, but one or more application"
    Warning "health checks are not confirmed yet."
    Warning ""
    Warning "Do NOT immediately destroy everything."
    Warning "Check the specific failed health check above."
}

Write-Host ""