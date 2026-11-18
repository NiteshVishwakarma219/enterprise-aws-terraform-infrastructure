# ==============================================================================
# File 2: aws-account-audit.ps1
# Purpose: List all running AWS services, exact age (days/hours), costs & activity
# ==============================================================================

$ErrorActionPreference = "Continue"
$Region = "us-east-1"
$ReportFile = "aws-full-audit.txt"
$AccountId = (aws sts get-caller-identity --query "Account" --output text)

function Get-AgeString {
    param([string]$DateString)
    if (-not $DateString -or $DateString -eq "None" -or $DateString -eq "null") {
        return "Unknown age"
    }
    try {
        $created = [DateTime]::Parse($DateString).ToUniversalTime()
        $now = (Get-Date).ToUniversalTime()
        $span = $now - $created
        return "$($span.Days) days, $($span.Hours) hrs, $($span.Minutes) mins (Since $($created.ToString('yyyy-MM-dd HH:mm')) UTC)"
    } catch {
        return "Date: $DateString"
    }
}

$out = @()
$out += "================================================================================"
$out += " AWS FULL ACCOUNT AUDIT & ACTIVITY REPORT"
$out += " Account ID : $AccountId | Region: $Region"
$out += " Generated  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$out += "================================================================================"

# --- 1. MONTH-TO-DATE COST BY SERVICE ---
$out += "`n[1. CURRENT MONTH COST & USAGE BY SERVICE]"
$startOfMonth = (Get-Date -Day 1).ToString("yyyy-MM-dd")
$tomorrow = (Get-Date).AddDays(1).ToString("yyyy-MM-dd")
$costJson = aws ce get-cost-and-usage --time-period "Start=$startOfMonth,End=$tomorrow" --granularity MONTHLY --metrics "UnblendedCost" --group-by "Type=DIMENSION,Key=SERVICE" --output json 2>$null | ConvertFrom-Json
if ($costJson -and $costJson.ResultsByTime.Groups) {
    $totalCost = 0
    foreach ($g in $costJson.ResultsByTime.Groups) {
        $serviceName = $g.Keys[0]
        $amt = [decimal]$g.Metrics.UnblendedCost.Amount
        $unit = $g.Metrics.UnblendedCost.Unit
        $totalCost += $amt
        $out += ("  - {0,-42} : {1:N4} {2}" -f $serviceName, $amt, $unit)
    }
    $out += ("  ------------------------------------------------------------------")
    $out += ("  TOTAL MONTH-TO-DATE SPEND                    : {0:N4} USD" -f $totalCost)
} else {
    $out += "  (Cost Explorer data unavailable or `$0.00 spend so far)"
}

# --- 2. EC2 INSTANCES ---
$out += "`n[2. EC2 INSTANCES]"
$ec2Json = aws ec2 describe-instances --region $Region --query "Reservations[].Instances[?State.Name!='terminated'].{Id:InstanceId,Name:Tags[?Key=='Name'] | [0].Value,Type:InstanceType,State:State.Name,Launch:LaunchTime}" --output json | ConvertFrom-Json
if ($ec2Json) {
    foreach ($i in $ec2Json) {
        $out += "  - $($i.Id) | Name: $($i.Name) | Type: $($i.Type) | State: $($i.State) | Running for: $(Get-AgeString $i.Launch)"
    }
} else { $out += "  (None running)" }

# --- 3. LOAD BALANCERS ---
$out += "`n[3. LOAD BALANCERS (ALB/NLB)]"
$albJson = aws elbv2 describe-load-balancers --region $Region --query "LoadBalancers[].{Name:LoadBalancerName,State:State.Code,Created:CreatedTime}" --output json | ConvertFrom-Json
if ($albJson) {
    foreach ($lb in $albJson) {
        $out += "  - $($lb.Name) | State: $($lb.State) | Running for: $(Get-AgeString $lb.Created)"
    }
} else { $out += "  (None running)" }

# --- 4. RDS DATABASES ---
$out += "`n[4. RDS DATABASES]"
$rdsJson = aws rds describe-db-instances --region $Region --query "DBInstances[].{Id:DBInstanceIdentifier,Engine:Engine,Class:DBInstanceClass,Status:DBInstanceStatus,Created:InstanceCreateTime}" --output json | ConvertFrom-Json
if ($rdsJson) {
    foreach ($db in $rdsJson) {
        $out += "  - $($db.Id) ($($db.Engine) / $($db.Class)) | Status: $($db.Status) | Running for: $(Get-AgeString $db.Created)"
    }
} else { $out += "  (None running)" }

