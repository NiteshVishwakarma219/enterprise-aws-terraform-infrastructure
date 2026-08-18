variable "name_prefix" {
  description = "Prefix used for security group names"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "app_port" {
  description = "Port the application (nginx) listens on, targeted by the ALB"
  type        = number
  default     = 80
}

variable "db_port" {
  description = "Database port"
  type        = number
  default     = 5432
}
