variable "project_name" {
  description = "Project name used in resource names and tags."
  type        = string
}

variable "environment" {
  description = "Environment name used in resource tags."
  type        = string
}

variable "private_subnet_ids" {
  description = "IDs of private subnets for RDS deployment."
  type        = list(string)
}

variable "rds_sg_id" {
  description = "Security group ID for RDS access control."
  type        = string
}

variable "db_username" {
  description = "Master username for the Temporal database."
  type        = string
}

variable "db_password" {
  description = "Master password for the Temporal database."
  type        = string
  sensitive   = true
}
