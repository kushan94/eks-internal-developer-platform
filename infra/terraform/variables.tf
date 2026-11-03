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
