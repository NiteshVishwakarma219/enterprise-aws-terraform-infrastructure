output "sns_topic_arn" {
  description = "SNS topic ARN used for alarm notifications"
  value       = aws_sns_topic.alerts.arn
}
