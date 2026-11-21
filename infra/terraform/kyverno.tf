# Lets Kyverno read image signatures from the platform's private ECR
# repositories (idp-apps/*), which is how the signed-images policy checks images
# built in application repos. It can read those repositories and nothing else.
resource "aws_iam_role" "kyverno" {
  count              = var.enable_eks ? 1 : 0
  name               = "${var.cluster_name}-kyverno"
  assume_role_policy = local.pod_identity_trust
}

resource "aws_iam_role_policy" "kyverno" {
  count = var.enable_eks ? 1 : 0
  name  = "read-app-images"
  role  = aws_iam_role.kyverno[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability",
          # Signatures made with cosign v3 are stored as referrers of the image.
          "ecr:ListImageReferrers", "ecr:DescribeImages",
        ]
        Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/idp-apps/*"
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "kyverno" {
  count           = var.enable_eks ? 1 : 0
  cluster_name    = module.eks[0].cluster_name
  namespace       = "kyverno"
  service_account = "kyverno-admission-controller"
  role_arn        = aws_iam_role.kyverno[0].arn
}
