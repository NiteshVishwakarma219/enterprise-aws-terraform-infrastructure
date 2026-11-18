# ============================================================
# S3 UPLOADS BUCKET
# ============================================================

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "uploads" {
  # S3 bucket names are globally unique across ALL AWS accounts, so the
  # account ID is appended to avoid BucketAlreadyExists.
  bucket = "${var.name_prefix}-uploads-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.name_prefix}-uploads"
    Tier = "storage"
  }
}


# ============================================================
# VERSIONING
# ============================================================

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  versioning_configuration {
    status = "Enabled"
  }
}


# ============================================================
# SERVER-SIDE ENCRYPTION
# ============================================================

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}


# ============================================================
# BLOCK PUBLIC ACCESS
# ============================================================

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


# ============================================================
# OWNERSHIP
# ============================================================

resource "aws_s3_bucket_ownership_controls" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}