# DNS for public service URLs. Route 53 hosts only the platform's subdomain;
# the parent zone delegates it with NS records. Kept in the bootstrap stack
# because recreating the zone would change its nameservers and break the delegation.

variable "platform_domain" {
  description = "Subdomain that Route 53 hosts for the platform."
  type        = string
  default     = "idp.skyforgelab.cloud"
}

resource "aws_route53_zone" "platform" {
  name    = var.platform_domain
  comment = "Public URLs for the internal developer platform"
}

# One wildcard certificate for every service. The load balancer controller
# finds it by hostname, so its ARN never has to be committed.
resource "aws_acm_certificate" "platform" {
  domain_name               = "*.${var.platform_domain}"
  subject_alternative_names = [var.platform_domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# ACM validates the certificate automatically once these records resolve,
# which needs the parent zone's delegation to be in place.
# Keyed by domain name, which is known before the certificate exists. The
# wildcard and the bare domain share one validation record, hence allow_overwrite.
resource "aws_route53_record" "certificate_validation" {
  for_each = {
    for o in aws_acm_certificate.platform.domain_validation_options : o.domain_name => o
  }

  zone_id         = aws_route53_zone.platform.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

output "platform_domain_nameservers" {
  description = "Add these as NS records for the platform domain in the parent zone."
  value       = aws_route53_zone.platform.name_servers
}
