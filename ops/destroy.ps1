<#
=======================================================================
 NEXOPS ENTERPRISE AWS
 COMPLETE ONE-CLICK DESTROY SCRIPT
=======================================================================

FILE:
    ops\destroy.ps1

RUN:
    .\ops\destroy.ps1

PURPOSE:
    Completely destroy the AWS infrastructure managed by this project.

DESTROY ORDER:

    1. environments\dev
    2. Terraform state S3 bucket cleanup
    3. bootstrap\state-backend
    4. final AWS/Terraform verification

HANDLES:

    - AWS credentials
    - AWS CLI availability
    - Terraform availability
    - DNS/network preflight
    - stale Terraform LockID
    - local Terraform process protection
    - Terraform retries
    - S3 versioned objects
    - S3 delete markers
    - BucketNotEmpty
    - more than 1000 S3 versions
    - S3 cleanup retry
    - prevent_destroy on Terraform state bucket
    - manual state bucket deletion when required
    - terraform state rm after manual bucket deletion
    - bootstrap destroy retries
    - final verification

IMPORTANT:

    This is a COMPLETE DESTRUCTION script.

    It permanently deletes the AWS infrastructure managed by this
    Terraform project.

    Do NOT use this against infrastructure that you want to keep.

=======================================================================
#>


# =====================================================================
# GLOBAL SETTINGS
# =====================================================================

$ErrorActionPreference = "Continue"

$AwsRegion = "us-east-1"

$MaxTerraformRetries = 5

$MaxS3CleanupRounds = 50

$RetryDelaySeconds = 20

$ProjectRoot = Split-Path -Parent $PSScriptRoot

$DevDirectory = Join-Path `
    $ProjectRoot `
    "environments\dev"

$BootstrapDirectory = Join-Path `
    $ProjectRoot `
    "bootstrap\state-backend"


# =====================================================================
# AWS HOSTS USED BY THIS PROJECT
# =====================================================================

$AwsHosts = @(
    "ec2.us-east-1.amazonaws.com",
    "s3.us-east-1.amazonaws.com",
    "rds.us-east-1.amazonaws.com",
    "acm.us-east-1.amazonaws.com",
    "secretsmanager.us-east-1.amazonaws.com",
    "route53.amazonaws.com",
    "sts.us-east-1.amazonaws.com"
)


# =====================================================================
# OUTPUT FUNCTIONS
# =====================================================================

function Write-Step {

    param(
        [string]$Message
    )

    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
}


function Write-OK {

    param(
        [string]$Message
    )

    Write-Host "[OK] $Message" -ForegroundColor Green
}


function Write-Warn {

    param(
        [string]$Message
    )

    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}


function Write-Fail {

    param(
        [string]$Message
    )

    Write-Host "[ERROR] $Message" -ForegroundColor Red
}


function Write-Info {

    param(
        [string]$Message
    )

    Write-Host "[INFO] $Message" -ForegroundColor White
}


# =====================================================================
# COMMAND CHECK
# =====================================================================

