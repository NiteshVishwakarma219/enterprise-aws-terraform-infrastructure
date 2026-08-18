# Start here

This copy has two changes from the version you were fighting with:

1. **`environments/dev/providers.tf`** now has adaptive AWS SDK retries
   (`retry_mode = "adaptive"`, `max_retries = 15`), so single short network
   blips are absorbed automatically instead of failing the whole run.
2. **`ops/deploy.ps1`** and **`ops/destroy.ps1`** — one-command wrappers that:
   - Check DNS is actually stable (5 passes) before starting anything
   - Auto-retry `apply`/`destroy` up to a few times if something transient
     fails (both are safe to re-run — Terraform only touches what's left)
   - Auto-clear a stuck state lock if one is detected

**Important, read once:** no script can make a broken home Wi-Fi connection
never drop mid-operation. If your network genuinely dies for a sustained
period, deploy.ps1/destroy.ps1 will retry a few times and then stop and tell
you to look at the last error — that's intentional, not a bug in the script.
For anything you actually depend on working every single time, run it from
WSL2 or a cloud shell instead of native Windows Wi-Fi.

## First time only — permissions

Confirm the IAM policy from `ops/all-permissions-combined.json` is attached
to whichever IAM user you deploy with:
```powershell
aws iam list-attached-user-policies --user-name <your-username>
```

## Deploy

```powershell
cd enterprise-aws-terraform-infrastructure-2
.\ops\deploy.ps1
```

## Destroy

```powershell
.\ops\destroy.ps1
```
It will ask you to type `DESTROY` to confirm before it touches anything.

## If a run genuinely fails after all retries

Read the last error block the script prints. Don't just re-run it over and
over — that's what produced the tangled state you had before. Bring the
exact error back and fix that one thing.
