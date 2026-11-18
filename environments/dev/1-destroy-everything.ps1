# ==============================================================================
# FINAL SCRIPT 1: 1-destroy-everything.ps1
# Purpose: Verify internet, release locks, destroy all AWS resources & state
# ==============================================================================

$ErrorActionPreference = "Continue"
$Region = "us-east-1"
$Prefix = "nexops-dev"
$StateBucket = "nexops-terraform-state-920235988251"
$StateKey = "nexops/dev/terraform.tfstate"
$LockTable = "nexops-terraform-locks"

# --- PRE-CHECK: VERIFY INTERNET & AWS CONNECTION ---
Write-Host "`n[0/4] Checking AWS connection..." -ForegroundColor Cyan
$identity = aws sts get-caller-identity --output json 2>$null
if (-not $identity) {
    Write-Host "ERROR: Cannot connect to AWS! Check your Wi-Fi / Internet connection and try again." -ForegroundColor Red
    exit 1
}

# --- STEP 1: RELEASE LOCKS ---
Write-Host "`n[1/4] Releasing any stuck Terraform locks..." -ForegroundColor Cyan
aws s3 rm "s3://$StateBucket/$StateKey.tflock" --region $Region 2>$null
Remove-Item -Force -ErrorAction SilentlyContinue ".terraform.tfstate.lock.info"

$tableExists = aws dynamodb describe-table --table-name $LockTable --region $Region 2>$null
if ($tableExists) {
    $scanJson = aws dynamodb scan --table-name $LockTable --region $Region --output json | ConvertFrom-Json
    foreach ($item in $scanJson.Items) {
        $lockId = $item.LockID.S
        if ($lockId) {
            aws dynamodb delete-item --table-name $LockTable --key "{`"LockID`":{`"S`":`"$lockId`"}}" --region $Region | Out-Null
        }
    }
}

# --- STEP 2: TERRAFORM DESTROY ---
Write-Host "`n[2/4] Running Terraform Destroy..." -ForegroundColor Cyan
terraform init -reconfigure
terraform destroy -lock=false -auto-approve

# --- STEP 3: FORCE CLEAN ANY REMAINING AWS RESOURCES ---
Write-Host "`n[3/4] Force-cleaning all orphaned $Prefix AWS resources..." -ForegroundColor Cyan

# Auto Scaling Groups & Launch Templates
$asgs = aws autoscaling describe-auto-scaling-groups --region $Region --query "AutoScalingGroups[?contains(AutoScalingGroupName, '$Prefix')].AutoScalingGroupName" --output text
foreach ($asg in ($asgs -split "\s+")) {
    if ($asg -and $asg -ne "None") {
        aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $asg --force-delete --region $Region | Out-Null
        Write-Host "  [-] Deleted ASG: $asg"
    }
}
$lts = aws ec2 describe-launch-templates --region $Region --query "LaunchTemplates[?contains(LaunchTemplateName, '$Prefix')].LaunchTemplateName" --output text
foreach ($lt in ($lts -split "\s+")) {
    if ($lt -and $lt -ne "None") { aws ec2 delete-launch-template --launch-template-name $lt --region $Region | Out-Null }
}

# EventBridge Rules & Targets
$rules = aws events list-rules --name-prefix $Prefix --region $Region --query "Rules[].Name" --output text
foreach ($rule in ($rules -split "\s+")) {
    if ($rule -and $rule -ne "None") {
        $targets = aws events list-targets-by-rule --rule $rule --region $Region --query "Targets[].Id" --output text
        if ($targets -and $targets -ne "None") { aws events remove-targets --rule $rule --ids ($targets -split "\s+") --region $Region | Out-Null }
        aws events delete-rule --name $rule --region $Region | Out-Null
    }
}

# Lambda & CloudWatch Logs
$lambdas = aws lambda list-functions --region $Region --query "Functions[?contains(FunctionName, '$Prefix')].FunctionName" --output text
foreach ($fn in ($lambdas -split "\s+")) { if ($fn -and $fn -ne "None") { aws lambda delete-function --function-name $fn --region $Region | Out-Null } }

