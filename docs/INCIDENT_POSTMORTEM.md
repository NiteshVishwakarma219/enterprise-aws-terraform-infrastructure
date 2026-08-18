# Incident Postmortem — First Deployment

This documents every real bug hit bringing this stack up for the first time, in the order
found, what actually caused each one, and exactly where the permanent fix lives. Kept as a
portfolio artifact — this kind of writeup is standard practice after any real production
incident.

## Timeline of issues

### 1. `https://` gave a connection error
**Symptom:** browsing `https://<alb-dns>/` failed to connect at all.
**Cause:** the ALB only has an HTTP (port 80) listener — no port 443 listener exists, since
no ACM certificate/domain was provisioned. Not a bug, a missing feature.
**Fix:** use `http://` for now. A real HTTPS listener + ACM cert + Route 53 record is a
known follow-up (see `INTERVIEW_QA.md`).

### 2. `502 Bad Gateway` from nginx
**Symptom:** plain `http://` loaded, but nginx returned 502.
**Root cause:** the frontend container's own nginx config (baked into the Docker image at
build time, in the app repo) proxies API calls to a hostname literally called `backend`.
But `user_data.sh.tpl` ran the backend container as `--name nexops-backend` with no
network alias — Docker's embedded DNS had no record for the plain name `backend`, so
nginx failed to even start, and kept crash-looping.
**Where it actually lives:** the *requirement* for a host named `backend` comes from the
**app repo** (`frontend/nginx.conf`). The **fix** belongs in the **infra repo**, which
controls what the container is actually named on the network.
**Permanent fix:** `modules/compute/templates/user_data.sh.tpl` starts the backend
container with `--network-alias backend`, satisfying what the frontend image expects.

### 3. `500 Internal Server Error` on login — `P2021: table does not exist`
**Symptom:** site loaded fine, but any login attempt 500'd.
**Root cause:** the app repo never had Prisma migrations committed (`prisma/migrations/`
was empty) — a brand-new RDS database has no tables at all until something creates them.
**Where it lives:** entirely an **app repo** gap.
**Fix applied:** `user_data.sh.tpl` runs `prisma db push --accept-data-loss` on every boot
as a stopgap, which creates any missing tables from `schema.prisma` directly.
**Real fix still needed:** commit actual Prisma migrations to the app repo and switch this
to the safer `prisma migrate deploy` (see "Remaining app-repo work" below).

### 4. `401 Unauthorized` on login with documented demo credentials
**Symptom:** table existed now, but the demo accounts didn't.
**Root cause:** no seed script existed in the app repo (`prisma.seed` was never configured
in `package.json`), so the documented demo accounts (admin/HR/manager/employee) were never
actually inserted anywhere.
**Fix applied:** `user_data.sh.tpl` runs an inline, idempotent (`upsert`-based) Node script
on every boot that ensures all four demo accounts exist with correctly bcrypt-hashed
passwords.
**Real fix still needed:** a committed `prisma/seed.js` in the app repo (see below).

### 5. `500 Internal Server Error` again — `secretOrPrivateKey must have a value`
**Symptom:** password check passed (progress!), but token generation crashed.
**Root cause:** `JWT_SECRET` was never generated anywhere or passed to the backend
container — pure infra gap, nothing wrong in the app code.
**Fix applied:** `modules/database/main.tf` generates a `random_password.jwt` and stores
it in the same Secrets Manager secret as the DB credentials; `user_data.sh.tpl` retrieves
and passes it as `JWT_SECRET`.

### 6. (Found during review, not user-visible yet) DB password contained unsafe URI characters
**Root cause:** `random_password.db`'s `override_special` included characters like `: { } ( ) >`
that are not valid unencoded inside a URI's userinfo section. It happened to work because
Prisma's parser was lenient, but was one dependency update away from breaking.
**Fix applied:** narrowed `override_special` to `-_.~` — the RFC 3986 "unreserved" set,
always safe unencoded in a URL.

### 7. (Found during review) `terraform apply` was one edit away from breaking entirely
**Root cause:** `user_data.sh.tpl` mixes two templating languages — Terraform's own
`${...}` interpolation and bash's `${VAR}` variable expansion. Every bash-native `${VAR}`
needs to be written as `$${VAR}` so Terraform's `templatefile()` doesn't try to resolve it
as an undefined Terraform variable and fail the apply. (Bare `$VAR` without braces is fine
either way — Terraform's interpolation syntax only triggers on `${...}`.)
**Fix applied:** every braced bash variable reference in the script is correctly
double-dollar-escaped.

### 8. ASG showing 1 instance instead of 2
**Root cause:** live AWS state had drifted from the Terraform-declared `asg_desired_capacity
= 2` (most likely from a direct `set-desired-capacity` call or console edit at some point,
or from the ASG's own health-check-driven termination/replacement cycle temporarily
settling at a smaller count mid-incident).
**Fix:** none needed in code — `asg_desired_capacity` already defaults to `2` in
`environments/dev/variables.tf`. Running `terraform apply` reliably re-asserts the desired
count each time, which is exactly the point of infrastructure-as-code: **drift
self-corrects on the next apply.**

## Remaining app-repo work (not yet done)

Two of the fixes above are workarounds living in the infra repo, compensating for gaps in
`enterprise-employee-management-system`. To close this properly:

1. Generate and commit real migrations:
   ```bash
   npx prisma migrate dev --name init
   git add prisma/migrations/
   ```
2. Add a committed seed script + `package.json` entry:
   ```json
   "prisma": { "seed": "node prisma/seed.js" }
   ```
3. Once both are baked into the built image, swap `user_data.sh.tpl`'s `db push
   --accept-data-loss` for `prisma migrate deploy`, and the inline seed script for
   `prisma db seed` — removing the riskier stopgaps now that the real thing exists.

## What this incident demonstrates (for interviews)

- Reading application logs (`docker logs`) to trace an error back through the stack:
  nginx → Docker networking → Prisma → Secrets Manager → JWT signing.
- Diagnosing via AWS-native tools (target group health, ASG instance refresh status, SSM
  Session Manager) instead of guessing.
- Distinguishing infra-layer bugs from application-layer bugs, and fixing each in the repo
  that actually owns it — not patching everything in one place because it's convenient.
- Recognizing self-healing infrastructure behavior (ASG replacing an unhealthy instance)
  versus a real bug, and confirming rather than assuming.
- Applying live, temporary fixes via SSM to restore service quickly, then separately
  pushing the durable fix through Terraform + an instance refresh — the correct order of
  operations under a real incident (stop the bleeding, then fix the root cause).
