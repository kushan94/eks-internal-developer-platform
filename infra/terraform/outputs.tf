output "cluster_name" {
  value = var.enable_eks ? module.eks[0].cluster_name : null
}

output "configure_kubectl" {
  description = "Command that points kubectl at the EKS cluster."
  value       = var.enable_eks ? "aws eks update-kubeconfig --region ${var.region} --name ${module.eks[0].cluster_name}" : null
}

# Applied to the cluster by `make aws-environment`. It identifies the account, so it is not committed.
output "aws_platform_environment" {
  description = "The aws-platform EnvironmentConfig that the WebService composition reads for the ECS runtime."
  value = yamlencode({
    apiVersion = "apiextensions.crossplane.io/v1beta1"
    kind       = "EnvironmentConfig"
    metadata   = { name = "aws-platform" }
    data = merge(
      {
        aws = {
          region         = var.region
          ecsClusterName = aws_ecs_cluster.this.name
          vpcId          = module.vpc.vpc_id
          vpcCidr        = module.vpc.vpc_cidr_block
          subnetIds      = module.vpc.private_subnets
          # Where the load balancer's traffic to public services comes from.
          publicSubnetCidrs    = module.vpc.public_subnets_cidr_blocks
          taskExecutionRoleArn = aws_iam_role.ecs_task_execution.arn
        }
        # Makes in-cluster databases run three instances across AZs.
        highAvailability = local.high_availability
        # The public domain, kept out of Git. Overrides the placeholder in the
        # platform EnvironmentConfig.
        publicDomain = var.platform_domain
        # Where images under idp-apps/ live. Holds the account ID, so it stays out of Git.
        ecrRegistry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
      },
      # The shared Postgres server for managed databases, which comes with EKS.
      var.enable_eks ? {
        managedPostgres = {
          providerConfigName = "shared-postgres"
          host               = aws_db_instance.shared_postgres[0].address
          port               = aws_db_instance.shared_postgres[0].port
          adminRole          = aws_db_instance.shared_postgres[0].username
        }
      } : {},
    )
  })
}

output "high_availability" {
  description = "Whether the production profile is on. make gitops passes it to the root application."
  value       = local.high_availability
}
