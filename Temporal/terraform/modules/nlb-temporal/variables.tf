variable "project_name" {
  description = "Project name used in resource names and tags."
  type        = string
}

variable "environment" {
  description = "Environment name used in resource tags."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the NLB target group."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the internal NLB."
  type        = list(string)
}
