# Enterprise AWS Architecture

```text
                              Internet
                                  │
                                  ▼
                    ┌─────────────────────────┐
                    │ Application Load        │
                    │ Balancer :80 (HTTP)     │
                    │ via ALB DNS name        │
                    └────────────┬────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │                         │
             Public subnet AZ-a        Public subnet AZ-b
                    │                         │
                    └────────────┬────────────┘
                                 ▼
              ┌─────────────────────────────────────┐
              │ Auto Scaling Group                  │
              │ Private application subnets        │
              │                                     │
              │ EC2 instance                        │
              │ ├─ Nginx :80                        │
              │ ├─ EEMS frontend container :3000    │
              │ └─ EEMS backend container :8000     │
              └───────────────┬─────────────────────┘
                              │
             ┌────────────────┼────────────────┐
             │                │                │
             ▼                ▼                ▼
       RDS PostgreSQL     S3 uploads     Secrets Manager
       private DB         private        DB + JWT + demo
       subnets             encrypted     credentials
             │
             ▼
       Multi-AZ-ready RDS

CloudWatch → SNS → Email
EventBridge → Lambda → S3 housekeeping
SSM Session Manager → EC2 administration
```

## Network layout

| Tier | Subnets | Access |
|---|---|---|
| Public | 2, one per AZ | ALB, Internet Gateway |
| Application | 2, one per AZ | ALB → EC2 only; outbound via NAT |
| Database | 2, one per AZ | App security group → RDS only |

## Request flow

1. User opens the ALB DNS name (`terraform output application_url`).
2. ALB forwards traffic on port 80 to healthy EC2 instances.
3. Host Nginx forwards `/` to the EEMS frontend container and `/api/`/`/uploads/` to the backend.
4. Backend connects privately to RDS using credentials retrieved from Secrets Manager.
5. Application file operations use the private S3 bucket through the EC2 IAM role.

## Deployment artifact

The EC2 instances pull the frozen EEMS release from Docker Hub:

```text
cloudwithnitesh/nexops-frontend:1.0.0
cloudwithnitesh/nexops-backend:1.0.0
```

The AWS project does not duplicate the application source code.
