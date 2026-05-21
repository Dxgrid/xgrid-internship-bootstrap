output "cluster_name" {
  description = "ECS cluster name — used in Phase 7 ALB integration and debugging commands."
  value       = aws_ecs_cluster.wordpress.name
}

output "cluster_arn" {
  description = "ECS cluster ARN — used for IAM policies, CloudWatch alarms, and audit logging."
  value       = aws_ecs_cluster.wordpress.arn
}

output "service_name" {
  description = "ECS service name — used for debugging and monitoring."
  value       = aws_ecs_service.wordpress.name
}

output "task_definition_arn" {
  description = "ECS task definition ARN — referenced by Phase 8 CloudWatch alarms and monitoring."
  value       = aws_ecs_task_definition.wordpress.arn
}

output "asg_name" {
  description = "Auto Scaling Group name — used by Phase 7 ALB integration for target group registration."
  value       = aws_autoscaling_group.ecs.name
}

output "log_group_name" {
  description = "CloudWatch log group name — where WordPress container logs are written."
  value       = aws_cloudwatch_log_group.wordpress.name
}

output "ecs_task_role_arn" {
  description = "ECS task role ARN — passed to EFS resource policy to allow mount access."
  value       = aws_iam_role.ecs_task_role.arn
}

output "ecs_instance_role_name" {
  description = "ECS EC2 instance role name — used by the prometheus module to attach additional IAM policies."
  value       = aws_iam_role.ecs_instance_role.name
}
