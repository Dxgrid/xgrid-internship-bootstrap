variable "project_name" {
  description = "Project name used for resource tags and naming."
  type        = string
  default     = "temporal-order"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "dev"
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
  default     = 1
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
