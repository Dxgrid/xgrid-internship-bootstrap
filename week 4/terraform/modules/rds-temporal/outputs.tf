output "rds_endpoint" {
  description = "RDS instance hostname (address only, without port)."
  value       = aws_db_instance.temporal.address
}

output "rds_port" {
  description = "RDS instance port (default PostgreSQL: 5432)."
  value       = aws_db_instance.temporal.port
}

output "rds_identifier" {
  description = "Identifier (name) of the RDS instance."
  value       = aws_db_instance.temporal.identifier
}

output "rds_arn" {
  description = "ARN of the RDS instance."
  value       = aws_db_instance.temporal.arn
}

output "rds_endpoint_with_port" {
  description = "RDS endpoint with port in format host:port."
  value       = "${aws_db_instance.temporal.address}:${aws_db_instance.temporal.port}"
}
