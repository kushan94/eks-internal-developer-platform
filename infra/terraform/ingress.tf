# IAM for public URLs: the AWS Load Balancer Controller creates ALBs from
# Gateway API resources, and ExternalDNS publishes route hostnames in Route 53.

variable "platform_domain" {
  description = "Route 53 zone for public service URLs, created by the bootstrap stack."
  type        = string

  validation {
    condition     = length(var.platform_domain) > 0
    error_message = "Set platform_domain (TF_VAR_platform_domain, or terraform.tfvars). The workflows read it from the IDP_DOMAIN repository variable."
  }
}

data "aws_route53_zone" "platform" {
  count = var.enable_eks ? 1 : 0
  name  = var.platform_domain
}

locals {
  pod_identity_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role" "load_balancer_controller" {
  count              = var.enable_eks ? 1 : 0
  name               = "${var.cluster_name}-aws-load-balancer-controller"
  assume_role_policy = local.pod_identity_trust
}

# The controller's published policy for v3.6.2, pinned with the chart version.
resource "aws_iam_role_policy" "load_balancer_controller" {
  count  = var.enable_eks ? 1 : 0
  name   = "aws-load-balancer-controller"
  role   = aws_iam_role.load_balancer_controller[0].id
  policy = file("${path.module}/policies/aws-load-balancer-controller-v3.6.2.json")
}

resource "aws_eks_pod_identity_association" "load_balancer_controller" {
  count           = var.enable_eks ? 1 : 0
  cluster_name    = module.eks[0].cluster_name
  namespace       = "aws-load-balancer-controller"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.load_balancer_controller[0].arn
}

resource "aws_iam_role" "external_dns" {
  count              = var.enable_eks ? 1 : 0
  name               = "${var.cluster_name}-external-dns"
  assume_role_policy = local.pod_identity_trust
}

# Only the platform zone can be changed.
resource "aws_iam_role_policy" "external_dns" {
  count = var.enable_eks ? 1 : 0
  name  = "platform-zone-records"
  role  = aws_iam_role.external_dns[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = data.aws_route53_zone.platform[0].arn
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResources"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "external_dns" {
  count           = var.enable_eks ? 1 : 0
  cluster_name    = module.eks[0].cluster_name
  namespace       = "external-dns"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns[0].arn
}
