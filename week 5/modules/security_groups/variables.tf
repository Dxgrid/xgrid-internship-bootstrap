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

variable "admin_cidr_block" {
  description = "CIDR block allowed SSH access to the monitoring EC2. Leave empty to disable SSH ingress."
  type        = string
  default     = ""
}
