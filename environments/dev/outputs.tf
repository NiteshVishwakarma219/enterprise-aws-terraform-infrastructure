output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer - open this in a browser"
  value       = module.compute.alb_dns_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "uploads_bucket_name" {
  description = "S3 uploads bucket name"
  value       = module.storage.bucket_name
}

output "db_endpoint" {
  description = "RDS connection endpoint"
  value       = module.database.db_endpoint
  sensitive   = true
}

output "database_secret_name" {
  description = "Secrets Manager secret holding DB credentials"
  value       = module.database.database_secret_name
}

output "autoscaling_group_name" {
  description = "Auto Scaling Group name"
  value       = module.compute.autoscaling_group_name
}

output "sns_alerts_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms"
  value       = module.monitoring.sns_topic_arn
}

output "application_url" {
  description = "HTTPS application URL when a custom domain is enabled; otherwise null."
  value       = module.route53.application_url
}

output "route53_name_servers" {
  description = "Route 53 authoritative name servers to set at GoDaddy."
  value       = module.route53.name_servers
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN used by the HTTPS listener."
  value       = module.route53.certificate_arn
  sensitive   = true
}

output "demo_admin_email" {
  description = "Demo administrator email."
  value       = "admin@nexops.com"
}

output "demo_admin_password" {
  description = "Generated demo administrator password stored in Secrets Manager."
  value       = module.database.demo_admin_password
  sensitive   = true
}
