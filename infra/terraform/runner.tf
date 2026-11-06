# A GitHub Actions runner inside the VPC, so the cluster workflow reaches the
# private EKS endpoint. It exists only alongside EKS and is destroyed with it.

locals {
  runner_version = "2.338.2"
  runner_sha256  = "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40"
  # Matches the bootstrap stack's bucket name.
  state_bucket = "idp-tfstate-${data.aws_caller_identity.current.account_id}"
}

data "aws_ssm_parameter" "al2023" {
  count = var.enable_eks ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "runner" {
  count       = var.enable_eks ? 1 : 0
  name        = "${var.cluster_name}-github-runner"
  description = "GitHub Actions runner. No inbound access; debug through SSM."
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "runner" {
  count             = var.enable_eks ? 1 : 0
  security_group_id = aws_security_group.runner[0].id
  description       = "GitHub, package downloads and AWS APIs, through the NAT gateway"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_iam_role" "runner" {
  count = var.enable_eks ? 1 : 0
  name  = "${var.cluster_name}-github-runner"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "runner_ssm" {
  count      = var.enable_eks ? 1 : 0
  role       = aws_iam_role.runner[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "runner" {
  count = var.enable_eks ? 1 : 0
  name  = "cluster-setup"
  role  = aws_iam_role.runner[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RunnerAppKey"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:idp/github/runner-app-*"
      },
      {
        Sid      = "Kubeconfig"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = module.eks[0].cluster_arn
      },
      {
        # Read Terraform outputs, such as the aws-platform EnvironmentConfig.
        Sid      = "ReadState"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetObject"]
        Resource = ["arn:aws:s3:::${local.state_bucket}", "arn:aws:s3:::${local.state_bucket}/*"]
      },
    ]
  })
}

resource "aws_iam_instance_profile" "runner" {
  count = var.enable_eks ? 1 : 0
  name  = "${var.cluster_name}-github-runner"
  role  = aws_iam_role.runner[0].name
}

resource "aws_instance" "runner" {
  count = var.enable_eks ? 1 : 0

  ami                    = data.aws_ssm_parameter.al2023[0].value
  instance_type          = "t3.small" # Free Tier-eligible
  subnet_id              = module.vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.runner[0].id]
  iam_instance_profile   = aws_iam_instance_profile.runner[0].name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  user_data = templatefile("${path.module}/runner-userdata.sh.tftpl", {
    region         = var.region
    repository     = var.github_repository
    runner_version = local.runner_version
    runner_sha256  = local.runner_sha256
  })
  user_data_replace_on_change = true

  tags = {
    Name = "${var.cluster_name}-github-runner"
  }

  # Register only once the cluster and its admin access exist.
  depends_on = [module.eks]
}
