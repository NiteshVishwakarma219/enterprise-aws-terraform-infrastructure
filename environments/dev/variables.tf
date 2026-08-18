variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name, used as a naming prefix everywhere"
  type        = string
  default     = "nexops"
}

variable "environment" {
  description = "Environment name (dev / staging / prod)"
  type        = string
  default     = "dev"
}

variable "alert_email" {
  description = "Email address to receive CloudWatch alarm notifications"
  type        = string
}

# --------------------------------------------------------------
# Networking
# --------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread subnets across"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "app_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "db_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.21.0/24", "10.0.22.0/24"]
}

# --------------------------------------------------------------
# DNS / HTTPS
# --------------------------------------------------------------

variable "route53_zone_name" {
  description = "Route 53 hosted zone name, normally your purchased GoDaddy domain (e.g. nitesh.shop)"
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Public application hostname. Leave empty to use the ALB DNS name without HTTPS."
  type        = string
  default     = ""
}

# --------------------------------------------------------------
# Compute
# --------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type for the app fleet"
  type        = string
  default     = "t3.micro"
}

variable "asg_min_size" {
  type    = number
  default = 1
}

variable "asg_max_size" {
  type    = number
  default = 3
}

variable "asg_desired_capacity" {
  type    = number
  default = 2
}

variable "backend_image" {
  description = "Backend Docker image"
  type        = string
}

variable "frontend_image" {
  description = "Frontend Docker image"
  type        = string
}

# --------------------------------------------------------------
# Database
# --------------------------------------------------------------

variable "db_name" {
  description = "Initial database name"
  type        = string
}

variable "db_username" {
  description = "Master username for the database"
  type        = string
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "multi_az" {
  description = "Deploy RDS as Multi-AZ (leave false for dev to save cost)"
  type        = bool
  default     = false
}
