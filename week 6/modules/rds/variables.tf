variable "project_name" {
  type        = string
  description = "Name of the project (e.g., 'flask-sre-ecs'). Used for resource naming and tagging."
}

variable "environment" {
  type        = string
  description = "Environment name (e.g., 'dev', 'staging', 'prod'). Used for resource naming and tagging."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "List of private subnet IDs where RDS will be placed (from module.vpc.private_subnet_ids)."
}

variable "rds_sg_id" {
  type        = string
  description = "Security group ID for RDS (from module.security_groups.rds_sg_id). Allows MySQL:3306 from ECS only."
}

variable "db_name" {
  type        = string
  description = "Name of the database to create (from module.secrets.db_name)."
}

variable "db_username" {
  type        = string
  description = "Master username for the database (from module.secrets.db_username)."
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "Master password for the database (from module.secrets.db_password). Sensitive — stored in encrypted state."
}

variable "kms_key_arn" {
  type        = string
  description = "ARN of the KMS CMK for RDS storage encryption (from module.secrets.kms_key_arn). Same key used across Secrets Manager, EFS, and RDS."
}

variable "sns_topic_arn" {
  type        = string
  description = "SNS topic ARN for CloudWatch alarm notifications. Passed from the monitoring module."
  default     = ""
}

variable "deletion_protection" {
  type        = bool
  description = "Enable deletion protection on the RDS instance. Set to true for production environments."
  default     = false
}
