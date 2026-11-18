output "launch_template_id" {
  description = "Launch Template ID"
  value       = aws_launch_template.app.id
}

output "autoscaling_group_name" {
  description = "Auto Scaling Group name"
  value       = aws_autoscaling_group.app.name
}

output "alb_dns_name" {
  description = "Application Load Balancer DNS name"
  value       = aws_lb.app.dns_name
}

output "alb_zone_id" {
  description = "Application Load Balancer hosted zone ID"
  value       = aws_lb.app.zone_id
}

output "alb_arn" {
  description = "Application Load Balancer ARN"
  value       = aws_lb.app.arn
}

output "target_group_arn" {
  description = "Target group ARN"
  value       = aws_lb_target_group.app.arn
}

output "alb_full_name" {
  value = aws_lb.app.arn_suffix
}

output "target_group_full_name" {
  value = aws_lb_target_group.app.arn_suffix
}

output "ec2_role_name" {
  description = "IAM role name attached to app instances"
  value       = aws_iam_role.ec2.name
}
