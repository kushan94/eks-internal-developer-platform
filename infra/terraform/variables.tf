variable "region" {
  description = "AWS region to deploy into."
  type        = string
}

variable "allowed_cidrs" {
  description = "CIDR ranges allowed to reach the public Kubernetes API endpoint, such as your own IP as a /32."
  type        = list(string)
}

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
  default     = "idp"
}

variable "kubernetes_version" {
  description = "Kubernetes minor version."
  type        = string
  default     = "1.36"
}

variable "enable_eks" {
  description = "Create the EKS cluster. It costs about $0.27 an hour with its nodes, so it is off unless a session needs it."
  type        = bool
  default     = false
}

variable "cluster_admin_arns" {
  description = "IAM role or user ARNs that get cluster admin access and administer the EKS KMS key, such as the role you use with aws login."
  type        = list(string)

  validation {
    condition     = length(var.cluster_admin_arns) > 0
    error_message = "Name at least one cluster admin."
  }
}

variable "github_repository" {
  description = "Repository the VPC runner registers with, as owner/name."
  type        = string
  default     = "kushan94/eks-internal-developer-platform"
}

variable "profile" {
  description = <<-EOT
    study: two AZs, one NAT gateway, two nodes and single-AZ databases, for
    cheap sessions. production: three AZs, a NAT gateway and a node in each,
    Multi-AZ RDS, and more replicas of platform components and in-cluster
    databases, for about twice the hourly cost.
  EOT
  type        = string
  default     = "study"

  validation {
    condition     = contains(["study", "production"], var.profile)
    error_message = "profile must be study or production."
  }
}
