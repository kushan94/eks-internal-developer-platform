# Applied once from a laptop. Its own state stays local and holds account
# details, so never commit terraform.tfstate from this folder.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "state" {
  bucket = "idp-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Policies shared by the CI roles in github-oidc.tf.
locals {
  state_lock_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.state.arn}/*.tflock"
    }]
  })

  # Terraform reads secret values to refresh the secrets it writes itself,
  # such as database logins. The plan identity can already read those values
  # in the state, so this adds no access, and it can't read any other secret.
  terraform_secrets_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "secretsmanager:GetSecretValue"
      Resource = [
        "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:idp/backstage/database-*",
        "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:idp/platform/shared-postgres-*",
      ]
    }]
  })
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

# Credentials for the Argo CD GitHub App. Terraform only creates the secret;
# you put the value in with the AWS CLI, so the private key never enters
# Terraform state. It lives here because this stack survives the nightly destroy.
resource "aws_secretsmanager_secret" "argocd_github_app" {
  name                    = "idp/argocd/github-app"
  description             = "GitHub App that Argo CD uses to read repositories. JSON with appId, installationId and privateKey."
  recovery_window_in_days = 7
}

output "argocd_github_app_secret" {
  value = aws_secretsmanager_secret.argocd_github_app.name
}

# GitHub App that the VPC runner uses to register itself with this repo.
# Same pattern: Terraform creates the secret, you store the value with the CLI.
resource "aws_secretsmanager_secret" "runner_github_app" {
  name                    = "idp/github/runner-app"
  description             = "GitHub App the VPC runner uses to get a registration token. JSON with appId, installationId and privateKey."
  recovery_window_in_days = 7
}

output "runner_github_app_secret" {
  value = aws_secretsmanager_secret.runner_github_app.name
}
