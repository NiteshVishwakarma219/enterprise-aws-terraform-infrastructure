variable "aws_region" {
  description = "AWS region for the state backend resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name, used to name the state bucket and lock table"
  type        = string
  default     = "nexops"
}