$logGroups = aws logs describe-log-groups --region $Region --query "logGroups[?contains(logGroupName, '$Prefix')].logGroupName" --output text
foreach ($lg in ($logGroups -split "\s+")) { if ($lg -and $lg -ne "None") { aws logs delete-log-group --log-group-name $lg --region $Region | Out-Null } }

# Load Balancers & Target Groups
$albs = aws elbv2 describe-load-balancers --region $Region --query "LoadBalancers[?contains(LoadBalancerName, '$Prefix')].LoadBalancerArn" --output text
foreach ($alb in ($albs -split "\s+")) { if ($alb -and $alb -ne "None") { aws elbv2 delete-load-balancer --load-balancer-arn $alb --region $Region | Out-Null } }

$tgs = aws elbv2 describe-target-groups --region $Region --query "TargetGroups[?contains(TargetGroupName, '$Prefix')].TargetGroupArn" --output text
foreach ($tg in ($tgs -split "\s+")) { if ($tg -and $tg -ne "None") { aws elbv2 delete-target-group --target-group-arn $tg --region $Region | Out-Null } }

# RDS Instances & Subnet Groups
$dbs = aws rds describe-db-instances --region $Region --query "DBInstances[?contains(DBInstanceIdentifier, '$Prefix')].DBInstanceIdentifier" --output text
foreach ($db in ($dbs -split "\s+")) {
    if ($db -and $db -ne "None") {
        Write-Host "  [-] Deleting RDS Instance: $db (waiting)..." -ForegroundColor Yellow
        aws rds delete-db-instance --db-instance-identifier $db --skip-final-snapshot --delete-automated-backups --region $Region 2>$null | Out-Null
        aws rds wait db-instance-deleted --db-instance-identifier $db --region $Region
    }
}
$subnetGroups = aws rds describe-db-subnet-groups --region $Region --query "DBSubnetGroups[?contains(DBSubnetGroupName, '$Prefix')].DBSubnetGroupName" --output text
foreach ($sg in ($subnetGroups -split "\s+")) { if ($sg -and $sg -ne "None") { aws rds delete-db-subnet-group --db-subnet-group-name $sg --region $Region | Out-Null } }

# NAT Gateways, Elastic IPs & Custom VPCs
$nats = aws ec2 describe-nat-gateways --region $Region --filter "Name=state,Values=available,pending" --query "NatGateways[].NatGatewayId" --output text
foreach ($nat in ($nats -split "\s+")) {
    if ($nat -and $nat -ne "None") {
        aws ec2 delete-nat-gateway --nat-gateway-id $nat --region $Region | Out-Null
        Write-Host "  [-] Deleting NAT Gateway: $nat (waiting 40s)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 40
    }
}
$eips = aws ec2 describe-addresses --region $Region --query "Addresses[?AssociationId==null].AllocationId" --output text
foreach ($eip in ($eips -split "\s+")) { if ($eip -and $eip -ne "None") { aws ec2 release-address --allocation-id $eip --region $Region | Out-Null } }

