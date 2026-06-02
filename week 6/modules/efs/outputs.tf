output "efs_id" {
  description = "EFS file system ID — passed to Prometheus and Grafana ECS task definitions for volume configuration."
  value       = aws_efs_file_system.main.id
}

output "efs_arn" {
  description = "EFS file system ARN — referenced in IAM policies that need file-system-level access."
  value       = aws_efs_file_system.main.arn
}

output "efs_dns_name" {
  description = "EFS DNS name — used in mount commands and runbook examples."
  value       = aws_efs_file_system.main.dns_name
}

output "prometheus_access_point_id" {
  description = "EFS access point ID for Prometheus TSDB data — passed to the Prometheus ECS task definition volume configuration."
  value       = aws_efs_access_point.prometheus.id
}

output "prometheus_access_point_arn" {
  description = "EFS access point ARN for Prometheus — used in the EFS resource policy ALLOW statement."
  value       = aws_efs_access_point.prometheus.arn
}

output "grafana_access_point_id" {
  description = "EFS access point ID for Grafana persistent data — passed to the Grafana ECS task definition volume configuration."
  value       = aws_efs_access_point.grafana.id
}

output "grafana_access_point_arn" {
  description = "EFS access point ARN for Grafana — used in the EFS resource policy ALLOW statement."
  value       = aws_efs_access_point.grafana.arn
}
