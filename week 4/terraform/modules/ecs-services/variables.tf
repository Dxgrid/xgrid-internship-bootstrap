variable "project_name" {
  description = "Project name used in resource names and tags."
  type        = string
}

variable "environment" {
  description = "Environment name used in resource tags."
  type        = string
}

variable "ecs_cluster_id" {
  description = "ECS cluster ID where services will be deployed."
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name for service discovery."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for task networking."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for task placement."
  type        = list(string)
}

variable "aws_region" {
  description = "AWS region."
  type        = string
}

variable "api_ecr_repository_url" {
  description = "ECR repository URL for API images."
  type        = string
}

variable "worker_ecr_repository_url" {
  description = "ECR repository URL for Worker images."
  type        = string
}

variable "rds_endpoint" {
  description = "RDS endpoint for Temporal database."
  type        = string
}

variable "db_username" {
  description = "Database username."
  type        = string
}


variable "db_secret_arn" {
  description = "ARN of Secrets Manager secret containing Temporal database credentials."
  type        = string
}
variable "api_target_group_arn" {
  description = "ALB target group ARN for API service."
  type        = string
}

variable "temporal_ui_target_group_arn" {
  description = "ALB target group ARN for Temporal UI."
  type        = string
}

variable "temporal_sg_id" {
  description = "Security group ID for Temporal Server tasks."
  type        = string
}

variable "api_sg_id" {
  description = "Security group ID for API tasks."
  type        = string
}

variable "worker_sg_id" {
  description = "Security group ID for Worker tasks."
  type        = string
}

variable "execution_role_arn" {
  description = "IAM execution role ARN for ECS tasks."
  type        = string
}

variable "task_role_arn" {
  description = "IAM task role ARN for running containers."
  type        = string
}

variable "temporal_server_address" {
  description = "Temporal Server gRPC address (hostname:port or IP:port)."
  type        = string
}

variable "api_container_port" {
  description = "Container port for API service."
  type        = number
}

variable "temporal_ui_container_port" {
  description = "Container port for Temporal UI."
  type        = number
}

variable "temporal_grpc_port" {
  description = "Container port for Temporal gRPC server."
  type        = number
}

variable "desired_api_count" {
  description = "Desired number of API task replicas."
  type        = number
}

variable "desired_worker_count" {
  description = "Desired number of Worker task replicas."
  type        = number
}

variable "temporal_grpc_target_group_arn" {
  description = "NLB target group ARN for Temporal gRPC port 7233 — temporal_server service registers here."
  type        = string
}
