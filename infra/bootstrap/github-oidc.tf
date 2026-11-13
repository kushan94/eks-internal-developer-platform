# GitHub Actions signs in to AWS with short-lived credentials through OIDC.
# Each role trusts only the GitHub environments that use it, so a workflow
# can only get the plan, apply or image push role by running in that
# environment, which carries its own branch and approval rules.

variable "github_repo" {
  description = "GitHub repository whose workflows may assume the CI roles, as owner/name."
  type        = string
  default     = "kushan94/eks-internal-developer-platform"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  github_roles = {
    plan       = ["aws-plan"]
    apply      = ["aws-apply", "aws-destroy"]
    image-push = ["aws-build"]
  }
}

data "aws_iam_policy_document" "github_trust" {
  for_each = local.github_roles

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for env in each.value : "repo:${var.github_repo}:environment:${env}"]
    }
  }
}

resource "aws_iam_role" "github" {
  for_each = local.github_roles

  name               = "github-${each.key}"
  path               = "/github/"
  assume_role_policy = data.aws_iam_policy_document.github_trust[each.key].json
}

# Same permissions as the IAM users they replace.
resource "aws_iam_role_policy_attachment" "github_plan" {
  role       = aws_iam_role.github["plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "github_plan_lock" {
  name   = "terraform-state-lock"
  role   = aws_iam_role.github["plan"].name
  policy = local.state_lock_policy
}

resource "aws_iam_role_policy" "github_plan_terraform_secrets" {
  name   = "read-terraform-secrets"
  role   = aws_iam_role.github["plan"].name
  policy = local.terraform_secrets_policy
}

resource "aws_iam_role_policy_attachment" "github_apply" {
  role       = aws_iam_role.github["apply"].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy" "github_image_push" {
  name   = "push-backstage-image"
  role   = aws_iam_role.github["image-push"].name
  policy = local.image_push_policy
}

output "github_plan_role_arn" {
  value = aws_iam_role.github["plan"].arn
}

output "github_apply_role_arn" {
  value = aws_iam_role.github["apply"].arn
}

output "github_image_push_role_arn" {
  value = aws_iam_role.github["image-push"].arn
}
