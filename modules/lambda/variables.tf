variable "name_prefix" {
  description = "Prefix used for Lambda resource names"
  type        = string
}

variable "lambda_role_arn" {
  description = "IAM role ARN the Lambda function assumes"
  type        = string
}

variable "uploads_bucket_name" {
  description = "S3 uploads bucket name, passed to the function as an env var"
  type        = string
}

variable "schedule_expression" {
  description = "EventBridge schedule expression that triggers the function"
  type        = string
  default     = "rate(1 day)"
}
