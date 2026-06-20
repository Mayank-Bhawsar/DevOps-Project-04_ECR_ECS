resource "aws_secretsmanager_secret" "app_secrets" {
  name = "devops-04-django-secrets"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app_secrets_val" {
  secret_id = aws_secretsmanager_secret.app_secrets.id
  secret_string = jsonencode({
    DJANGO_SECRET_KEY = "placeholder-insecure-dev-key-change-me-in-console"
  })

  lifecycle {
    ignore_changes = [ secret_string ]
  }
}