# How the ALB, Auto Scaling Group, and CloudWatch actually work together

A plain-language walkthrough of the moving parts behind `modules/compute` and
`modules/monitoring` — written so you can explain this confidently in an interview, not
just point at the Terraform.

## The three pieces and what each one actually does

**Application Load Balancer (ALB)** — the single, stable entry point. It has one DNS name
(`alb_dns_name`) that never changes, even as the instances behind it come and go. Its only
jobs: accept incoming connections, and forward each request to a *healthy* instance.

**Target Group** — the ALB's address book. It's a list of instances (targets), each
tagged `healthy` or `unhealthy` based on a periodic health check (in this project: an HTTP
GET to `/`, every 30 seconds, expecting a `200-399` response). The ALB only ever routes to
targets marked `healthy` — an unhealthy target still exists in the group, it's just
skipped.

**Auto Scaling Group (ASG)** — the thing that actually owns the EC2 instances. It doesn't
know anything about HTTP — it just keeps a target *count* of instances running (bounded by
`min_size` / `max_size`, aiming for `desired_capacity`), launches new ones from the Launch
Template when it's short, and terminates ones that fail health checks.

## Why "minimum 2 instances" matters

With `asg_min_size = 1`, a single bad deploy or a single AZ outage takes the whole site
down — there's no second instance to absorb traffic while the first is being replaced.
With `min_size = 2` (spread across two AZs, as this VPC is), you get:
- **Zero-downtime deploys**: an instance refresh replaces one instance at a time, and the
  ALB keeps serving from the survivor the whole time.
- **AZ fault tolerance**: if `us-east-1a` has a problem, the instance in `us-east-1b` keeps
  serving traffic while the ASG replaces the failed one.

This project's `environments/dev/variables.tf` defaults `asg_desired_capacity = 2` for
exactly this reason — that value drifting to 1 (as happened during the incident above) is
a resilience regression, not just a number changing.

## The self-healing loop, end to end

```
1. ASG launches an instance from the Launch Template (runs user_data.sh.tpl)
2. Instance registers itself with the Target Group automatically (ASG does this)
3. Target Group starts health-checking it: GET / every 30s
4. If it fails 3 consecutive checks -> marked unhealthy
5. ASG (health_check_type = "ELB") sees the unhealthy status and terminates the instance
6. ASG immediately launches a replacement to get back to desired_capacity
7. New instance repeats from step 1
```

This loop is *exactly* what happened during the incident: the frontend's crash-loop bug
made every instance permanently fail its health check, so the ASG kept replacing
instances forever — each one launching broken, in a cycle — until the actual bug in
`user_data.sh.tpl` was fixed and rolled out via `terraform apply` + a manual instance
refresh. **This is also why live-patching a single running instance with SSM was never a
real fix** — the ASG has no idea a human hand-fixed something inside a container; the next
health-check-driven replacement (or the instance refresh you trigger) throws that manual
fix away and boots fresh from `user_data.sh.tpl` again.

## Instance Refresh — how a deploy actually rolls out

`aws autoscaling start-instance-refresh` doesn't touch running instances directly. It:
1. Terminates one instance (respecting `min_healthy_percentage` — 90% here, so it won't
   drop below roughly 1-of-2 instances serving at a time)
2. Launches a replacement from the **current** Launch Template version
3. Waits for the `instance_warmup` period (120s here) before considering it "settled"
4. Moves to the next instance, repeats

This is why changing `user_data.sh.tpl` alone does nothing to running instances — it only
changes what *future* instances boot with. `terraform apply` creates a new Launch Template
*version*; the instance refresh is the separate step that actually rolls it out.

## CloudWatch + SNS — how you'd actually find out about any of this without watching manually

`modules/monitoring` wires up alarms so you don't have to be actively checking:
- **`asg-high-cpu`**: average CPU > 80% for 3 consecutive minutes → could mean traffic
  spike or a runaway process
- **`alb-5xx`**: more than 10 server errors in a minute → the kind of app-level bug this
  whole incident was
- **`alb-unhealthy-hosts`**: any target unhealthy for 2 consecutive checks → would have
  fired repeatedly throughout this incident, and is the single most useful alarm for
  exactly what happened here
- **`rds-high-cpu`** / **`rds-low-storage`**: database-side pressure

Every alarm publishes to one SNS topic (`nexops-dev-alerts`), which emails
`alert_email`. In a real incident, `alb-unhealthy-hosts` firing repeatedly (as it would
have, every single time an instance crash-looped) is the signal that tells you *when* to
start investigating — rather than finding out from a user reporting a broken page, the way
this incident actually unfolded.

## The honest gap right now

Alarms exist, but nothing currently *acts* on them beyond sending an email — there's no
auto-rollback, no Lambda remediation, no PagerDuty integration. For a portfolio project
that's a fine, honest stopping point; for real production you'd typically add at least a
CloudWatch Alarm → Auto Scaling *scaling policy* connection for the failure cases where an
automated response makes sense (this project's `aws_autoscaling_policy.cpu` already does
this for scale-out on CPU, but not for the unhealthy-host case that actually bit us here).
