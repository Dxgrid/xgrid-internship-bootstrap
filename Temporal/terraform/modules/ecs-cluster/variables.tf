variable "project_name" {
  description = "Project name used in resource names and tags."
  type        = string
}

variable "environment" {
  description = "Environment name used in resource tags."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name — also written into EC2 user_data to register instances."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the EC2 Auto Scaling Group."
  type        = list(string)
}

variable "ecs_sg_id" {
  description = "Security group ID applied to ECS EC2 instances."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for ECS cluster nodes. Use t3.large for Temporal + monitoring stack."
  type        = string
  default     = "t3.large"

  validation {
    condition     = contains(["t3.medium", "t3.large", "t3.xlarge", "m5.large", "m5.xlarge"], var.instance_type)
    error_message = "instance_type must be one of: t3.medium, t3.large, t3.xlarge, m5.large, m5.xlarge."
  }
}
