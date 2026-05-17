variable "project_name" {
  description = "Project name used in resource names and tags."
  type        = string
}

variable "environment" {
  description = "Environment name used in resource tags."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where security groups will be created."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block — used to allow NLB health checks into the Temporal SG (NLBs have no security group)."
  type        = string
}
