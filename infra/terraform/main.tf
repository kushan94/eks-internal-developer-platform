data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.cluster_name
  cidr = "10.42.0.0/16"

  azs             = local.azs
  private_subnets = ["10.42.0.0/20", "10.42.16.0/20"]
  public_subnets  = ["10.42.128.0/20", "10.42.144.0/20"]

  # One NAT gateway keeps this cheap, but is not highly available.
  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = var.cluster_name
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"
  count   = var.enable_eks ? 1 : 0

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.allowed_cidrs

  # Name the admins explicitly. Granting admin to whoever runs Terraform would
  # lock you out when the pipeline applies, and change access on every run.
  enable_cluster_creator_admin_permissions = false
  kms_key_administrators                   = var.cluster_admin_arns
  access_entries = merge(
    {
      for i, arn in var.cluster_admin_arns : "admin-${i}" => {
        principal_arn = arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
    {
      # The VPC runner installs Argo CD and the cluster bootstrap.
      github-runner = {
        principal_arn = aws_iam_role.runner[0].arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
  )

  # The runner reaches the API through the private endpoint.
  security_group_additional_rules = {
    github_runner = {
      description              = "Kubernetes API from the VPC GitHub runner"
      from_port                = 443
      to_port                  = 443
      source_security_group_id = aws_security_group.runner[0].id
    }
  }

  # Pod Identity replaces IRSA, and the AWS Free plan denies creating OIDC providers.
  enable_irsa = false

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = {
    coredns                = {}
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
  }

  eks_managed_node_groups = {
    system = {
      ami_type = "AL2023_x86_64_STANDARD"
      # The AWS Free plan denies Spot instances and only allows Free Tier-eligible
      # types. m7i-flex.large is the only eligible type with 8 GiB of memory.
      capacity_type  = "ON_DEMAND"
      instance_types = ["m7i-flex.large"]

      min_size     = 2
      max_size     = 3
      desired_size = 2
    }
  }
}
