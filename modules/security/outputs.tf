output "alb_security_group_id" {
  description = "Security group ID for the ALB"
  value       = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = "Security group ID for the application tier"
  value       = aws_security_group.app.id
}

output "db_security_group_id" {
  description = "Security group ID for the database tier"
  value       = aws_security_group.db.id
}
