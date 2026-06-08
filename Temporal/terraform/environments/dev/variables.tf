variable "project_name" {
  description = "Project name used for resource tags and naming."
  type        = string
  default     = "temporal-order"
}

variable "aws_region" {
  description = "AWS region for the deployment."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets."
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "db_username" {
  description = "Master username for RDS Temporal database."
  type        = string
  default     = "temporal"
}

variable "db_password" {
  description = "Master password for RDS Temporal database. Set via tfvars."
  type        = string
  sensitive   = true
}


variable "ecr_image_scan" {
  description = "Enable image scanning on push for ECR repositories."
  type        = bool
  default     = true
}

variable "desired_api_count" {
  description = "Desired number of API task replicas."
  type        = number
  default     = 1
}

variable "desired_worker_count" {
  description = "Desired number of Worker task replicas."
  type        = number
  default     = 2
}

variable "worker_min_capacity" {
  description = "Minimum worker tasks for ECS Application Auto Scaling. Must be >= 2 to survive rolling deployments."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_min_capacity >= 2
    error_message = "worker_min_capacity must be at least 2 to ensure availability during rolling deployments."
  }
}

variable "worker_max_capacity" {
  description = "Maximum worker tasks ECS Application Auto Scaling may launch."
  type        = number
  default     = 10
}

variable "ecs_instance_type" {
  description = "EC2 instance type for ECS cluster nodes. t3.large required to fit Temporal + monitoring stack."
  type        = string
  default     = "t3.large"
}

variable "alert_email" {
  description = "Email address to receive CloudWatch alarm notifications via SNS."
  type        = string
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "api_container_port" {
  description = "Container port for FastAPI service."
  type        = number
  default     = 8000
}

variable "temporal_ui_container_port" {
  description = "Container port for Temporal UI."
  type        = number
  default     = 8080
}

variable "temporal_grpc_port" {
  description = "Container port for Temporal gRPC server."
  type        = number
  default     = 7233
}
