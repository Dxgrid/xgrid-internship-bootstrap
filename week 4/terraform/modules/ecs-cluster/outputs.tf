output "cluster_id" {
  description = "ECS cluster ID."
  value       = aws_ecs_cluster.temporal.id
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.temporal.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.temporal.arn
}
