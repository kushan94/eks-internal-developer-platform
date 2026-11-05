# IAM role that the Crossplane AWS providers assume through EKS Pod Identity.
resource "aws_iam_role" "crossplane" {
  count = var.enable_eks ? 1 : 0
  name  = "${var.cluster_name}-crossplane-aws"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

# Only what the WebService ECS runtime creates: ECS services, task definitions,
# security groups and log groups.
resource "aws_iam_role_policy" "crossplane" {
  count = var.enable_eks ? 1 : 0
  name  = "webservice-ecs-runtime"
  role  = aws_iam_role.crossplane[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EcsServices"
        Effect = "Allow"
        Action = [
          "ecs:CreateService", "ecs:UpdateService", "ecs:DeleteService", "ecs:DescribeServices",
          "ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition", "ecs:DescribeTaskDefinition",
          "ecs:ListTagsForResource", "ecs:TagResource", "ecs:UntagResource",
        ]
        Resource = "*"
      },
      {
        Sid    = "SecurityGroups"
        Effect = "Allow"
        Action = [
          "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
          "ec2:ModifySecurityGroupRules", "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
          "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
          "ec2:CreateTags", "ec2:DeleteTags",
          "ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules", "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeTags",
        ]
        Resource = "*"
      },
      {
        Sid    = "LogGroups"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DescribeLogGroups",
          "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy",
          "logs:ListTagsForResource", "logs:ListTagsLogGroup", "logs:TagResource", "logs:UntagResource",
          "logs:TagLogGroup", "logs:UntagLogGroup",
        ]
        Resource = "*"
      },
      {
        Sid      = "PassTaskExecutionRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.ecs_task_execution.arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "crossplane" {
  count           = var.enable_eks ? 1 : 0
  cluster_name    = module.eks[0].cluster_name
  namespace       = "crossplane-system"
  service_account = "provider-aws"
  role_arn        = aws_iam_role.crossplane[0].arn
}
