# ==============================================================================
# SCRIPT 3: 3-status-urls-audit.ps1
# Purpose: Show live ALB/Domain URLs, all running services, age, cost & activity
# ==============================================================================

$ErrorActionPreference = "Continue"
$Region = "us-east-1"
$ReportFile = "aws-live-report.txt"
$AccountId = (aws sts get-caller-identity --query "Account" --output text)

function Get-AgeString {
    param([string]$DateString)
    if (-not $DateString -or $DateString -eq "None" -or $DateString -eq "null") { return "Unknown" }
    try {
        $created = [DateTime]::Parse($DateString).ToUniversalTime()
        $span = (Get-Date).ToUniversalTime() - $created
        return "$($span.Days)d $($span.Hours)h $($span.Minutes)m (Since $($created.ToString('yyyy-MM-dd HH:mm')) UTC)"
    } catch { return $DateString }
}

$out = @()
$out += "================================================================================"
$out += " AWS LIVE ACCESS URLS, SERVICES, COST & ACTIVITY REPORT"
$out += " Account: $AccountId | Region: $Region | Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$out += "================================================================================"

# --- 1. DIRECT ACCESS URLS & DOMAINS ---
$out += "`n[1. DIRECT ACCESS URLS & DOMAINS]"
$albs = aws elbv2 describe-load-balancers --region $Region --query "LoadBalancers[]" --output json | ConvertFrom-Json
if ($albs) {
    foreach ($lb in $albs) {
        $out += "  - Load Balancer ($($lb.LoadBalancerName)):"
        $out += "      Direct App URL    : http://$($lb.DNSName)"
        $out += "      Health Check URL  : http://$($lb.DNSName)/api/health"
        $out += "      State / Age       : $($lb.State.Code) | $(Get-AgeString $lb.CreatedTime)"
    }
} else { $out += "  - Load Balancers: (None running)" }

$zones = aws route53 list-hosted-zones --query "HostedZones[]" --output json 2>$null | ConvertFrom-Json
if ($zones) {
    foreach ($z in $zones) {
        $out += "  - Route53 Domain      : $($z.Name) (ID: $($z.Id))"
    }
}

$rdsList = aws rds describe-db-instances --region $Region --query "DBInstances[]" --output json | ConvertFrom-Json
if ($rdsList) {
    foreach ($db in $rdsList) {
        $out += "  - RDS Endpoint        : $($db.Endpoint.Address):$($db.Endpoint.Port) ($($db.DBInstanceIdentifier))"
    }
}

# --- 2. TARGET GROUP HEALTH ---
$out += "`n[2. LOAD BALANCER TARGET HEALTH]"
$tgs = aws elbv2 describe-target-groups --region $Region --query "TargetGroups[]" --output json | ConvertFrom-Json
if ($tgs) {
    foreach ($tg in $tgs) {
        $health = aws elbv2 describe-target-health --target-group-arn $tg.TargetGroupArn --region $Region --query "TargetHealthDescriptions[]" --output json | ConvertFrom-Json
        if ($health) {
            foreach ($h in $health) {
                $out += "  - $($tg.TargetGroupName) -> Target: $($h.Target.Id):$($h.Target.Port) | Status: $($h.TargetHealth.State) ($($h.TargetHealth.Reason))"
            }
        } else { $out += "  - $($tg.TargetGroupName) -> (No targets registered)" }
    }
} else { $out += "  (No target groups)" }

# --- 3. RUNNING COMPUTE, STORAGE & NETWORKING ---
$out += "`n[3. RUNNING SERVICES & EXACT AGE]"
$ec2s = aws ec2 describe-instances --region $Region --query "Reservations[].Instances[?State.Name=='running' || State.Name=='pending']" --output json | ConvertFrom-Json
if ($ec2s) {
    foreach ($i in $ec2s) {
        $nameTag = ($i.Tags | Where-Object { $_.Key -eq "Name" }).Value
        $out += "  - EC2 Instance  : $($i.InstanceId) ($nameTag) | Type: $($i.InstanceType) | PrivateIP: $($i.PrivateIpAddress) | Age: $(Get-AgeString $i.LaunchTime)"
    }
} else { $out += "  - EC2 Instances : (None running)" }

if ($rdsList) {
    foreach ($db in $rdsList) {
        $out += "  - RDS Database  : $($db.DBInstanceIdentifier) ($($db.Engine)) | Status: $($db.DBInstanceStatus) | Age: $(Get-AgeString $db.InstanceCreateTime)"
    }
}

$lambdas = aws lambda list-functions --region $Region --query "Functions[]" --output json | ConvertFrom-Json
foreach ($fn in $lambdas) { $out += "  - Lambda        : $($fn.FunctionName) ($($fn.Runtime)) | Updated: $(Get-AgeString $fn.LastModified)" }

$buckets = aws s3api list-buckets --query "Buckets[]" --output json | ConvertFrom-Json
foreach ($b in $buckets) { $out += "  - S3 Bucket     : $($b.Name) | Age: $(Get-AgeString $b.CreationDate)" }

$nats = aws ec2 describe-nat-gateways --region $Region --filter "Name=state,Values=available,pending" --query "NatGateways[]" --output json | ConvertFrom-Json
foreach ($n in $nats) { $out += "  - NAT Gateway   : $($n.NatGatewayId) | Age: $(Get-AgeString $n.CreateTime)" }

# --- 4. MONTH-TO-DATE COST ---
$out += "`n[4. CURRENT MONTH SPEND BY SERVICE]"
$startOfMonth = (Get-Date -Day 1).ToString("yyyy-MM-dd")
$tomorrow = (Get-Date).AddDays(1).ToString("yyyy-MM-dd")
$costJson = aws ce get-cost-and-usage --time-period "Start=$startOfMonth,End=$tomorrow" --granularity MONTHLY --metrics "UnblendedCost" --group-by "Type=DIMENSION,Key=SERVICE" --output json 2>$null | ConvertFrom-Json
if ($costJson -and $costJson.ResultsByTime.Groups) {
    $total = 0
    foreach ($g in $costJson.ResultsByTime.Groups) {
        $amt = [decimal]$g.Metrics.UnblendedCost.Amount
        if ($amt -gt 0) {
            $total += $amt
            $out += ("  - {0,-42} : {1:N4} USD" -f $g.Keys, $amt)
        }
    }
    $out += ("  TOTAL MONTH-TO-DATE SPEND                    : {0:N4} USD" -f $total)
} else { $out += "  TOTAL MONTH-TO-DATE SPEND                    : 0.0000 USD" }

# --- 5. RECENT ACCOUNT ACTIVITY (CLOUDTRAIL) ---
$out += "`n[5. COMPLETE RECENT ACCOUNT ACTIVITY (LAST 30 EVENTS)]"
$trail = aws cloudtrail lookup-events --region $Region --max-results 30 --query "Events[].{Time:EventTime,Event:EventName,Source:EventSource,User:Username}" --output json 2>$null | ConvertFrom-Json
if ($trail) {
    foreach ($ev in $trail) {
        $t = [DateTime]::Parse($ev.Time).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
        $u = if ($ev.User) { $ev.User } else { "System/Role" }
        $out += ("  - {0} UTC | {1,-28} | {2,-26} | By: {3}" -f $t, $ev.Event, $ev.Source, $u)
    }
}

$report = $out -join "`n"
Write-Host $report -ForegroundColor White
$report | Out-File -FilePath $ReportFile -Encoding UTF8
Write-Host "`nSaved full report to: $(Resolve-Path $ReportFile)" -ForegroundColor Yellow

