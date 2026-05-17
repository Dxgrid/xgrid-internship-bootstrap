variable "project_name" {
  description = "Project name used in resource names and tags."
  type        = string
}

variable "environment" {
  description = "Environment name used in resource tags."
  type        = string
}

variable "db_secret_arn" {
  description = "ARN of Secrets Manager secret containing Temporal database credentials."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of KMS key used to encrypt the Temporal database secret."
  type        = string
}
