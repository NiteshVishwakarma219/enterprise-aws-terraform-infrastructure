variable "name_prefix" {
  description = "Prefix used for compute resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "app_subnet_ids" {
  description = "Private application subnet IDs"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the Application Load Balancer"
  type        = list(string)
}

variable "app_security_group_id" {
  description = "Application security group ID"
  type        = string
}

variable "alb_security_group_id" {
  description = "Security group ID for the ALB"
  type        = string
}

variable "backend_image" {
  description = "Backend Docker image"
  type        = string
}

variable "frontend_image" {
  description = "Frontend Docker image"
  type        = string
}

variable "database_secret_name" {
  description = "Secrets Manager database secret name"
  type        = string
}

variable "database_secret_arn" {
  description = "Secrets Manager database secret ARN"
  type        = string
}

variable "uploads_bucket_arn" {
  description = "ARN of the S3 uploads bucket"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the app fleet"
  type        = string
  default     = "t3.micro"
}

variable "asg_min_size" {
  description = "Minimum number of instances in the Auto Scaling Group"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of instances in the Auto Scaling Group"
  type        = number
  default     = 3
}

variable "asg_desired_capacity" {
  description = "Desired number of instances in the Auto Scaling Group"
  type        = number
  default     = 2
}

variable "health_check_path" {
  description = "Path the ALB health check requests"
  type        = string
  default     = "/api/health"
}

variable "https_enabled" {
  description = "Whether to create an HTTPS listener and redirect HTTP to HTTPS."
  type        = bool
  default     = false
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for HTTPS. Required when https_enabled is true."
  type        = string
  default     = null
}
