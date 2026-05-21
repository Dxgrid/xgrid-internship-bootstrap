variable "project_name" {
  description = "Project name used for resource naming."
  type        = string
}

variable "environment" {
  description = "Environment name used for resource naming."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for mount targets (one per AZ)."
  type        = list(string)
}

variable "efs_sg_id" {
  description = "EFS security group ID for mount targets."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK ARN for EFS encryption at rest (from secrets module)."
  type        = string
}

variable "ecs_task_role_arn" {
  description = "ECS task role ARN — added to EFS resource policy ALLOW statement for mount access."
  type        = string
}