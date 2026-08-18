# GoDaddy → Route 53 → ACM Setup

Assume the purchased domain is:

```text
nitesh.shop
```

## 1. Configure Terraform

In `environments/dev/terraform.tfvars`:

```hcl
route53_zone_name = "nitesh.shop"
domain_name       = "nitesh.shop"
```

## 2. Create only the Route 53 hosted zone

This is intentionally a two-phase process because Route 53 must become authoritative before ACM DNS validation can succeed.

```bash
terraform apply -target=module.route53.aws_route53_zone.this[0]
```

## 3. Get Route 53 nameservers

```bash
terraform output route53_name_servers
```

You will receive four nameservers similar to:

```text
ns-123.awsdns-45.com
ns-678.awsdns-90.net
ns-111.awsdns-22.org
ns-222.awsdns-33.co.uk
```

Use the actual values Terraform returns.

## 4. Change nameservers at GoDaddy

In GoDaddy:

```text
Domain
→ DNS / Manage DNS
→ Nameservers
→ Change
→ Enter my own nameservers
```

Enter all Route 53 nameservers.

Do not add an application A record in GoDaddy after delegation. Route 53 will manage the application DNS record.

## 5. Important if you use email

If the domain already has email, copy its existing MX/TXT/CNAME records into the Route 53 hosted zone before or immediately after nameserver delegation. Nameserver delegation moves DNS authority from GoDaddy to Route 53.

## 6. Deploy the complete stack

After DNS delegation has propagated:

```bash
terraform apply
```

Terraform will:

1. Create ACM certificate.
2. Create ACM DNS validation record in Route 53.
3. Wait for certificate validation.
4. Create HTTPS ALB listener.
5. Create HTTP → HTTPS redirect.
6. Create Route 53 ALIAS record to the ALB.

## 7. Get the application URL

```bash
terraform output application_url
```

Expected:

```text
https://nitesh.shop
```

## 8. Verify

Open the URL in a browser and confirm:

- HTTPS certificate is valid.
- HTTP redirects to HTTPS.
- Login works.
- API requests succeed.
- Employee/department/leave pages load.
- Uploads work.
