output "sns_topic_arn" {
  description = "Wire this into existing RDS and ALB alarm_actions"
  value       = aws_sns_topic.wordpress_alerts.arn
}

output "dashboard_url" {
  description = "Direct link to open the dashboard in AWS console"
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=${aws_cloudwatch_dashboard.wordpress.dashboard_name}"
}
