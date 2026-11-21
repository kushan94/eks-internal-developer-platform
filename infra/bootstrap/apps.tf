# An image registry and a push-only CI user for each application repo that
# apps/*.yaml onboards. The registry outlives the nightly destroy, like
# Backstage's. Adding a file to apps/ and applying the bootstrap stack gives the
# repo its own repository and key, and the key can't push anywhere else.

locals {
  # The repo name is the last part of each file's repoURL, with or without .git.
  app_repos = toset([
    for f in fileset("${path.module}/../../apps", "*.yaml") :
    regex("/([^/]+?)(?:\\.git)?$", yamldecode(file("${path.module}/../../apps/${f}")).repoURL)[0]
  ])
}

resource "aws_ecr_repository" "app" {
  for_each = local.app_repos

  name                 = "idp-apps/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each = local.app_repos

  repository = aws_ecr_repository.app[each.key].name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_iam_user" "app_image_push" {
  for_each = local.app_repos

  name = "github-app-push-${each.key}"
  path = "/github/"
}

resource "aws_iam_user_policy" "app_image_push" {
  for_each = local.app_repos

  name = "push-app-image"
  user = aws_iam_user.app_image_push[each.key].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage",
        ]
        Resource = aws_ecr_repository.app[each.key].arn
      },
    ]
  })
}

resource "aws_iam_access_key" "app_image_push" {
  for_each = local.app_repos

  user = aws_iam_user.app_image_push[each.key].name
}

output "app_repository_urls" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

# Read by scripts/app-repo-setup.sh, which stores each key in its own repo.
output "app_image_push_keys" {
  value = {
    for k, key in aws_iam_access_key.app_image_push : k => {
      access_key_id     = key.id
      secret_access_key = key.secret
    }
  }
  sensitive = true
}
