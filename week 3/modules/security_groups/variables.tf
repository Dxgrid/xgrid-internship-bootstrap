variable "project_name" {
  description = "Project name used for resource naming."
  type        = string
}

variable "environment" {
  description = "Environment name used for resource naming."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID from the VPC module."
  type        = string
}
