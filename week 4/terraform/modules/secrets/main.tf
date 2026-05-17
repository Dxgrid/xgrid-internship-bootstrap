# Secrets Manager for Temporal PostgreSQL Database Credentials
# Pattern adapted from Week 3 WordPress implementation, customized for PostgreSQL

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Customer Managed Key (CMK) for Secrets Manager encryption
# ViaService condition restricts usage to Secrets Manager only (no EFS in Week 4)
resource "aws_kms_key" "secrets" {
  description             = "CMK for ${var.project_name}-${var.environment} Temporal Secrets Manager"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootAccountFullAdmin"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowSecretsManagerUsage"
        Effect = "Allow"
        Principal = {
          Service = "secretsmanager.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-${var.environment}-temporal-cmk"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.project_name}-${var.environment}-temporal-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# Secrets Manager secret for Temporal database credentials
resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project_name}/${var.environment}/temporal-db-credentials"
  description             = "Temporal PostgreSQL database credentials (auto-managed by Terraform)"
  kms_key_id              = aws_kms_key.secrets.id
  recovery_window_in_days = 0  # Demo: instant deletion. Set to 7-30 in production.

  tags = {
    Name        = "${var.project_name}-${var.environment}-temporal-db-secret"
    Project     = var.project_name
    Environment = var.environment
    Application = "temporal"
    ManagedBy   = "Terraform"
  }
}

# Secret version containing the actual credentials
# AWS automatically labels this as AWSCURRENT
resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    dbname   = "temporal"
    host     = var.rds_endpoint
    port     = "5432"
  })
}
