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
