# GitHub OAuth app that Grafana uses for sign-in on EKS. JSON with clientId
# and clientSecret. Terraform only creates the secret; you store the value
# with the CLI, so it never enters Terraform state.
resource "aws_secretsmanager_secret" "grafana_github_oauth" {
  name                    = "idp/grafana/github-oauth"
  description             = "GitHub OAuth app for Grafana sign-in."
  recovery_window_in_days = 7
}

output "grafana_github_oauth_secret" {
  value = aws_secretsmanager_secret.grafana_github_oauth.name
}
