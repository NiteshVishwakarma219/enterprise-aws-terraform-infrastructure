# ============================================================
# LAMBDA TRUST POLICY
# ============================================================

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

# ============================================================
# LAMBDA EXECUTION ROLE
# ============================================================

resource "aws_iam_role" "lambda" {
  name               = "${var.name_prefix}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name = "${var.name_prefix}-lambda-role"
  }
}

# ============================================================
# BASIC CLOUDWATCH LOGS PERMISSIONS
# ============================================================

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ============================================================
# READ-ONLY ACCESS TO THE UPLOADS BUCKET
# ============================================================

data "aws_iam_policy_document" "lambda_s3_read" {
  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:ListBucket"
    ]

    resources = [
      var.uploads_bucket_arn,
      "${var.uploads_bucket_arn}/*"
    ]
  }
}

resource "aws_iam_policy" "lambda_s3_read" {
  name   = "${var.name_prefix}-lambda-s3-read"
  policy = data.aws_iam_policy_document.lambda_s3_read.json
}

resource "aws_iam_role_policy_attachment" "lambda_s3_read" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda_s3_read.arn
}
