output "rds_endpoint" {
  description = "RDS instance hostname (address only, without port). Passed to secrets module to complete the JSON secret with {username, password, dbname, host, port}."
  value       = aws_db_instance.wordpress.address
}

output "rds_port" {
  description = "RDS instance port (default MySQL: 3306)."
  value       = aws_db_instance.wordpress.port
}

output "rds_arn" {
  description = "ARN of the RDS instance. Used for IAM policies, CloudWatch alarms, and audit logging."
  value       = aws_db_instance.wordpress.arn
}

output "rds_identifier" {
  description = "Identifier (name) of the RDS instance. Used for CloudWatch alarm dimensions and AWS CLI commands."
  value       = aws_db_instance.wordpress.identifier
}
