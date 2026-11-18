variable "name_prefix" {
  description = "Prefix used for monitoring resource names"
  type        = string
}

variable "alert_email" {
  description = "Email address to receive CloudWatch alarm notifications"
  type        = string
}

variable "autoscaling_group_name" {
  description = "Auto Scaling Group name to monitor"
  type        = string
}

variable "alb_full_name" {
  description = "ALB arn_suffix, used for CloudWatch metric dimensions"
  type        = string
}

variable "target_group_full_name" {
  description = "Target group arn_suffix, used for CloudWatch metric dimensions"
  type        = string
}

variable "db_instance_id" {
  description = "RDS instance identifier to monitor"
  type        = string
}
