output "grafana_task_role_arn" {
  description = "Grafana ECS task role ARN — passed to the EFS module so it can be added to the resource policy ALLOW statement."
  value       = aws_iam_role.grafana_task.arn
}

output "grafana_service_name" {
  description = "Grafana ECS service name — useful for runbook commands and CloudWatch log filter URLs."
  value       = aws_ecs_service.grafana.name
}

output "grafana_log_group_name" {
  description = "CloudWatch log group name for Grafana — used in runbook log filter commands."
  value       = aws_cloudwatch_log_group.grafana.name
}

output "grafana_alarm_name" {
  description = "Grafana unhealthy hosts alarm name — referenced by the monitoring module composite alarm."
  value       = aws_cloudwatch_metric_alarm.grafana_unhealthy.alarm_name
}
