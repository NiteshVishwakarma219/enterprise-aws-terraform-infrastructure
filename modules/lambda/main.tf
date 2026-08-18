# ============================================================
# PACKAGE THE FUNCTION SOURCE
# ============================================================

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/lambda.zip"
}

# ============================================================
# LAMBDA FUNCTION
# ============================================================

resource "aws_lambda_function" "housekeeping" {
  function_name = "${var.name_prefix}-housekeeping"
  role          = var.lambda_role_arn

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  handler = "index.handler"
  runtime = "python3.12"
  timeout = 30

  environment {
    variables = {
      UPLOADS_BUCKET = var.uploads_bucket_name
    }
  }

  tags = {
    Name = "${var.name_prefix}-housekeeping"
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${aws_lambda_function.housekeeping.function_name}"
  retention_in_days = 14
}

# ============================================================
# EVENTBRIDGE SCHEDULE TRIGGER
# ============================================================

resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "${var.name_prefix}-housekeeping-schedule"
  schedule_expression = var.schedule_expression
}

resource "aws_cloudwatch_event_target" "schedule" {
  rule = aws_cloudwatch_event_rule.schedule.name
  arn  = aws_lambda_function.housekeeping.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.housekeeping.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}
