output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "alb_temporal_dns_name" {
  description = "DNS name of the Temporal ALB."
  value       = module.alb_temporal.alb_dns_name
}

output "api_url" {
  description = "URL to access the FastAPI Order Management service."
  value       = "http://${module.alb_temporal.alb_dns_name}:8000"
}

output "grafana_url" {
  description = "URL to access Grafana (monitoring UI)."
  value       = "http://${module.alb_temporal.alb_dns_name}"
}

output "grafana_admin_password" {
  description = "Generated Grafana admin password (user: admin)."
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "temporal_ui_url" {
  description = "URL to access the Temporal Web UI."
  value       = "http://${module.alb_temporal.alb_dns_name}:8080"
}

output "api_ecr_repository_url" {
  description = "URL of the API ECR repository for pushing images."
  value       = module.ecr.api_repository_url
}

output "worker_ecr_repository_url" {
  description = "URL of the Worker ECR repository for pushing images."
  value       = module.ecr.worker_repository_url
}

output "temporal_rds_endpoint" {
  description = "Endpoint of the Temporal RDS PostgreSQL instance."
  value       = module.rds_temporal.rds_endpoint
}

output "temporal_rds_port" {
  description = "Port of the Temporal RDS instance (default: 5432)."
  value       = module.rds_temporal.rds_port
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster hosting all services."
  value       = module.ecs_cluster.cluster_name
}

output "temporal_nlb_address" {
  description = "Internal Temporal gRPC address used by API and Worker containers."
  value       = local.temporal_server_address
}

output "temporal_server_service_name" {
  description = "Name of the Temporal Server ECS service for querying task IPs."
  value       = module.ecs_services.temporal_server_service_name
}

output "api_target_group_arn" {
  description = "ARN of the API target group for health checks and registrations."
  value       = module.alb_temporal.api_target_group_arn
}

output "temporal_ui_target_group_arn" {
  description = "ARN of the Temporal UI target group."
  value       = module.alb_temporal.temporal_ui_target_group_arn
}