# --- 5. LAMBDA FUNCTIONS ---
$out += "`n[5. LAMBDA FUNCTIONS]"
$lambdaJson = aws lambda list-functions --region $Region --query "Functions[].{Name:FunctionName,Runtime:Runtime,Modified:LastModified}" --output json | ConvertFrom-Json
if ($lambdaJson) {
    foreach ($fn in $lambdaJson) {
        $out += "  - $($fn.Name) ($($fn.Runtime)) | Last Modified: $(Get-AgeString $fn.Modified)"
    }
} else { $out += "  (None)" }

# --- 6. S3 BUCKETS (GLOBAL) ---
$out += "`n[6. S3 BUCKETS (ALL REGIONS)]"
$s3Json = aws s3api list-buckets --query "Buckets[].{Name:Name,Created:CreationDate}" --output json | ConvertFrom-Json
if ($s3Json) {
    foreach ($b in $s3Json) {
        $out += "  - $($b.Name) | Age: $(Get-AgeString $b.Created)"
    }
} else { $out += "  (None)" }

# --- 7. DYNAMODB TABLES ---
$out += "`n[7. DYNAMODB TABLES]"
$ddbTables = aws dynamodb list-tables --region $Region --query "TableNames[]" --output json | ConvertFrom-Json
if ($ddbTables) {
    foreach ($t in $ddbTables) {
        $created = aws dynamodb describe-table --table-name $t --region $Region --query "Table.CreationDateTime" --output text
        $out += "  - $t | Age: $(Get-AgeString $created)"
    }
} else { $out += "  (None)" }

# --- 8. VPCs & NAT GATEWAYS ---
$out += "`n[8. VPCs & NAT GATEWAYS]"
$vpcJson = aws ec2 describe-vpcs --region $Region --query "Vpcs[].{Id:VpcId,Name:Tags[?Key=='Name'] | [0].Value,Cidr:CidrBlock,Default:IsDefault}" --output json | ConvertFrom-Json
if ($vpcJson) {
    foreach ($v in $vpcJson) {
        $out += "  - VPC: $($v.Id) | Name: $($v.Name) | CIDR: $($v.Cidr) | DefaultVPC: $($v.Default)"
    }
}
$natJson = aws ec2 describe-nat-gateways --region $Region --filter "Name=state,Values=available,pending" --query "NatGateways[].{Id:NatGatewayId,Created:CreateTime}" --output json | ConvertFrom-Json
if ($natJson) {
    foreach ($n in $natJson) {
        $out += "  - NAT Gateway: $($n.Id) | Running for: $(Get-AgeString $n.Created)"
    }
}

# --- 9. CUSTOM IAM ROLES ---
$out += "`n[9. CUSTOM IAM ROLES]"
$iamJson = aws iam list-roles --query "Roles[?!starts_with(Path, '/aws-service-role/')].{Name:RoleName,Created:CreateDate}" --output json | ConvertFrom-Json
if ($iamJson) {
    foreach ($r in $iamJson) {
        $out += "  - $($r.Name) | Age: $(Get-AgeString $r.Created)"
    }
} else { $out += "  (None)" }

# --- 10. CLOUDWATCH LOG GROUPS ---
$out += "`n[10. CLOUDWATCH LOG GROUPS]"
$logsJson = aws logs describe-log-groups --region $Region --query "logGroups[].{Name:logGroupName,Created:creationTime,Bytes:storedBytes}" --output json | ConvertFrom-Json
if ($logsJson) {
    foreach ($lg in $logsJson) {
        $dt = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$lg.Created).UtcDateTime.ToString("o")
        $sizeMB = [math]::Round($lg.Bytes / 1MB, 2)
        $out += "  - $($lg.Name) ($sizeMB MB) | Age: $(Get-AgeString $dt)"
    }
} else { $out += "  (None)" }

# --- 11. RECENT ACCOUNT ACTIVITY (CLOUDTRAIL LAST 25 EVENTS) ---
$out += "`n[11. RECENT ACCOUNT ACTIVITY (LAST 25 CLOUDTRAIL EVENTS)]"
$trailJson = aws cloudtrail lookup-events --region $Region --max-results 25 --query "Events[].{Time:EventTime,Event:EventName,Source:EventSource,User:Username}" --output json 2>$null | ConvertFrom-Json
if ($trailJson) {
    foreach ($ev in $trailJson) {
        $evTime = [DateTime]::Parse($ev.Time).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
        $user = if ($ev.User) { $ev.User } else { "System/Role" }
        $out += ("  - {0} UTC | {1,-28} | {2,-26} | By: {3}" -f $evTime, $ev.Event, $ev.Source, $user)
    }
} else {
    $out += "  (No recent CloudTrail events found)"
}

$finalReport = $out -join "`n"
Write-Host $finalReport -ForegroundColor White
$finalReport | Out-File -FilePath $ReportFile -Encoding UTF8
Write-Host "`nReport saved to: $(Resolve-Path $ReportFile)" -ForegroundColor Yellow
