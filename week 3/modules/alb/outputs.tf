output "alb_dns_name" {
  description = "Paste this in your browser — WordPress will be live here"
  value       = aws_lb.wordpress.dns_name
}

output "alb_arn" {
  description = "The ARN of the ALB"
  value       = aws_lb.wordpress.arn
}

output "alb_arn_suffix" {
  description = "Used in CloudWatch dashboard dimensions"
  value       = aws_lb.wordpress.arn_suffix
}

output "alb_zone_id" {
  description = "Used for Route53 alias record in prod"
  value       = aws_lb.wordpress.zone_id
}

output "target_group_arn" {
  description = "Wire this into module.ecs target_group_arn input"
  value       = aws_lb_target_group.wordpress.arn
}

output "target_group_arn_suffix" {
  description = "Used in CloudWatch alarm dimensions"
  value       = aws_lb_target_group.wordpress.arn_suffix
}

output "unhealthy_hosts_alarm_name" {
  description = "Name of the unhealthy hosts alarm for composite alarm"
  value       = aws_cloudwatch_metric_alarm.alb_unhealthy_hosts.alarm_name
}
