output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "Command that points kubectl at this cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
