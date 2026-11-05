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
    data = {
      aws = {
        region               = var.region
        ecsClusterArn        = aws_ecs_cluster.this.arn
        vpcId                = module.vpc.vpc_id
        vpcCidr              = module.vpc.vpc_cidr_block
        subnetIds            = module.vpc.private_subnets
        taskExecutionRoleArn = aws_iam_role.ecs_task_execution.arn
      }
    }
  })
}
