output "zone_id" {
  value       = try(aws_route53_zone.this[0].zone_id, null)
  description = "Route 53 hosted zone ID."
}

output "name_servers" {
  value       = try(aws_route53_zone.this[0].name_servers, [])
  description = "Name servers to configure at GoDaddy when Route 53 is authoritative."
}

output "certificate_arn" {
  value       = try(aws_acm_certificate_validation.this[0].certificate_arn, null)
  description = "ACM certificate ARN."
}

output "application_url" {
  value       = var.enabled ? "https://${var.domain_name}" : null
  description = "Application HTTPS URL."
}
