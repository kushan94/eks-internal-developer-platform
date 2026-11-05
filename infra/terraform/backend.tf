# The bucket is passed at init time, because its name includes the account ID:
#   terraform init -backend-config="bucket=<state bucket>"
terraform {
  backend "s3" {
    key          = "eks-idp/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }
}
