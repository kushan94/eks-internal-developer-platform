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

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.allowed_cidrs

  enable_cluster_creator_admin_permissions = true

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
      # The AWS Free plan denies Spot instances.
      capacity_type  = "ON_DEMAND"
      instance_types = ["t3.large"]

      min_size     = 2
      max_size     = 3
      desired_size = 2
    }
  }
}
