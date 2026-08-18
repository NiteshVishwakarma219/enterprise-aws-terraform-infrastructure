output "lambda_function_name" {
  description = "Name of the housekeeping Lambda function"
  value       = aws_lambda_function.housekeeping.function_name
}

output "lambda_function_arn" {
  description = "ARN of the housekeeping Lambda function"
  value       = aws_lambda_function.housekeeping.arn
}
