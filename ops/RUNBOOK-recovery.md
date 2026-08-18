# Recovery Runbook

## What actually happened (root causes)

1. **Windows DNS dropped mid-`destroy`.** Not a Terraform bug. Your `terraform
   destroy` was running fine, then partway through (after ~7 minutes) the
   `ec2.us-east-1.amazonaws.com` and `nexops-terraform-state-...s3...`
   hostnames stopped resolving. Terraform failed to (a) finish deleting the
   IGW/subnet and (b) write the updated state back to S3. That's why you got
   `errored.tfstate` and a stuck lock.

2. **`errored.tfstate` is your most important file right now — do not delete
   it.** It has `serial: 13`, 72 tracked resources, and is the *last known
   good snapshot* before the network dropped. The remote state in S3 is
   older/stale by comparison. Deleting it (as a generic "reset" checklist
   might tell you to) throws away the only accurate record of what Terraform
   still thinks exists.

3. **`AuthFailure` disassociating the EIP is a real permission gap**, not a
   network issue. This repo's `modules/iam` only creates an execution role
   *for the Lambda function* — it grants nothing to the IAM user/role you run
   `terraform`/`aws` as from PowerShell. That identity needs its own policy.
   See `ops/deployer-iam-policy.json`.

4. **`HostedZoneNotEmpty`** happens because `terraform destroy` tries to
   delete the Route53 zone before/while other records still sit in it (the
   ACM validation CNAME, and possibly the `aws_route53_record.application`
   record at root level, which failed to be removed because of the same DNS
   drop). This is destroy-ordering + the same interrupted run, not a config
   bug.

5. **Unused DynamoDB table.** `bootstrap/state-backend` creates a DynamoDB
   lock table (`nexops-terraform-locks`), but `environments/dev/backend.tf`
   uses S3's newer native locking (`use_lockfile = true`) instead of
   `dynamodb_table = ...`. Both mechanisms work, but you were paying for /
   maintaining a table that's never referenced. Pick one — see options below.

6. **Stray local files removed in this copy:** `modules/terraform.tfstate`
   (an empty state accidentally created by running `terraform` directly
   inside `modules/`) and the `.terraform/` cache dirs. Neither should be
   committed; both are now covered by `.gitignore` and were deleted here.

## Fix your network path first (don't skip this)

DNS server changes alone often don't stick through a 7+ minute apply on
Windows Wi-Fi because of adapter power-saving, VPN/antivirus DNS filtering,
or IPv6 fallback. Before touching AWS again:

- Run PowerShell **as Administrator**, then:
  ```powershell
  netsh winsock reset
  netsh int ip reset
  ipconfig /flushdns
  Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi" -ServerAddresses ("1.1.1.1","8.8.8.8")
  ```
  Reboot.
- Disable Wi-Fi adapter power management: Device Manager → your adapter →
  Power Management → uncheck "Allow the computer to turn off this device".
- If you're on a VPN or have antivirus with "web/DNS protection", temporarily
  disable it for the test.
- **Best fix:** run `terraform` from WSL2 (Ubuntu) instead of native
  PowerShell, or from an EC2 instance / CloudShell in the same region. This
  removes your home network as a variable entirely for a 5-15 minute apply.
- Confirm stability, not just resolution — run this 10 times in a row with no
  failures before trusting it:
  ```powershell
  for ($i=0; $i -lt 10; $i++) { Resolve-DnsName ec2.us-east-1.amazonaws.com; Start-Sleep 2 }
  ```

## Safe recovery sequence (in order)

1. **Attach `ops/deployer-iam-policy.json` to the IAM user/role you deploy
   with.** Without this, destroy/apply will keep failing on EIP, and
   possibly other actions, regardless of DNS.

   ```powershell
   aws iam put-user-policy `
     --user-name <your-iam-username> `
     --policy-name nexops-terraform-deployer `
     --policy-document file://ops/deployer-iam-policy.json
   ```

2. **Reconcile state — push the errored state, don't delete it:**
   ```powershell
   cd environments\dev
   terraform init -reconfigure
   terraform state push errored.tfstate
   ```
   If it complains about serial/lineage mismatch, that means someone/something
   already wrote a newer state remotely — stop and compare before forcing.

3. **Check for a stuck lock and clear only if truly orphaned:**
   ```powershell
   terraform force-unlock <LOCK_ID_FROM_ERROR>
   ```

4. **Refresh against real AWS to see what's actually still there** (this does
   not delete anything):
   ```powershell
   terraform plan -refresh-only
   ```
   Read this output carefully — it tells you which of the 72 resources are
   still live vs. already gone.

5. **Now run destroy again**, on a verified-stable connection:
   ```powershell
   terraform destroy -auto-approve
   ```
   If it fails again on Route53 `HostedZoneNotEmpty`, list and remove leftover
   records first (never delete NS/SOA):
   ```powershell
   aws route53 list-resource-record-sets --hosted-zone-id <ZONE_ID>
   ```
   then delete only the extra `A`/`CNAME` records via
   `aws route53 change-resource-record-sets`, and re-run destroy.

6. Once `terraform state list` is empty and the manual `aws ec2/elbv2/rds`
   checks come back empty, you're at a true clean slate. Then:
   ```powershell
   terraform init -reconfigure
   terraform plan -out=tfplan
   terraform apply tfplan
   ```

## Locking mechanism — pick one, don't run both long-term

- **Keep S3 native locking (current setup, recommended, no extra AWS
  resource to manage):** leave `backend.tf` as-is
  (`use_lockfile = true`), and delete the now-unused
  `aws_dynamodb_table.lock` resource from
  `bootstrap/state-backend/main.tf`.
- **Or switch to DynamoDB locking (more mature tooling/console visibility):**
  in `environments/dev/backend.tf` replace `use_lockfile = true` with
  `dynamodb_table = "nexops-terraform-locks"`, keep the DynamoDB resource in
  bootstrap.

Either is fine technically — the lock failures you hit were caused by the
network drop, not by which locking mechanism was chosen.
