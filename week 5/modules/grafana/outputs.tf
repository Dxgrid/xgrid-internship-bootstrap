output "grafana_alarm_name" {
  description = "Name of the Grafana health CloudWatch alarm."
  value       = aws_cloudwatch_metric_alarm.grafana_unhealthy.alarm_name
}

output "grafana_log_group_name" {
  description = "CloudWatch log group name for Grafana container logs."
  value       = aws_cloudwatch_log_group.grafana.name
}
