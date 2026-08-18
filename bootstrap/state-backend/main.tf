# ============================================================
# This stack has NO remote backend of its own (chicken-and-egg
# problem: it creates the backend other stacks will use).
# Run this once, manually, before anything else:
#
#   cd bootstrap/state-backend
#   terraform init
#   terraform apply
#
# Then use the bucket_name / dynamodb_table_name outputs to
# fill in environments/dev/backend.tf
# ============================================================

data "aws_caller_identity" "current" {}

# ------------------------------------------------------------
# S3 bucket to store terraform state
# ------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = "${var.project_name}-terraform-state-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.project_name}-terraform-state"
  }

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------
# DynamoDB table for state locking
# ------------------------------------------------------------

resource "aws_dynamodb_table" "lock" {
  name         = "${var.project_name}-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name = "${var.project_name}-terraform-locks"
  }
}
