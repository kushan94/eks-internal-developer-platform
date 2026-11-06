# Applied once from a laptop. Its own state stays local, because it holds the
# GitHub access keys, so never commit terraform.tfstate from this folder.

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

# The AWS Free plan denies OIDC providers, so GitHub can't use keyless
# federation. These users have access keys instead, stored as GitHub
# environment secrets.

# Runs terraform plan for pull requests. Read-only, plus the state lock file.
resource "aws_iam_user" "github_plan" {
  name = "github-plan"
  path = "/github/"
}

resource "aws_iam_user_policy_attachment" "github_plan" {
  user       = aws_iam_user.github_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_user_policy" "github_plan_lock" {
  name = "terraform-state-lock"
  user = aws_iam_user.github_plan.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.state.arn}/*.tflock"
    }]
  })
}

# Runs terraform apply and destroy, only from GitHub environments that need approval or run on main.
resource "aws_iam_user" "github_apply" {
  name = "github-apply"
  path = "/github/"
}

resource "aws_iam_user_policy_attachment" "github_apply" {
  user       = aws_iam_user.github_apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_access_key" "github_plan" {
  user = aws_iam_user.github_plan.name
}

resource "aws_iam_access_key" "github_apply" {
  user = aws_iam_user.github_apply.name
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "github_plan_access_key_id" {
  value     = aws_iam_access_key.github_plan.id
  sensitive = true
}

output "github_plan_secret_access_key" {
  value     = aws_iam_access_key.github_plan.secret
  sensitive = true
}

output "github_apply_access_key_id" {
  value     = aws_iam_access_key.github_apply.id
  sensitive = true
}

output "github_apply_secret_access_key" {
  value     = aws_iam_access_key.github_apply.secret
  sensitive = true
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
