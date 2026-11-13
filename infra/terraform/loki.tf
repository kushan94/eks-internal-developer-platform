# IAM role that Loki assumes through EKS Pod Identity, to store logs in the
# bootstrap stack's bucket. It can only use that bucket.
resource "aws_iam_role" "loki" {
  count = var.enable_eks ? 1 : 0
  name  = "${var.cluster_name}-loki"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "loki" {
  count = var.enable_eks ? 1 : 0
  name  = "store-logs"
  role  = aws_iam_role.loki[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::idp-logs-${data.aws_caller_identity.current.account_id}"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::idp-logs-${data.aws_caller_identity.current.account_id}/*"
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "loki" {
  count           = var.enable_eks ? 1 : 0
  cluster_name    = module.eks[0].cluster_name
  namespace       = "monitoring"
  service_account = "loki"
  role_arn        = aws_iam_role.loki[0].arn
}
