output "secret_arn" {
  description = "ARN of the Secrets Manager secret."
  value       = aws_secretsmanager_secret.db.arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret."
  value       = aws_secretsmanager_secret.db.name
}

output "db_username" {
  description = "Database username."
  value       = var.db_username
}

output "db_name" {
  description = "Database name."
  value       = var.db_name
}

output "db_password" {
  description = "Database password (sensitive)."
  value       = random_password.db.result
  sensitive   = true
}

output "kms_key_arn" {
  description = "ARN of the CMK used for secret encryption."
  value       = aws_kms_key.secrets.arn
}

output "kms_key_id" {
  description = "ID of the CMK used for secret encryption."
  value       = aws_kms_key.secrets.id
}