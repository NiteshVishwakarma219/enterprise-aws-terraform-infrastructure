<#
  One-click destroy.
  Run from PowerShell:  .\ops\destroy.ps1

  Same DNS preflight + auto-retry + auto-unlock approach as deploy.ps1.
  terraform destroy is safe to re-run - it only removes what's still there.
#>

$ErrorActionPreference = "Continue"
$maxRetries = 4
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
                Write-Host "DNS FAILED resolving $h on pass $pass. Fix your network before destroying." -ForegroundColor Red
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

Write-Host "This will destroy every resource this project manages in AWS." -ForegroundColor Yellow
$confirm = Read-Host "Type DESTROY to continue"
if ($confirm -ne "DESTROY") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
}

Push-Location "$PSScriptRoot\..\environments\dev"

try {
    terraform init -reconfigure
    if ($LASTEXITCODE -ne 0) { throw "terraform init failed" }

    $attempt = 0
    $destroyed = $false

    while (-not $destroyed -and $attempt -lt $maxRetries) {
        $attempt++
        Write-Host "`n=== terraform destroy (attempt $attempt of $maxRetries) ===" -ForegroundColor Cyan
        $destroyOutput = terraform destroy -auto-approve 2>&1 | Tee-Object -Variable destroyOutput
        $destroyOutput | Write-Host

        if ($LASTEXITCODE -eq 0) {
            $destroyed = $true
        } else {
            $lockId = Get-StuckLockId ($destroyOutput -join "`n")
            if ($lockId) {
                Write-Host "Stuck state lock detected ($lockId). Clearing and retrying..." -ForegroundColor Yellow
                terraform force-unlock -force $lockId
            } else {
                Write-Host "Destroy failed partway. This is safe to retry." -ForegroundColor Yellow
                Write-Host "Waiting 20s before retry $($attempt+1) of $maxRetries..." -ForegroundColor Yellow
                Start-Sleep -Seconds 20
            }
        }
    }

    $remaining = terraform state list
    if ($destroyed -and [string]::IsNullOrWhiteSpace($remaining)) {
        Write-Host "`n=== DESTROY COMPLETE - state is empty ===" -ForegroundColor Green
    } else {
        Write-Host "`n=== DESTROY DID NOT FULLY COMPLETE ===" -ForegroundColor Red
        Write-Host "Resources still tracked in state:" -ForegroundColor Red
        Write-Host $remaining
        Write-Host "Share the last error above rather than re-running blindly." -ForegroundColor Red
        exit 1
    }
} finally {
    Pop-Location
}
