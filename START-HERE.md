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

## 6. Access (ALB only — no Route 53 / domain)

The application is served directly by the Application Load Balancer over HTTP.
No Route 53 hosted zone, ACM certificate or custom domain is used.

```bash
terraform output alb_dns_name
terraform output application_url
```

Open the `application_url` (`http://<alb-dns-name>`) in a browser.

## 7. Verify

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
- `docs/TROUBLESHOOTING.md`
- `docs/INTERVIEW_QA.md`
- `diagrams/architecture.md`
