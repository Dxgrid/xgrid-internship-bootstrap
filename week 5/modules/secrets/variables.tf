variable "project_name" {
  description = "Project name used for resource naming."
  type        = string
}

variable "environment" {
  description = "Environment name used for resource naming."
  type        = string
}

variable "db_name" {
  description = "Database name to store in Secrets Manager."
  type        = string
  default     = "wordpress"
}

variable "db_username" {
  description = "Database username to store in Secrets Manager."
  type        = string
  default     = "wordpress_user"
}

variable "db_host" {
  description = "RDS instance hostname (from module.rds.rds_endpoint). Used to complete the secret with connection details. Empty string before RDS creation."
  type        = string
  default     = ""
}

variable "secret_recovery_window" {
  description = "Number of days Secrets Manager waits before permanently deleting a secret. Set to 0 for immediate deletion in non-production environments."
  type        = number
  default     = 7
}