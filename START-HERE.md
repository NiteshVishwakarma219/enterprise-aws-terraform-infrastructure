# Start Here

This is the fixed AWS Project 1 package for the EEMS Docker release `1.0.0`.

## 1. Enter the project

```bash
cd enterprise-aws-terraform-infrastructure
```

## 2. Configure AWS CLI

```bash
aws sts get-caller-identity
```

## 3. Create remote state

```bash
cd bootstrap/state-backend
terraform init
terraform validate
terraform plan
terraform apply
terraform output state_bucket_name
```

## 4. Configure the main environment

```bash
cd ../../environments/dev
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`.

## 5. Initialize remote state

```bash
terraform init -backend-config="bucket=<STATE_BUCKET_NAME>"
```

## 6. If you already own a GoDaddy domain

Set:

```hcl
route53_zone_name = "yourdomain.com"
domain_name       = "yourdomain.com"
```

Then create the Route 53 hosted zone first:

```bash
terraform apply -target=module.route53.aws_route53_zone.this[0]
terraform output route53_name_servers
```

Set those nameservers at GoDaddy.

After delegation:

```bash
terraform apply
```

## 7. If you do not own a domain yet

Leave:

```hcl
route53_zone_name = ""
domain_name       = ""
```

Deploy normally and use:

```bash
terraform output alb_dns_name
```

## 8. Verify

```bash
terraform validate
terraform plan
terraform apply
terraform output alb_dns_name
terraform output application_url
```

See:

- `docs/DEPLOYMENT_GUIDE.md`
- `docs/FIXES_APPLIED.md`
- `docs/GODADDY_ROUTE53_SETUP.md`
- `docs/TROUBLESHOOTING.md`
- `docs/INTERVIEW_QA.md`
- `diagrams/architecture.md`
