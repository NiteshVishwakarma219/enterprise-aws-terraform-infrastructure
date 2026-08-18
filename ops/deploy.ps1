<#
  One-click deploy.
  Run from PowerShell:  .\ops\deploy.ps1
  (Right-click -> Run with PowerShell also works if double-clicking.)

  What it does:
    1. Verifies DNS to the AWS hostnames this project needs, 5 times in a
       row, before touching Terraform at all. Refuses to start if flaky.
    2. Runs init/validate/plan/apply for environments\dev.
    3. If apply fails on a transient error, retries automatically up to
       3 times (terraform apply is safe to re-run - it only creates what
       is still missing).
    4. If a stale state lock is the failure reason and no other terraform
       process is running on this machine, clears it automatically before
       retrying.
#>

$ErrorActionPreference = "Continue"
$maxRetries = 3
$hosts = @(
  "ec2.us-east-1.amazonaws.com",
  "s3.us-east-1.amazonaws.com",
  "rds.us-east-1.amazonaws.com",
  "acm.us-east-1.amazonaws.com",
  "secretsmanager.us-east-1.amazonaws.com",
  "route53.amazonaws.com"
)

function Test-DnsStable {
    Write-Host "Checking DNS stability (5 passes)..." -ForegroundColor Cyan
    for ($pass = 1; $pass -le 5; $pass++) {
        foreach ($h in $hosts) {
            try {
                Resolve-DnsName -Name $h -ErrorAction Stop | Out-Null
            } catch {
                Write-Host "DNS FAILED resolving $h on pass $pass. Fix your network before deploying." -ForegroundColor Red
                Write-Host "Run: ipconfig /flushdns   then retry this script." -ForegroundColor Yellow
                return $false
            }
        }
        Start-Sleep -Seconds 1
    }
    Write-Host "DNS looks stable." -ForegroundColor Green
    return $true
}

function Get-StuckLockId([string]$errorText) {
    if ($errorText -match "ID:\s+([a-f0-9-]{36})") {
        return $matches[1]
    }
    return $null
}

if (-not (Test-DnsStable)) {
    exit 1
}

Push-Location "$PSScriptRoot\..\environments\dev"

try {
    terraform init -reconfigure
    if ($LASTEXITCODE -ne 0) { throw "terraform init failed" }

    terraform validate
    if ($LASTEXITCODE -ne 0) { throw "terraform validate failed - fix the config error shown above, this is not a network issue" }

    $attempt = 0
    $applied = $false

    while (-not $applied -and $attempt -lt $maxRetries) {
        $attempt++
        Write-Host "`n=== terraform plan (attempt $attempt of $maxRetries) ===" -ForegroundColor Cyan
        $planOutput = terraform plan -out=tfplan 2>&1 | Tee-Object -Variable planOutput
        $planOutput | Write-Host

        if ($LASTEXITCODE -ne 0) {
            $lockId = Get-StuckLockId ($planOutput -join "`n")
            if ($lockId) {
                Write-Host "Stuck state lock detected ($lockId). Clearing and retrying..." -ForegroundColor Yellow
                terraform force-unlock -force $lockId
                continue
            } else {
                Write-Host "Plan failed for a non-lock reason. Waiting 15s and retrying..." -ForegroundColor Yellow
                Start-Sleep -Seconds 15
                continue
            }
        }

        Write-Host "`n=== terraform apply (attempt $attempt of $maxRetries) ===" -ForegroundColor Cyan
        $applyOutput = terraform apply tfplan 2>&1 | Tee-Object -Variable applyOutput
        $applyOutput | Write-Host

        if ($LASTEXITCODE -eq 0) {
            $applied = $true
        } else {
            $lockId = Get-StuckLockId ($applyOutput -join "`n")
            if ($lockId) {
                Write-Host "Stuck state lock detected during apply ($lockId). Clearing and retrying..." -ForegroundColor Yellow
                terraform force-unlock -force $lockId
            } else {
                Write-Host "Apply failed. This is safe to retry - terraform only creates what's missing." -ForegroundColor Yellow
                Write-Host "Waiting 20s before retry $($attempt+1) of $maxRetries..." -ForegroundColor Yellow
                Start-Sleep -Seconds 20
            }
        }
    }

    if ($applied) {
        Write-Host "`n=== DEPLOY COMPLETE ===" -ForegroundColor Green
        terraform output
    } else {
        Write-Host "`n=== DEPLOY DID NOT COMPLETE after $maxRetries attempts ===" -ForegroundColor Red
        Write-Host "Copy the last error above and share it - do not keep re-running blindly." -ForegroundColor Red
        exit 1
    }
} finally {
    Pop-Location
}
