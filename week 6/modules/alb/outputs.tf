output "alb_dns_name" {
  description = "ALB public DNS name — paste this in your browser to reach the demo app."
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ALB ARN."
  value       = aws_lb.main.arn
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix — used in CloudWatch alarm and dashboard dimensions."
  value       = aws_lb.main.arn_suffix
}

output "alb_zone_id" {
  description = "ALB hosted zone ID — used for Route53 alias records in staging/prod."
  value       = aws_lb.main.zone_id
}

output "target_group_arn" {
  description = "Demo app target group ARN — passed to the ECS module so the service registers tasks here."
  value       = aws_lb_target_group.app.arn
}

output "target_group_arn_suffix" {
  description = "Demo app target group ARN suffix — used in CloudWatch alarm dimensions."
  value       = aws_lb_target_group.app.arn_suffix
}

output "unhealthy_hosts_alarm_name" {
  description = "Unhealthy hosts alarm name — referenced by the monitoring module composite alarm."
  value       = aws_cloudwatch_metric_alarm.alb_unhealthy_hosts.alarm_name
}

output "grafana_target_group_arn" {
  description = "Grafana target group ARN — passed to the Grafana ECS service so it registers task IPs here."
  value       = aws_lb_target_group.grafana.arn
}

output "grafana_tg_arn_suffix" {
  description = "Grafana target group ARN suffix — used in CloudWatch alarm dimensions."
  value       = aws_lb_target_group.grafana.arn_suffix
}
