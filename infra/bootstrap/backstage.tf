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

# The policy for the github-image-push role in github-oidc.tf.
locals {
  image_push_policy = jsonencode({
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

