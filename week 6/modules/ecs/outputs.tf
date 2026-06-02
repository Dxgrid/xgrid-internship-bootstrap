output "cluster_name" {
  description = "ECS cluster name — used by monitoring, prometheus, and grafana modules for CloudWatch alarm dimensions and service discovery."
  value       = aws_ecs_cluster.main.name
}

output "cluster_arn" {
  description = "ECS cluster ARN — used by the prometheus module IAM policy and for CloudWatch Container Insights queries."
  value       = aws_ecs_cluster.main.arn
}

output "service_name" {
  description = "Demo app ECS service name — used by the monitoring module as the CloudWatch alarm service dimension."
  value       = aws_ecs_service.demo_app.name
}

output "task_definition_arn" {
  description = "Demo app ECS task definition ARN — referenced by the monitoring module and for manual redeploy commands."
  value       = aws_ecs_task_definition.demo_app.arn
}

output "asg_name" {
  description = "Auto Scaling Group name — used for scaling demo and capacity troubleshooting."
  value       = aws_autoscaling_group.ecs.name
}

output "log_group_name" {
  description = "CloudWatch log group name for the demo app — used in runbook log filter commands."
  value       = aws_cloudwatch_log_group.demo_app.name
}

output "ecs_task_role_arn" {
  description = "Demo app task role ARN — passed to the EFS module resource policy so it can be granted access when EFS is used by other services."
  value       = aws_iam_role.ecs_task_role.arn
}

output "ecs_instance_role_name" {
  description = "ECS EC2 instance role name — used by the prometheus module to attach additional read-only IAM policies for service discovery."
  value       = aws_iam_role.ecs_instance_role.name
}

output "ecr_repository_url" {
  description = "ECR repository URL for the demo app. Build and push the image here before running terraform apply for the ECS service."
  value       = aws_ecr_repository.demo_app.repository_url
}

output "cloudmap_namespace_arn" {
  description = "Cloud Map private DNS namespace ARN — passed to Prometheus and Grafana modules for service_connect_configuration."
  value       = aws_service_discovery_private_dns_namespace.cluster.arn
}

output "cloudmap_namespace_name" {
  description = "Cloud Map namespace DNS name — used to build the Prometheus dns_sd_configs target: demo-app-metrics.<namespace_name>."
  value       = aws_service_discovery_private_dns_namespace.cluster.name
}

output "demo_app_cloudmap_dns_name" {
  description = "Fully-qualified DNS name Prometheus uses to discover all demo-app task IPs via MULTIVALUE A records."
  value       = "demo-app-metrics.${aws_service_discovery_private_dns_namespace.cluster.name}"
}

