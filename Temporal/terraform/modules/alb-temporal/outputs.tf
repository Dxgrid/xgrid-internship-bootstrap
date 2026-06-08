output "alb_id" {
  description = "ID of the Application Load Balancer."
  value       = aws_lb.temporal.id
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer."
  value       = aws_lb.temporal.arn
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer."
  value       = aws_lb.temporal.dns_name
}

output "alb_arn_suffix" {
  description = "ARN suffix of the ALB for CloudWatch metric dimensions."
  value       = aws_lb.temporal.arn_suffix
}

output "api_target_group_arn" {
  description = "ARN of the API target group."
  value       = aws_lb_target_group.api.arn
}

output "api_target_group_arn_suffix" {
  description = "ARN suffix of the API target group for CloudWatch dimensions."
  value       = aws_lb_target_group.api.arn_suffix
}

output "temporal_ui_target_group_arn" {
  description = "ARN of the Temporal UI target group."
  value       = aws_lb_target_group.temporal_ui.arn
}

output "temporal_ui_target_group_arn_suffix" {
  description = "ARN suffix of the Temporal UI target group for CloudWatch dimensions."
  value       = aws_lb_target_group.temporal_ui.arn_suffix
}

output "grafana_target_group_arn" {
  description = "ARN of the Grafana target group."
  value       = aws_lb_target_group.grafana.arn
}

output "grafana_target_group_arn_suffix" {
  description = "ARN suffix of the Grafana target group for CloudWatch dimensions."
  value       = aws_lb_target_group.grafana.arn_suffix
}