$vpcs = aws ec2 describe-vpcs --region $Region --filters "Name=tag:Name,Values=*$Prefix*" --query "Vpcs[].VpcId" --output text
foreach ($vpc in ($vpcs -split "\s+")) {
    if ($vpc -and $vpc -ne "None") {
        $enis = aws ec2 describe-network-interfaces --region $Region --filters "Name=vpc-id,Values=$vpc" --query "NetworkInterfaces[].NetworkInterfaceId" --output text
        foreach ($eni in ($enis -split "\s+")) { if ($eni -and $eni -ne "None") { aws ec2 delete-network-interface --network-interface-id $eni --region $Region | Out-Null } }

        $rts = aws ec2 describe-route-tables --region $Region --filters "Name=vpc-id,Values=$vpc" --query "RouteTables[?Associations[0].Main!=``true``]" --output json | ConvertFrom-Json
        foreach ($rt in $rts) {
            foreach ($assoc in $rt.Associations) {
                if ($assoc.RouteTableAssociationId) { aws ec2 disassociate-route-table --association-id $assoc.RouteTableAssociationId --region $Region | Out-Null }
            }
            aws ec2 delete-route-table --route-table-id $rt.RouteTableId --region $Region | Out-Null
        }

        $igws = aws ec2 describe-internet-gateways --region $Region --filters "Name=attachment.vpc-id,Values=$vpc" --query "InternetGateways[].InternetGatewayId" --output text
        foreach ($igw in ($igws -split "\s+")) {
            if ($igw -and $igw -ne "None") {
                aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $vpc --region $Region | Out-Null
                aws ec2 delete-internet-gateway --internet-gateway-id $igw --region $Region | Out-Null
            }
        }
        $subnets = aws ec2 describe-subnets --region $Region --filters "Name=vpc-id,Values=$vpc" --query "Subnets[].SubnetId" --output text
        foreach ($sub in ($subnets -split "\s+")) { if ($sub -and $sub -ne "None") { aws ec2 delete-subnet --subnet-id $sub --region $Region | Out-Null } }
        $sgs = aws ec2 describe-security-groups --region $Region --filters "Name=vpc-id,Values=$vpc" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text
        foreach ($sg in ($sgs -split "\s+")) { if ($sg -and $sg -ne "None") { aws ec2 delete-security-group --group-id $sg --region $Region | Out-Null } }
        aws ec2 delete-vpc --vpc-id $vpc --region $Region | Out-Null
        Write-Host "  [-] Deleted VPC: $vpc"
    }
}


# SNS, S3 & Secrets Manager (including scheduled-for-deletion)
$topics = aws sns list-topics --region $Region --query "Topics[?contains(TopicArn, '$Prefix')].TopicArn" --output text
foreach ($topic in ($topics -split "\s+")) { if ($topic -and $topic -ne "None") { aws sns delete-topic --topic-arn $topic --region $Region | Out-Null } }

$buckets = aws s3api list-buckets --query "Buckets[?contains(Name, '$Prefix') && Name != '$StateBucket'].Name" --output text
foreach ($bucket in ($buckets -split "\s+")) { if ($bucket -and $bucket -ne "None") { aws s3 rb "s3://$bucket" --force | Out-Null } }

$secrets = aws secretsmanager list-secrets --include-planned-deletion --region $Region --query "SecretList[?contains(Name, '$Prefix')].Name" --output text
foreach ($secret in ($secrets -split "\s+")) {
    if ($secret -and $secret -ne "None") {
        aws secretsmanager delete-secret --secret-id $secret --force-delete-without-recovery --region $Region 2>$null | Out-Null
    }
}

# IAM Roles & Policies
$roles = aws iam list-roles --query "Roles[?contains(RoleName, '$Prefix')].RoleName" --output text
foreach ($role in ($roles -split "\s+")) {
    if ($role -and $role -ne "None") {
        $profiles = aws iam list-instance-profiles-for-role --role-name $role --query "InstanceProfiles[].InstanceProfileName" --output text
        foreach ($prof in ($profiles -split "\s+")) {
            if ($prof -and $prof -ne "None") {
                aws iam remove-role-from-instance-profile --instance-profile-name $prof --role-name $role | Out-Null
                aws iam delete-instance-profile --instance-profile-name $prof | Out-Null
            }
        }
        $managed = aws iam list-attached-role-policies --role-name $role --query "AttachedPolicies[].PolicyArn" --output text
        foreach ($arn in ($managed -split "\s+")) { if ($arn -and $arn -ne "None") { aws iam detach-role-policy --role-name $role --policy-arn $arn | Out-Null } }
        $inline = aws iam list-role-policies --role-name $role --query "PolicyNames[]" --output text
        foreach ($pol in ($inline -split "\s+")) { if ($pol -and $pol -ne "None") { aws iam delete-role-policy --role-name $role --policy-name $pol | Out-Null } }
        aws iam delete-role --role-name $role | Out-Null
    }
}
