output "nlb_dns_name" {
  description = "Internal NLB DNS name — append :7233 to use as TEMPORAL_ADDRESS."
  value       = aws_lb.temporal_internal.dns_name
}

output "temporal_grpc_target_group_arn" {
  description = "Target group ARN — pass to ecs-services for temporal_server load_balancer block."
  value       = aws_lb_target_group.temporal_grpc.arn
}

output "nlb_arn" {
  description = "NLB ARN."
  value       = aws_lb.temporal_internal.arn
}
