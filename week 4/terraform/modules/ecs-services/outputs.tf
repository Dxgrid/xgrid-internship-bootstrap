output "temporal_server_service_name" {
  description = "Name of the Temporal Server ECS service."
  value       = aws_ecs_service.temporal_server.name
}

output "temporal_server_service_arn" {
  description = "ARN of the Temporal Server ECS service."
  value       = aws_ecs_service.temporal_server.id
}

output "api_service_name" {
  description = "Name of the API ECS service."
  value       = aws_ecs_service.api.name
}

output "api_service_arn" {
  description = "ARN of the API ECS service."
  value       = aws_ecs_service.api.id
}

output "worker_service_name" {
  description = "Name of the Worker ECS service."
  value       = aws_ecs_service.worker.name
}

output "worker_service_arn" {
  description = "ARN of the Worker ECS service."
  value       = aws_ecs_service.worker.id
}

output "temporal_server_taskdef_arn" {
  description = "ARN of the Temporal Server task definition."
  value       = aws_ecs_task_definition.temporal_server.id
}

output "api_taskdef_arn" {
  description = "ARN of the API task definition."
  value       = aws_ecs_task_definition.api.id
}

output "worker_taskdef_arn" {
  description = "ARN of the Worker task definition."
  value       = aws_ecs_task_definition.worker.id
}
