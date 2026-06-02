output "vpc_id" {
  description = "VPC ID for the dev environment."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs for the dev environment."
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs for the dev environment."
  value       = module.vpc.private_subnet_ids
}

output "rds_endpoint" {
  description = "RDS instance hostname."
  value       = module.rds.rds_endpoint
}

output "rds_identifier" {
  description = "RDS instance identifier — used in AWS CLI and CloudWatch commands."
  value       = module.rds.rds_identifier
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = module.ecs.cluster_name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = module.ecs.cluster_arn
}

output "demo_app_service_name" {
  description = "Demo app ECS service name."
  value       = module.ecs.service_name
}

output "ecr_repository_url" {
  description = "ECR repository URL — build and push the demo app image here before first deploy."
  value       = module.ecs.ecr_repository_url
}

output "asg_name" {
  description = "ECS Auto Scaling Group name — used for scaling demo commands."
  value       = module.ecs.asg_name
}

output "alb_dns_name" {
  description = "ALB public DNS — paste this in your browser to reach the demo app."
  value       = module.alb.alb_dns_name
}

output "grafana_url" {
  description = "Grafana UI URL via ALB path routing."
  value       = "http://${module.alb.alb_dns_name}/grafana"
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL."
  value       = module.monitoring.dashboard_url
}

output "sns_topic_arn" {
  description = "SNS topic ARN for alarm notifications."
  value       = module.monitoring.sns_topic_arn
}

output "prometheus_service_name" {
  description = "Prometheus ECS service name — use this to find the task private IP for the Grafana datasource."
  value       = module.prometheus.prometheus_service_name
}

output "prometheus_log_group" {
  description = "CloudWatch log group for Prometheus and AlertManager container logs."
  value       = module.prometheus.prometheus_log_group_name
}

output "grafana_log_group" {
  description = "CloudWatch log group for Grafana container logs."
  value       = module.grafana.grafana_log_group_name
}

output "grafana_alarm_name" {
  description = "CloudWatch alarm that fires when Grafana is unreachable via the ALB."
  value       = module.grafana.grafana_alarm_name
}
