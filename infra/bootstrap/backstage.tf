# Persistent pieces for running Backstage in the cluster: its image registry,
# a CI user that can only push to it, and the secret for its GitHub App.

resource "aws_ecr_repository" "backstage" {
  name                 = "idp/backstage"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "backstage" {
  repository = aws_ecr_repository.backstage.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# GitHub Actions pushes Backstage images with this user. It can't do anything else.
resource "aws_iam_user" "github_image_push" {
  name = "github-image-push"
  path = "/github/"
}

resource "aws_iam_user_policy" "github_image_push" {
  name = "push-backstage-image"
  user = aws_iam_user.github_image_push.name
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
        Resource = aws_ecr_repository.backstage.arn
      },
    ]
  })
}

resource "aws_iam_access_key" "github_image_push" {
  user = aws_iam_user.github_image_push.name
}

# GitHub App that Backstage uses for sign-in and to open pull requests. JSON
# with appId, clientId, clientSecret, privateKey and webhookSecret, stored with the CLI.
resource "aws_secretsmanager_secret" "backstage_github_app" {
  name                    = "idp/backstage/github-app"
  description             = "GitHub App for Backstage sign-in and pull requests."
  recovery_window_in_days = 7
}

output "backstage_repository_url" {
  value = aws_ecr_repository.backstage.repository_url
}

output "github_image_push_access_key_id" {
  value     = aws_iam_access_key.github_image_push.id
  sensitive = true
}

output "github_image_push_secret_access_key" {
  value     = aws_iam_access_key.github_image_push.secret
  sensitive = true
}
