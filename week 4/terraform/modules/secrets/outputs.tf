output "secret_arn" {
  description = "ARN of the Temporal database credentials secret in Secrets Manager."
  value       = aws_secretsmanager_secret.db.arn
}

output "secret_name" {
  description = "Name of the Temporal database credentials secret."
  value       = aws_secretsmanager_secret.db.name
}


output "kms_key_id" {
  description = "KMS key ID used for encrypting the secret."
  value       = aws_kms_key.secrets.id
}

output "kms_key_arn" {
  description = "KMS key ARN used for encrypting the secret."
  value       = aws_kms_key.secrets.arn
}
