output "prometheus_task_role_arn" {
  description = "Prometheus ECS task role ARN — passed to the EFS module so it can be added to the resource policy ALLOW statement."
  value       = aws_iam_role.prometheus_task.arn
}

output "prometheus_service_name" {
  description = "Prometheus ECS service name — useful for runbook commands and CloudWatch log filter URLs."
  value       = aws_ecs_service.prometheus.name
}

output "prometheus_log_group_name" {
  description = "CloudWatch log group name for Prometheus and AlertManager — used in runbook log filter commands."
  value       = aws_cloudwatch_log_group.prometheus.name
}
