output "efs_id" {
  description = "EFS file system ID backing the Prometheus TSDB."
  value       = aws_efs_file_system.monitoring.id
}

output "prometheus_service_name" {
  description = "ECS service name for Prometheus."
  value       = aws_ecs_service.prometheus.name
}

output "grafana_service_name" {
  description = "ECS service name for Grafana."
  value       = aws_ecs_service.grafana.name
}

output "prometheus_dns_name" {
  description = "Cloud Map FQDN where Prometheus is reachable inside the VPC."
  value       = "prometheus.${var.cloudmap_namespace_name}"
}

output "node_exporter_service_name" {
  description = "ECS daemon service name for Node Exporter."
  value       = aws_ecs_service.node_exporter.name
}
