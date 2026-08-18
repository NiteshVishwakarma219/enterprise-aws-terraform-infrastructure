# Interview Q&A — talking through this project

**Q: Walk me through the architecture.**
A three-tier VPC (public / private-app / private-db) across two AZs. An ALB in the public
subnets fans out to an Auto Scaling Group of EC2 instances in the private app subnets,
running Dockerized frontend + backend containers behind Nginx. RDS PostgreSQL sits in
private DB subnets, reachable only from the app tier's security group. S3 holds user
uploads. Secrets Manager holds DB credentials, read by the EC2 instance role at boot — no
credentials are baked into the AMI or user data. A scheduled Lambda handles housekeeping,
and CloudWatch alarms feed an SNS topic for email alerting.

**Q: Why S3 remote state + DynamoDB locking instead of local state?**
Local state doesn't scale past one operator and risks state loss. S3 gives durable,
versioned storage; DynamoDB provides locking so two people (or CI + a person) can't apply
concurrently and corrupt state.

**Q: Why a bootstrap stack separate from the main environment?**
Chicken-and-egg problem: the S3 bucket/DynamoDB table *for* remote state can't itself live
in that remote state before it exists. So it's created once, locally, then referenced by
every other stack's backend config.

**Q: How do EC2 instances get database credentials without them being hardcoded?**
The instance's IAM role is scoped to `secretsmanager:GetSecretValue` on exactly one secret
ARN (the DB credentials secret created by `modules/database`). `user_data.sh.tpl` calls the
AWS CLI at boot to fetch and inject them as environment variables into the backend container.

**Q: Why no SSH key pair on the instances?**
Access goes through AWS Systems Manager Session Manager instead (the instance role has
`AmazonSSMManagedInstanceCore` attached). No open port 22, no key management, and every
session is logged in CloudTrail.

**Q: How would you scale this to a second environment (staging/prod)?**
Duplicate `environments/dev` as `environments/staging`, change the backend `key` and
`terraform.tfvars`, adjust sizing variables (`asg_*`, `db_instance_class`, `multi_az`).
The modules themselves don't change — that's the point of factoring them out.

**Q: What's the single biggest gap for production-readiness as it stands?**
No HTTPS/TLS on the ALB listener (only port 80) and no WAF — for a real production
front door you'd add an ACM certificate, an HTTPS listener with an HTTP→HTTPS redirect,
and consider AWS WAF in front of the ALB.


## Route 53 / ACM

**Q: How does the custom GoDaddy domain reach the application?**

A: GoDaddy is used as the registrar. The domain's nameservers are delegated to an authoritative Route 53 hosted zone. Route 53 points the hostname to the ALB using an alias record. ACM performs DNS validation and provides the TLS certificate to the ALB. Port 80 redirects to HTTPS on port 443.

**Q: Why is the application not exposed directly from EC2?**

A: EC2 instances live in private application subnets and accept application traffic only from the ALB security group. The public ALB is the only internet-facing entry point.
