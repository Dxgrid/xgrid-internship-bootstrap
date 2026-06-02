variable "project_name" {
  description = "Project name used for resource naming and tagging."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, or prod)."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EFS mount targets (one per AZ)."
  type        = list(string)
}

variable "efs_sg_id" {
  description = "Security group ID attached to EFS mount targets."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK ARN for EFS encryption at rest (from secrets module)."
  type        = string
}

variable "prometheus_task_role_arn" {
  description = "Prometheus ECS task role ARN added to the EFS resource policy. Leave empty until the Prometheus module is applied."
  type        = string
  default     = ""
}

variable "grafana_task_role_arn" {
  description = "Grafana ECS task role ARN added to the EFS resource policy. Leave empty until the Grafana module is applied."
  type        = string
  default     = ""
}
