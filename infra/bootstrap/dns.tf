# DNS for public service URLs. Route 53 hosts the whole domain, and delegates
# the platform's subdomain to its own zone, so the platform's tools can only
# change records under that subdomain. Both zones live in the bootstrap stack,
# because recreating a zone changes its nameservers and breaks delegation.

variable "parent_domain" {
  description = "Domain registered at the registrar, whose nameservers point at this zone."
  type        = string
}

variable "platform_domain" {
  description = "Subdomain that Route 53 hosts for the platform."
  type        = string
}

resource "aws_route53_zone" "parent" {
  name    = var.parent_domain
  comment = "Domain apex. Set these nameservers at the registrar."
}

resource "aws_route53_record" "platform_delegation" {
  zone_id = aws_route53_zone.parent.zone_id
  name    = var.platform_domain
  type    = "NS"
  ttl     = 3600
  records = aws_route53_zone.platform.name_servers
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
  description = "Nameservers of the platform zone. The parent zone delegates to them."
  value       = aws_route53_zone.platform.name_servers
}

output "parent_domain_nameservers" {
  description = "Set these as the domain's nameservers at the registrar."
  value       = aws_route53_zone.parent.name_servers
}
