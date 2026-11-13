# IAM role that External Secrets Operator assumes through EKS Pod Identity.
# It can only read secrets under idp/argocd/, idp/backstage/, idp/platform/,
# idp/grafana/ and idp/alerting/.
resource "aws_iam_role" "external_secrets" {
  count = var.enable_eks ? 1 : 0
  name  = "${var.cluster_name}-external-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "external_secrets" {
  count = var.enable_eks ? 1 : 0
  name  = "read-argocd-secrets"
  role  = aws_iam_role.external_secrets[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetResourcePolicy",
        "secretsmanager:ListSecretVersionIds",
      ]
      Resource = [
        "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:idp/argocd/*",
        "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:idp/backstage/*",
        "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:idp/platform/*",
        "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:idp/grafana/*",
        "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:idp/alerting/*",
      ]
    }]
  })
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  count           = var.enable_eks ? 1 : 0
  cluster_name    = module.eks[0].cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets[0].arn
}
