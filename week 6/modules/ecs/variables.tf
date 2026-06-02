variable "project_name" {
  type        = string
  description = "Project name used for resource naming and tagging."
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, or prod)."
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "vpc_id" {
  type        = string
  description = "ID of the VPC where ECS resources are deployed."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for EC2 instances and awsvpc ECS tasks. Tasks must not be directly internet-reachable."
}

variable "ecs_sg_id" {
  type        = string
  description = "Security group ID attached to ECS EC2 instances and awsvpc tasks."
}

variable "target_group_arn" {
  type        = string
  description = "ALB target group ARN for the demo app. Set to empty string to skip ALB registration (useful during the initial ECR image bootstrap before the image exists)."
  default     = ""
}

variable "desired_count" {
  type        = number
  description = "Desired number of demo app ECS task replicas. Minimum 2 for high availability."
  default     = 2
  validation {
    condition     = var.desired_count >= 1
    error_message = "desired_count must be at least 1."
  }
}

variable "min_instances" {
  type        = number
  description = "Minimum EC2 instance count in the ECS Auto Scaling Group."
  default     = 1
  validation {
    condition     = var.min_instances >= 1
    error_message = "min_instances must be at least 1."
  }
}

variable "max_instances" {
  type        = number
  description = "Maximum EC2 instance count in the ECS Auto Scaling Group."
  default     = 2
}

variable "managed_scaling_target_capacity" {
  type        = number
  description = "Target cluster utilization percentage for ECS managed scaling (1–100)."
  default     = 85
  validation {
    condition     = var.managed_scaling_target_capacity >= 1 && var.managed_scaling_target_capacity <= 100
    error_message = "managed_scaling_target_capacity must be between 1 and 100."
  }
}

variable "app_image" {
  type        = string
  description = "Full Docker image URI for the demo app (e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com/repo:tag). Leave empty to default to the ECR repository created by this module tagged 'latest'. The image must be pushed to ECR before ECS tasks can start successfully."
  default     = ""
}
