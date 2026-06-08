variable "project_name" {
  description = "Project name used in resource names and tags."
  type        = string
}

variable "environment" {
  description = "Environment name used in resource tags."
  type        = string
}

variable "aws_region" {
  description = "AWS region."
  type        = string
}

variable "cluster_id" {
  description = "ECS cluster ID."
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster ARN."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the awsvpc service tasks."
  type        = list(string)
}

variable "services_sg_id" {
  description = "Security group ID for the mock service tasks (ingress :8000 from worker)."
  type        = string
}

variable "execution_role_arn" {
  description = "Shared ECS execution role ARN (ECR pull + CloudWatch Logs)."
  type        = string
}

variable "services_ecr_repository_url" {
  description = "Shared ECR repository URL; each service is a distinct tag (fraud, inventory, ...)."
  type        = string
}

variable "cloudmap_namespace_id" {
  description = "Cloud Map private DNS namespace ID the services register in."
  type        = string
}

variable "cloudmap_namespace_name" {
  description = "Cloud Map private DNS namespace name (e.g. temporal-order-dev.local)."
  type        = string
}

variable "container_port" {
  description = "Port each FastAPI mock service listens on."
  type        = number
  default     = 8000
}