function Test-RequiredCommands {

    Write-Step "CHECKING REQUIRED COMMANDS"

    $requiredCommands = @(
        "terraform",
        "aws"
    )

    foreach ($commandName in $requiredCommands) {

        if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {

            Write-Fail "Command not found: $commandName"

            Write-Host ""
            Write-Host "Install the missing command before continuing." `
                -ForegroundColor Yellow

            return $false
        }

        Write-OK "$commandName is available."
    }

    return $true
}


# =====================================================================
# CHECK PROJECT DIRECTORIES
# =====================================================================

function Test-ProjectStructure {

    Write-Step "CHECKING PROJECT STRUCTURE"

    if (-not (Test-Path $DevDirectory)) {

        Write-Fail "Dev Terraform directory not found:"
        Write-Fail $DevDirectory

        return $false
    }

    Write-OK "Found environments\dev"

    if (-not (Test-Path $BootstrapDirectory)) {

        Write-Fail "Bootstrap Terraform directory not found:"
        Write-Fail $BootstrapDirectory

        return $false
    }

    Write-OK "Found bootstrap\state-backend"

    return $true
}


# =====================================================================
# AWS CREDENTIAL CHECK
# =====================================================================

function Test-AWSCredentials {

    Write-Step "CHECKING AWS CREDENTIALS"

    $identityOutput = @(
        aws sts get-caller-identity `
            --region $AwsRegion `
            2>&1
    )

    $identityOutput | Write-Host

    if ($LASTEXITCODE -ne 0) {

        Write-Fail "AWS credentials are not working."

        Write-Host ""
        Write-Host "Check your AWS CLI login/profile before continuing." `
            -ForegroundColor Yellow

        return $false
    }

    Write-OK "AWS credentials are valid."

    return $true
}


# =====================================================================
# AWS REGION CHECK
# =====================================================================

function Test-AWSRegion {

    Write-Step "CHECKING AWS REGION"

    Write-Info "Configured region: $AwsRegion"

    $regionCheck = aws ec2 describe-regions `
        --region $AwsRegion `
        --query "Regions[?RegionName=='$AwsRegion'].RegionName" `
        --output text `
        2>$null

    if ($LASTEXITCODE -ne 0) {

        Write-Fail "Unable to communicate with AWS EC2 API."

        return $false
    }

    if ([string]::IsNullOrWhiteSpace($regionCheck)) {

        Write-Fail "AWS region check failed."

        return $false
    }

    Write-OK "AWS region $AwsRegion is available."

    return $true
}


# =====================================================================
# DNS / NETWORK CHECK
# =====================================================================

function Test-DNSStable {

    Write-Step "CHECKING AWS DNS / NETWORK STABILITY"

    Write-Info "Five consecutive DNS passes are required."

    for ($pass = 1; $pass -le 5; $pass++) {

        Write-Host ""
        Write-Host "DNS PASS $pass / 5" -ForegroundColor Cyan

        foreach ($hostName in $AwsHosts) {

            $resolved = $false

            try {

                Resolve-DnsName `
                    -Name $hostName `
                    -ErrorAction Stop |
                    Out-Null

                $resolved = $true
            }
            catch {

                $resolved = $false
            }

            if (-not $resolved) {

                Write-Fail "DNS failed for:"
                Write-Fail $hostName

                Write-Host ""
                Write-Warn "Run:"
                Write-Host "ipconfig /flushdns" -ForegroundColor White

                return $false
            }

            Write-Host "  OK $hostName" -ForegroundColor DarkGreen
        }

        Start-Sleep -Seconds 1
    }

    Write-OK "AWS DNS is stable."

    return $true
}


# =====================================================================
# CHECK LOCAL TERRAFORM PROCESSES
# =====================================================================

function Get-LocalTerraformProcesses {

    return @(
        Get-Process `
            -Name terraform `
            -ErrorAction SilentlyContinue
    )
}


function Test-LocalTerraformRunning {

    $processes = Get-LocalTerraformProcesses

    if ($processes.Count -gt 0) {

        return $true
    }

    return $false
}


# =====================================================================
# EXTRACT TERRAFORM LOCK ID
# =====================================================================

function Get-TerraformLockId {

    param(
        [string]$OutputText
    )

    if ([string]::IsNullOrWhiteSpace($OutputText)) {

        return $null
    }

    $patterns = @(
        "ID:\s+([a-fA-F0-9-]{36})",
        "Lock ID:\s+([a-fA-F0-9-]{36})",
        "LockID:\s+([a-fA-F0-9-]{36})"
    )

    foreach ($pattern in $patterns) {

        if ($OutputText -match $pattern) {

            return $matches[1]
        }
    }

    return $null
}


# =====================================================================
# FORCE UNLOCK
# =====================================================================

function Remove-StaleTerraformLock {

    param(
        [string]$TerraformOutput
    )

    $lockId = Get-TerraformLockId $TerraformOutput

    if ([string]::IsNullOrWhiteSpace($lockId)) {

        return $false
    }

    Write-Step "TERRAFORM STATE LOCK DETECTED"

    Write-Warn "Lock ID:"
    Write-Host $lockId -ForegroundColor Yellow

    if (Test-LocalTerraformRunning) {

        Write-Fail ""
        Write-Fail "A Terraform process is currently running on this computer."
        Write-Fail "The script will NOT force-unlock an active Terraform process."
        Write-Fail ""

        $processes = Get-LocalTerraformProcesses

        foreach ($process in $processes) {

            Write-Host "Terraform PID: $($process.Id)" `
                -ForegroundColor Yellow
        }

        return $false
    }

    Write-Warn "No local Terraform process is running."

    Write-Warn "Attempting automatic force-unlock..."

    $unlockOutput = @(
        terraform force-unlock `
            -force `
            $lockId `
            2>&1
    )

    $unlockOutput | Write-Host

    if ($LASTEXITCODE -eq 0) {

        Write-OK "Terraform state lock removed."

        Start-Sleep -Seconds 5

        return $true
    }

    Write-Fail "Terraform force-unlock failed."

    return $false
}


# =====================================================================
# TERRAFORM INIT
# =====================================================================

function Initialize-TerraformDirectory {

    param(
        [string]$Directory
    )

    Push-Location $Directory

    try {

        Write-Info "Running terraform init -reconfigure..."

        $initOutput = @(
            terraform init -reconfigure 2>&1
        )

        $initOutput | Write-Host

        if ($LASTEXITCODE -eq 0) {

            Write-OK "Terraform initialization successful."

            return $true
        }

        $initText = $initOutput -join "`n"

        if (Remove-StaleTerraformLock $initText) {

            Write-Warn "Retrying Terraform initialization..."

            $initOutput2 = @(
                terraform init -reconfigure 2>&1
            )

            $initOutput2 | Write-Host

            if ($LASTEXITCODE -eq 0) {

                Write-OK "Terraform initialization successful."

                return $true
            }
        }

        Write-Fail "Terraform init failed."

        return $false
    }
    finally {

        Pop-Location
    }
}


# =====================================================================
# DISCOVER STATE BUCKET FROM BOOTSTRAP
# =====================================================================

function Get-StateBucketName {

    Write-Step "DISCOVERING TERRAFORM STATE BUCKET"

    if (-not (Test-Path $BootstrapDirectory)) {

        Write-Fail "Bootstrap directory does not exist."

        return $null
    }

    Push-Location $BootstrapDirectory

    try {

        # -------------------------------------------------------------
        # Try Terraform output first
        # -------------------------------------------------------------

        $bucket = terraform output -raw state_bucket_name 2>$null

        if ($LASTEXITCODE -eq 0) {

            if (-not [string]::IsNullOrWhiteSpace($bucket)) {

                $bucket = $bucket.Trim()

                Write-OK "State bucket discovered:"
                Write-Host $bucket -ForegroundColor White

                return $bucket
            }
        }

        # -------------------------------------------------------------
        # Try terraform state directly
        # -------------------------------------------------------------

        $stateOutput = @(
            terraform state show `
                aws_s3_bucket.state `
                2>&1
        )

        $stateText = $stateOutput -join "`n"

        if ($stateText -match 'bucket\s+=\s+"([^"]+)"') {

            $bucket = $matches[1]

            Write-OK "State bucket discovered from Terraform state:"
            Write-Host $bucket -ForegroundColor White

            return $bucket
        }

        # -------------------------------------------------------------
        # Last fallback: AWS search by known project prefix
        # -------------------------------------------------------------

        Write-Warn "Terraform output did not reveal the state bucket."

        Write-Info "Searching AWS S3 buckets for nexops-terraform-state-*..."

        $bucketList = @(
            aws s3api list-buckets `
                --query "Buckets[].Name" `
                --output text `
                2>$null
        )

        foreach ($line in $bucketList) {

            foreach ($name in ($line -split "\s+")) {

                if (
                    $name -like "nexops-terraform-state-*" -and
                    -not [string]::IsNullOrWhiteSpace($name)
                ) {

                    Write-OK "Found state bucket:"
                    Write-Host $name -ForegroundColor White

                    return $name
                }
            }
        }

        Write-Warn "No Terraform state bucket was found."

        return $null
    }
    finally {

        Pop-Location
    }
}


# =====================================================================
# CHECK S3 BUCKET EXISTS
# =====================================================================

function Test-S3BucketExists {

    param(
        [string]$Bucket
    )

    if ([string]::IsNullOrWhiteSpace($Bucket)) {

        return $false
    }

    aws s3api head-bucket `
        --bucket $Bucket `
        --region $AwsRegion `
        2>$null

    if ($LASTEXITCODE -eq 0) {

        return $true
    }

    return $false
}


# =====================================================================
# DELETE ALL S3 VERSIONS + DELETE MARKERS
# =====================================================================

function Empty-VersionedS3Bucket {

    param(
        [Parameter(Mandatory=$true)]
        [string]$Bucket
    )

    Write-Step "COMPLETELY EMPTYING VERSIONED S3 STATE BUCKET"

    Write-Info "Bucket:"
    Write-Host $Bucket -ForegroundColor White

    if (-not (Test-S3BucketExists $Bucket)) {

        Write-OK "S3 bucket does not exist."

        return $true
    }

    # -----------------------------------------------------------------
    # STEP 1 - NORMAL OBJECT DELETE
    # -----------------------------------------------------------------

    Write-Host ""
    Write-Host "Removing normal S3 objects..." -ForegroundColor Yellow

    $normalDelete = @(
        aws s3 rm `
            "s3://$Bucket" `
            --recursive `
            --region $AwsRegion `
            2>&1
    )

    $normalDelete | Write-Host

    # -----------------------------------------------------------------
    # STEP 2 - VERSIONED OBJECTS
    # -----------------------------------------------------------------

    for ($round = 1; $round -le $MaxS3CleanupRounds; $round++) {

        Write-Host ""
        Write-Host "S3 VERSION CLEANUP ROUND $round / $MaxS3CleanupRounds" `
            -ForegroundColor Cyan

        $json = @(
            aws s3api list-object-versions `
                --bucket $Bucket `
                --region $AwsRegion `
                --output json `
                2>&1
        )

        if ($LASTEXITCODE -ne 0) {

            Write-Warn "Unable to list S3 versions."

            Write-Host ($json -join "`n")

            Start-Sleep -Seconds 10

            continue
        }

        $jsonText = $json -join "`n"

        if ([string]::IsNullOrWhiteSpace($jsonText)) {

            Write-OK "S3 bucket has no remaining versions."

            break
        }

        try {

            $data = $jsonText | ConvertFrom-Json
        }
        catch {

            Write-Fail "Could not parse AWS S3 response."

            return $false
        }

        $objectsToDelete = @()

        # -----------------------------------------------------------------
        # OBJECT VERSIONS
        # -----------------------------------------------------------------

        foreach ($version in @($data.Versions)) {

            if (
                $null -ne $version.Key -and
                $null -ne $version.VersionId
            ) {

                $objectsToDelete += @{
                    Key       = [string]$version.Key
                    VersionId = [string]$version.VersionId
                }
            }
        }

        # -----------------------------------------------------------------
        # DELETE MARKERS
        # -----------------------------------------------------------------

        foreach ($marker in @($data.DeleteMarkers)) {

            if (
                $null -ne $marker.Key -and
                $null -ne $marker.VersionId
            ) {

                $objectsToDelete += @{
                    Key       = [string]$marker.Key
                    VersionId = [string]$marker.VersionId
                }
            }
        }

        # -----------------------------------------------------------------
        # NOTHING LEFT
        # -----------------------------------------------------------------

        if ($objectsToDelete.Count -eq 0) {

            Write-OK "No object versions or delete markers remain."

            break
        }

        Write-Warn "Found $($objectsToDelete.Count) versions/delete markers."

        # -----------------------------------------------------------------
        # DELETE MAXIMUM 1000 AT A TIME
        # -----------------------------------------------------------------

        for (
            $start = 0;
            $start -lt $objectsToDelete.Count;
            $start += 1000
        ) {

            $end = [Math]::Min(
                $start + 999,
                $objectsToDelete.Count - 1
            )

            $batch = @()

            for ($i = $start; $i -le $end; $i++) {

                $batch += $objectsToDelete[$i]
            }

            Write-Info "Deleting S3 entries $($start + 1) through $($end + 1)..."

            $deletePayload = @{
                Objects = $batch
                Quiet   = $true
            } | ConvertTo-Json -Depth 10 -Compress

            $temporaryFile = Join-Path `
                $env:TEMP `
                "nexops-s3-delete-$([guid]::NewGuid()).json"

            try {

                Set-Content `
                    -Path $temporaryFile `
                    -Value $deletePayload `
                    -Encoding UTF8

                $deleteOutput = @(
                    aws s3api delete-objects `
                        --bucket $Bucket `
                        --delete "file://$temporaryFile" `
                        --region $AwsRegion `
                        2>&1
                )

                $deleteOutput | Write-Host

                if ($LASTEXITCODE -ne 0) {

                    Write-Warn "S3 batch deletion failed."

                    Start-Sleep -Seconds 10

                    continue
                }
            }
            finally {

                Remove-Item `
                    $temporaryFile `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }

        Start-Sleep -Seconds 3
    }

    # -----------------------------------------------------------------
    # FINAL VERIFICATION
    # -----------------------------------------------------------------

    Write-Host ""
    Write-Host "FINAL S3 BUCKET VERIFICATION" -ForegroundColor Cyan

    for ($check = 1; $check -le 5; $check++) {

        $verifyJson = @(
            aws s3api list-object-versions `
                --bucket $Bucket `
                --region $AwsRegion `
                --output json `
                2>&1
        )

        if ($LASTEXITCODE -ne 0) {

            Write-Warn "S3 verification failed. Retrying..."

            Start-Sleep -Seconds 5

            continue
        }

        try {

            $verifyText = $verifyJson -join "`n"

            $verifyData = $verifyText | ConvertFrom-Json

            $remainingVersions = @(
                $verifyData.Versions
            ).Count

            $remainingMarkers = @(
                $verifyData.DeleteMarkers
            ).Count

            Write-Host ""
            Write-Host "Remaining object versions : $remainingVersions"
            Write-Host "Remaining delete markers  : $remainingMarkers"

            if (
                $remainingVersions -eq 0 -and
                $remainingMarkers -eq 0
            ) {

                Write-OK "S3 BUCKET IS COMPLETELY EMPTY."

                return $true
            }
        }
        catch {

            Write-Warn "Could not parse verification response."
        }

        Start-Sleep -Seconds 5
    }

    Write-Fail "S3 bucket still contains data."

    return $false
}


# =====================================================================
# MANUALLY DELETE EMPTY STATE BUCKET
# =====================================================================

function Remove-StateBucketDirectly {

    param(
        [string]$Bucket
    )

    Write-Step "DELETING EMPTY TERRAFORM STATE BUCKET"

    if (-not (Test-S3BucketExists $Bucket)) {

        Write-OK "State bucket already does not exist."

        return $true
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {

        Write-Info "Bucket deletion attempt $attempt / 5..."

        $deleteOutput = @(
            aws s3api delete-bucket `
                --bucket $Bucket `
                --region $AwsRegion `
                2>&1
        )

        $deleteOutput | Write-Host

        if ($LASTEXITCODE -eq 0) {

            Write-OK "State bucket deleted directly through AWS."

            return $true
        }

        $deleteText = $deleteOutput -join "`n"

        if (
            $deleteText -match "BucketNotEmpty" -or
            $deleteText -match "must delete all versions"
        ) {

            Write-Warn "Bucket is still not empty."

            if (-not (Empty-VersionedS3Bucket $Bucket)) {

                return $false
            }
        }
        else {

            Write-Warn "AWS bucket deletion failed."

            Start-Sleep -Seconds 10
        }
    }

    if (-not (Test-S3BucketExists $Bucket)) {

        Write-OK "State bucket no longer exists."

        return $true
    }

    Write-Fail "Unable to delete state bucket."

    return $false
}


# =====================================================================
# REMOVE RESOURCE FROM TERRAFORM STATE
# =====================================================================

function Remove-StateBucketFromTerraformState {

    Write-Step "REMOVING MANUALLY DELETED BUCKET FROM BOOTSTRAP STATE"

    Push-Location $BootstrapDirectory

    try {

        $stateList = @(
            terraform state list 2>$null
        )

        if ($LASTEXITCODE -ne 0) {

            Write-Warn "Could not read bootstrap Terraform state."

            return $true
        }

        $resources = $stateList | ForEach-Object {
            $_.ToString().Trim()
        }

        $bucketResources = @(
            $resources | Where-Object {
                $_ -eq "aws_s3_bucket.state"
            }
        )

        if ($bucketResources.Count -eq 0) {

            Write-OK "aws_s3_bucket.state is already absent from state."

            return $true
        }

        Write-Warn "The S3 bucket was manually deleted."

        Write-Info "Removing aws_s3_bucket.state from Terraform state..."

        $removeOutput = @(
            terraform state rm `
                "aws_s3_bucket.state" `
                2>&1
        )

        $removeOutput | Write-Host

        if ($LASTEXITCODE -eq 0) {

            Write-OK "S3 bucket removed from Terraform state."

            return $true
        }

        $removeText = $removeOutput -join "`n"

        if (Remove-StaleTerraformLock $removeText) {

            $removeOutput2 = @(
                terraform state rm `
                    "aws_s3_bucket.state" `
                    2>&1
            )

            $removeOutput2 | Write-Host

            if ($LASTEXITCODE -eq 0) {

                Write-OK "S3 bucket removed from Terraform state."

                return $true
            }
        }

        Write-Fail "Could not remove bucket from Terraform state."

        return $false
    }
    finally {

        Pop-Location
    }
}


# =====================================================================
# DESTROY DEV ENVIRONMENT
# =====================================================================

function Destroy-DevEnvironment {

    Write-Step "DESTROYING ENVIRONMENTS\DEV"

    Push-Location $DevDirectory

    try {

        if (-not (Initialize-TerraformDirectory $DevDirectory)) {

            return $false
        }

        for (
            $attempt = 1;
            $attempt -le $MaxTerraformRetries;
            $attempt++
        ) {

            Write-Host ""
            Write-Host "DEV DESTROY ATTEMPT $attempt / $MaxTerraformRetries" `
                -ForegroundColor Cyan

            $destroyOutput = @(
                terraform destroy `
                    -auto-approve `
                    2>&1
            )

            $destroyOutput | Write-Host

            if ($LASTEXITCODE -eq 0) {

                Write-OK "DEV ENVIRONMENT DESTROY COMPLETE."

                return $true
            }

            $destroyText = $destroyOutput -join "`n"

            # ---------------------------------------------------------
            # LOCK
            # ---------------------------------------------------------

            if (Remove-StaleTerraformLock $destroyText) {

                continue
            }

            # ---------------------------------------------------------
            # NETWORK / AWS TRANSIENT ERROR
            # ---------------------------------------------------------

            if (
                $destroyText -match "timeout" -or
                $destroyText -match "connection" -or
                $destroyText -match "TLS" -or
                $destroyText -match "503" -or
                $destroyText -match "502" -or
                $destroyText -match "500" -or
                $destroyText -match "RequestLimitExceeded" -or
                $destroyText -match "Throttl"
            ) {

                Write-Warn "Transient AWS/network error detected."

                Write-Warn "Waiting before retry..."

                Start-Sleep -Seconds $RetryDelaySeconds

                continue
            }

            # ---------------------------------------------------------
            # OTHER ERROR
            # ---------------------------------------------------------

            if ($attempt -lt $MaxTerraformRetries) {

                Write-Warn "Destroy failed."

                Write-Warn "Terraform can safely retry remaining resources."

                Start-Sleep -Seconds $RetryDelaySeconds

                continue
            }
        }

        Write-Fail "DEV environment was not completely destroyed."

        return $false
    }
    finally {

        Pop-Location
    }
}


# =====================================================================
# DESTROY BOOTSTRAP RESOURCES EXCEPT STATE BUCKET
# =====================================================================

function Destroy-BootstrapResources {

    Write-Step "DESTROYING BOOTSTRAP / STATE-BACKEND RESOURCES"

    Push-Location $BootstrapDirectory

    try {

        if (-not (Initialize-TerraformDirectory $BootstrapDirectory)) {

            return $false
        }

        for (
            $attempt = 1;
            $attempt -le $MaxTerraformRetries;
            $attempt++
        ) {

            Write-Host ""
            Write-Host "BOOTSTRAP DESTROY ATTEMPT $attempt / $MaxTerraformRetries" `
                -ForegroundColor Cyan

            $destroyOutput = @(
                terraform destroy `
                    -auto-approve `
                    2>&1
            )

            $destroyOutput | Write-Host

            if ($LASTEXITCODE -eq 0) {

                Write-OK "BOOTSTRAP DESTROY COMPLETE."

                return $true
            }

            $destroyText = $destroyOutput -join "`n"

            # ---------------------------------------------------------
            # LOCK
            # ---------------------------------------------------------

            if (Remove-StaleTerraformLock $destroyText) {

                continue
            }

            # ---------------------------------------------------------
            # BUCKET NOT EMPTY
            # ---------------------------------------------------------

            if (
                $destroyText -match "BucketNotEmpty" -or
                $destroyText -match "bucket.*not empty" -or
                $destroyText -match "delete all versions"
            ) {

                Write-Warn "Terraform reported BucketNotEmpty."

                $bucket = Get-StateBucketName

                if ($bucket) {

                    if (-not (Empty-VersionedS3Bucket $bucket)) {

                        return $false
                    }

                    continue
                }
            }

            # ---------------------------------------------------------
            # prevent_destroy
            # ---------------------------------------------------------

            if ($destroyText -match "prevent_destroy") {

                Write-Warn ""
                Write-Warn "Terraform prevent_destroy is enabled."
                Write-Warn "The script will handle the state bucket directly."

                $bucket = Get-StateBucketName

                if ($bucket) {

                    # -------------------------------------------------
                    # EMPTY FIRST
                    # -------------------------------------------------

                    if (-not (Empty-VersionedS3Bucket $bucket)) {

                        return $false
                    }

                    # -------------------------------------------------
                    # DELETE BUCKET DIRECTLY
                    # -------------------------------------------------

                    if (-not (Remove-StateBucketDirectly $bucket)) {

                        return $false
                    }

                    # -------------------------------------------------
                    # REMOVE FROM TF STATE
                    # -------------------------------------------------

                    if (-not (Remove-StateBucketFromTerraformState)) {

                        return $false
                    }

                    continue
                }

                Write-Fail "Could not discover state bucket."

                return $false
            }

            # ---------------------------------------------------------
            # TRANSIENT NETWORK/AWS
            # ---------------------------------------------------------

            if (
                $destroyText -match "timeout" -or
                $destroyText -match "connection" -or
                $destroyText -match "TLS" -or
                $destroyText -match "503" -or
                $destroyText -match "502" -or
                $destroyText -match "500" -or
                $destroyText -match "RequestLimitExceeded" -or
                $destroyText -match "Throttl"
            ) {

                Write-Warn "Transient AWS/network error detected."

                Start-Sleep -Seconds $RetryDelaySeconds

                continue
            }

            # ---------------------------------------------------------
            # RETRY
            # ---------------------------------------------------------

            if ($attempt -lt $MaxTerraformRetries) {

                Write-Warn "Bootstrap destroy did not finish."

                Write-Warn "Waiting before retry..."

                Start-Sleep -Seconds $RetryDelaySeconds

                continue
            }
        }

        Write-Fail "Bootstrap resources were not completely destroyed."

        return $false
    }
    finally {

        Pop-Location
    }
}


# =====================================================================
# FINAL BOOTSTRAP STATE CHECK
# =====================================================================

function Test-BootstrapStateEmpty {

    Write-Step "VERIFYING BOOTSTRAP TERRAFORM STATE"

    Push-Location $BootstrapDirectory

    try {

        $stateOutput = @(
            terraform state list 2>&1
        )

        $stateText = $stateOutput -join "`n"

        if ($LASTEXITCODE -ne 0) {

            Write-Warn "Could not read final Terraform state."

            Write-Host $stateText

            return $false
        }

        $resources = @(
            $stateOutput |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
        )

        if ($resources.Count -eq 0) {

            Write-OK "Bootstrap Terraform state is empty."

            return $true
        }

        Write-Warn "Bootstrap Terraform state still contains:"

        $resources | Write-Host

        return $false
    }
    finally {

        Pop-Location
    }
}


# =====================================================================
# FINAL S3 CHECK
# =====================================================================

function Test-StateBucketGone {

    param(
        [string]$Bucket
    )

    if ([string]::IsNullOrWhiteSpace($Bucket)) {

        Write-Info "No state bucket name available for final check."

        return $true
    }

    Write-Step "VERIFYING TERRAFORM STATE BUCKET"

    if (Test-S3BucketExists $Bucket) {

        Write-Fail "State bucket still exists:"
        Write-Fail $Bucket

        return $false
    }

    Write-OK "State bucket no longer exists."

    return $true
}


# =====================================================================
# FINAL AWS PROJECT BUCKET CHECK
# =====================================================================

function Show-RemainingNexopsBuckets {

    Write-Step "CHECKING FOR REMAINING NEXOPS S3 BUCKETS"

    $bucketOutput = @(
        aws s3api list-buckets `
            --query "Buckets[].Name" `
            --output text `
            2>$null
    )

    if ($LASTEXITCODE -ne 0) {

        Write-Warn "Could not query S3 buckets."

        return
    }

    $remaining = @()

    foreach ($line in $bucketOutput) {

        foreach ($bucket in ($line -split "\s+")) {

            if (
                -not [string]::IsNullOrWhiteSpace($bucket) -and
                (
                    $bucket -like "nexops-*" -or
                    $bucket -like "*nexops*"
                )
            ) {

                $remaining += $bucket
            }
        }
    }

    if ($remaining.Count -eq 0) {

        Write-OK "No NexOps S3 buckets found."

        return
    }

    Write-Warn "Possible remaining NexOps S3 buckets:"

    $remaining | Sort-Object -Unique | Write-Host
}


# =====================================================================
# FINAL CHECK
# =====================================================================

function FinalVerification {

    param(
        [string]$StateBucket
    )

    Write-Step "FINAL DESTRUCTION VERIFICATION"

    $success = $true

    # ---------------------------------------------------------------
    # STATE BUCKET
    # ---------------------------------------------------------------

    if ($StateBucket) {

        if (-not (Test-StateBucketGone $StateBucket)) {

            $success = $false
        }
    }

    # ---------------------------------------------------------------
    # BOOTSTRAP STATE
    # ---------------------------------------------------------------

    if (-not (Test-BootstrapStateEmpty)) {

        $success = $false
    }

    # ---------------------------------------------------------------
    # REMAINING BUCKETS
    # ---------------------------------------------------------------

    Show-RemainingNexopsBuckets

    return $success
}


# =====================================================================
# MAIN
# =====================================================================

Clear-Host

Write-Host ""
Write-Host "######################################################################" `
    -ForegroundColor Red

Write-Host "#                                                                    #" `
    -ForegroundColor Red

Write-Host "#             NEXOPS COMPLETE AWS DESTROY                           #" `
    -ForegroundColor Red

Write-Host "#                                                                    #" `
    -ForegroundColor Red

Write-Host "######################################################################" `
    -ForegroundColor Red

Write-Host ""

Write-Host "PROJECT ROOT:" -ForegroundColor Cyan
Write-Host $ProjectRoot

Write-Host ""

Write-Host "AWS REGION:" -ForegroundColor Cyan
Write-Host $AwsRegion

Write-Host ""

Write-Warn "THIS SCRIPT WILL DESTROY THE AWS INFRASTRUCTURE MANAGED BY:"
Write-Host ""

Write-Host "  environments\dev" -ForegroundColor Yellow
Write-Host "  bootstrap\state-backend" -ForegroundColor Yellow

Write-Host ""

Write-Warn "The Terraform state S3 bucket will also be emptied and deleted."

Write-Host ""

# =====================================================================
# BASIC CHECKS
# =====================================================================

if (-not (Test-RequiredCommands)) {

    exit 1
}


if (-not (Test-ProjectStructure)) {

    exit 1
}


if (-not (Test-AWSCredentials)) {

    exit 1
}


if (-not (Test-AWSRegion)) {

    exit 1
}


if (-not (Test-DNSStable)) {

    exit 1
}


# =====================================================================
# DISCOVER STATE BUCKET BEFORE DESTROY
# =====================================================================

$StateBucketBeforeDestroy = Get-StateBucketName


# =====================================================================
# FINAL CONFIRMATION
# =====================================================================

Write-Host ""
Write-Host "######################################################################" `
    -ForegroundColor Red

Write-Host ""
Write-Host "FINAL WARNING" -ForegroundColor Red
Write-Host ""

Write-Host "This operation is destructive." -ForegroundColor Yellow

Write-Host ""
Write-Host "Type exactly:" -ForegroundColor White
Write-Host ""
Write-Host "DESTROY-ALL" -ForegroundColor Red
Write-Host ""

$confirmation = Read-Host "Confirmation"

if ($confirmation -ne "DESTROY-ALL") {

    Write-Warn "Destroy cancelled."

    exit 0
}


# =====================================================================
# CHECK FOR ACTIVE TERRAFORM PROCESS
# =====================================================================

if (Test-LocalTerraformRunning) {

    Write-Fail ""
    Write-Fail "A Terraform process is already running on this computer."
    Write-Fail ""

    $processes = Get-LocalTerraformProcesses

    foreach ($process in $processes) {

        Write-Fail "Terraform PID: $($process.Id)"
    }

    Write-Fail ""
    Write-Fail "Close the other Terraform operation before starting destroy."

    exit 1
}


# =====================================================================
# PHASE 1 - DEV
# =====================================================================

Write-Step "PHASE 1 / 3 - DESTROYING DEV INFRASTRUCTURE"

if (-not (Destroy-DevEnvironment)) {

    Write-Fail ""
    Write-Fail "DEV DESTROY DID NOT COMPLETE."
    Write-Fail ""
    Write-Fail "The script has stopped to avoid pretending everything is gone."

    exit 1
}


# =====================================================================
# PHASE 2 - STATE BUCKET
# =====================================================================

Write-Step "PHASE 2 / 3 - CLEANING TERRAFORM STATE BUCKET"

$StateBucketAfterDev = Get-StateBucketName

if (
    $StateBucketAfterDev
) {

    Write-Info "Terraform state bucket:"
    Write-Host $StateBucketAfterDev -ForegroundColor White

    if (-not (Empty-VersionedS3Bucket $StateBucketAfterDev)) {

        Write-Fail ""
        Write-Fail "Could not completely empty Terraform state bucket."

        exit 1
    }
}
else {

    Write-Warn "Terraform state bucket could not be discovered."

    Write-Info "Bootstrap Terraform will determine whether it still exists."
}


# =====================================================================
# PHASE 3 - BOOTSTRAP
# =====================================================================

Write-Step "PHASE 3 / 3 - DESTROYING BOOTSTRAP"

if (-not (Destroy-BootstrapResources)) {

    Write-Fail ""
    Write-Fail "BOOTSTRAP DESTROY DID NOT COMPLETE."

    exit 1
}


# =====================================================================
# FINAL BUCKET CLEANUP
# =====================================================================

if ($StateBucketAfterDev) {

    if (Test-S3BucketExists $StateBucketAfterDev) {

        Write-Step "FINAL STATE BUCKET CLEANUP"

        if (-not (Empty-VersionedS3Bucket $StateBucketAfterDev)) {

            Write-Fail "Unable to empty state bucket during final cleanup."

            exit 1
        }

        if (-not (Remove-StateBucketDirectly $StateBucketAfterDev)) {

            Write-Fail "Unable to delete state bucket."

            exit 1
        }
    }
}


# =====================================================================
# FINAL VERIFICATION
# =====================================================================

if (-not (FinalVerification $StateBucketAfterDev)) {

    Write-Host ""
    Write-Fail "=================================================================="
    Write-Fail " DESTROY FINISHED WITH REMAINING RESOURCES"
    Write-Fail "=================================================================="

    Write-Host ""
    Write-Fail "The script did not falsely report success."

    exit 1
}


# =====================================================================
# SUCCESS
# =====================================================================

Write-Host ""
Write-Host ""
Write-Host "######################################################################" `
    -ForegroundColor Green

Write-Host "#                                                                    #" `
    -ForegroundColor Green

Write-Host "#                 COMPLETE DESTROY SUCCESSFUL                      #" `
    -ForegroundColor Green

Write-Host "#                                                                    #" `
    -ForegroundColor Green

Write-Host "######################################################################" `
    -ForegroundColor Green

Write-Host ""

Write-OK "environments\dev destroyed."
Write-OK "Terraform state S3 versions removed."
Write-OK "Terraform S3 delete markers removed."
Write-OK "Terraform state bucket deleted."
Write-OK "bootstrap\state-backend destroyed."
Write-OK "Terraform bootstrap state verified."

Write-Host ""
Write-Host "AWS infrastructure is ready for a completely fresh deployment." `
    -ForegroundColor Cyan

Write-Host ""