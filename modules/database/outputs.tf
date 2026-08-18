output "db_instance_id" {
  description = "RDS instance identifier"
  value       = aws_db_instance.main.id
}

output "db_endpoint" {
  description = "RDS connection endpoint (host:port)"
  value       = aws_db_instance.main.endpoint
}

output "db_address" {
  description = "RDS hostname (no port)"
  value       = aws_db_instance.main.address
}

output "database_secret_name" {
  description = "Secrets Manager secret name holding DB credentials"
  value       = aws_secretsmanager_secret.db.name
}

output "database_secret_arn" {
  description = "Secrets Manager secret ARN holding DB credentials"
  value       = aws_secretsmanager_secret.db.arn
}

output "demo_admin_password" {
  description = "Generated demo administrator password. Sensitive."
  value       = random_password.admin_demo.result
  sensitive   = true
}
