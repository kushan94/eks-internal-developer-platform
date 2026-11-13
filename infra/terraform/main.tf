data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  high_availability = var.profile == "production"
  azs               = slice(data.aws_availability_zones.available.names, 0, local.high_availability ? 3 : 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.cluster_name
  cidr = "10.42.0.0/16"

  # A /20 per AZ: private from 10.42.0.0, public from 10.42.128.0.
  azs             = local.azs
  private_subnets = [for i, _ in local.azs : cidrsubnet("10.42.0.0/16", 4, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet("10.42.0.0/16", 4, i + 8)]

  # The study profile shares one NAT gateway, so losing its AZ cuts every
  # private subnet off from the internet. Production has one per AZ.
  enable_nat_gateway     = true
  single_nat_gateway     = !local.high_availability
  one_nat_gateway_per_az = local.high_availability

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
    # Prefix delegation gives each network interface /28 prefixes instead of
    # single IPs, so an m7i-flex.large runs 110 pods instead of 29. Managed
    # node groups read it at creation, which before_compute makes sure of.
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        env = { ENABLE_PREFIX_DELEGATION = "true" }
      })
    }
    # The association is part of the add-on, so the driver never starts without AWS access.
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi[0].arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  eks_managed_node_groups = {
    system = {
      ami_type = "AL2023_x86_64_STANDARD"
      # The AWS Free plan denies Spot instances and only allows Free Tier-eligible
      # types. m7i-flex.large is the only eligible type with 8 GiB of memory.
      capacity_type  = "ON_DEMAND"
      instance_types = ["m7i-flex.large"]

      # Production keeps a node in each of its three AZs.
      min_size     = local.high_availability ? 3 : 2
      max_size     = local.high_availability ? 6 : 3
      desired_size = local.high_availability ? 3 : 2
    }
  }
}
