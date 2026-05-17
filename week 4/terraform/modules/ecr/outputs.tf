output "api_repository_url" {
  description = "URL of the API ECR repository (without tag)."
  value       = aws_ecr_repository.api.repository_url
}

output "api_repository_name" {
  description = "Name of the API ECR repository."
  value       = aws_ecr_repository.api.name
}

output "api_repository_arn" {
  description = "ARN of the API ECR repository."
  value       = aws_ecr_repository.api.arn
}

output "worker_repository_url" {
  description = "URL of the Worker ECR repository (without tag)."
  value       = aws_ecr_repository.worker.repository_url
}

output "worker_repository_name" {
  description = "Name of the Worker ECR repository."
  value       = aws_ecr_repository.worker.name
}

output "worker_repository_arn" {
  description = "ARN of the Worker ECR repository."
  value       = aws_ecr_repository.worker.arn
}
