# Incoming webhook that Alertmanager posts alerts to on EKS: JSON with url, a
# Slack webhook or a Discord webhook ending in /slack. Terraform only creates
# the secret; you store the value with the CLI, so it never enters Terraform
# state.
resource "aws_secretsmanager_secret" "alerting_webhook" {
  name                    = "idp/alerting/webhook"
  description             = "Chat webhook for Alertmanager."
  recovery_window_in_days = 7
}

output "alerting_webhook_secret" {
  value = aws_secretsmanager_secret.alerting_webhook.name
}
