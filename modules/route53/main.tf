resource "aws_route53_zone" "this" {
  count = var.enabled ? 1 : 0

  name = var.zone_name

  tags = {
    Name = var.zone_name
  }
}

resource "aws_acm_certificate" "this" {
  count = var.enabled ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.domain_name}-certificate"
  }
}

resource "aws_route53_record" "certificate_validation" {
  count = var.enabled ? 1 : 0

  zone_id = aws_route53_zone.this[0].zone_id

  name = tolist(
    aws_acm_certificate.this[0].domain_validation_options
  )[0].resource_record_name

  type = tolist(
    aws_acm_certificate.this[0].domain_validation_options
  )[0].resource_record_type

  records = [
    tolist(
      aws_acm_certificate.this[0].domain_validation_options
    )[0].resource_record_value
  ]

  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = var.enabled ? 1 : 0

  certificate_arn = aws_acm_certificate.this[0].arn

  validation_record_fqdns = [
    aws_route53_record.certificate_validation[0].fqdn
  ]
}