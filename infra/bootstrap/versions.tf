terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "eks-idp"
      ManagedBy = "terraform-bootstrap"
    }
  }
}

variable "region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "eu-north-1"
}
