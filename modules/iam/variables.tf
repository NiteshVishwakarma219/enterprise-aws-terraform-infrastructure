variable "name_prefix" {
  description = "Prefix used for IAM resource names"
  type        = string
}

variable "uploads_bucket_arn" {
  description = "ARN of the S3 uploads bucket the Lambda function may need to read"
  type        = string
}
