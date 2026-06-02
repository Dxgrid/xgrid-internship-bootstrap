output "sns_topic_arn" {
  description = "Wire this into existing RDS and ALB alarm_actions"
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_url" {
  description = "Direct link to open the dashboard in AWS console"
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
