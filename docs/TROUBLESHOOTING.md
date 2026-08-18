# Troubleshooting

**See [`INCIDENT_POSTMORTEM.md`](INCIDENT_POSTMORTEM.md) first** — it documents every real
bug hit deploying this project the first time (frontend crash-loops, missing JWT secret,
missing DB migrations/seed data, ASG capacity drift), with exact root causes and fixes.
The entries below are the general/hypothetical version of the same categories, useful if
you hit a variant that isn't an exact match.

## `terraform init` fails on the backend

You likely haven't run `bootstrap/state-backend` yet, or `environments/dev/backend.tf`
still has the placeholder account ID. See DEPLOYMENT_GUIDE.md step 1-2.

## ALB shows 502/503, or targets never go healthy

- Check the target group health check status in the AWS console (EC2 → Target Groups).
- SSH isn't available (no key pair is provisioned) — use **SSM Session Manager** instead:
  `aws ssm start-session --target <instance-id>`
- Once connected, check bootstrap logs:
  `cat /var/log/nexops-bootstrap.log`
  `docker ps` (should show `nexops-backend` and `nexops-frontend` running)
  `systemctl status nginx`
- A common cause: the instance role couldn't reach Secrets Manager (check the
  `database_secret_arn` wiring in `modules/compute` matches the actual secret).

## `terraform apply` fails creating the RDS instance

- Check `db_engine_version` in `modules/database/variables.tf` is still a version AWS
  supports for PostgreSQL in your region (AWS periodically deprecates old minor versions).
- Confirm your account's default VPC service quotas allow another RDS instance.

## No email alarm notifications arriving

SNS email subscriptions require manual confirmation. Check the inbox (and spam folder) for
`alert_email` for an "AWS Notification - Subscription Confirmation" email and click Confirm.

## Lambda `archive_file` errors during plan

Make sure `modules/lambda/src/index.py` exists — `terraform plan` zips it on the fly. If
you deleted or renamed it, the `archive_file` data source has nothing to package.

## State lock stuck / "Error acquiring the state lock"

Someone's `apply`/`plan` was interrupted. If you're sure no one else is running Terraform:

```bash
terraform force-unlock <LOCK_ID>
```

(The lock ID is printed in the error message.)
