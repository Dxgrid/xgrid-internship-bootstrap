variable "project_name" {
  description = "Project name used in resource names and tags."
  type        = string
}

variable "environment" {
  description = "Environment name used in resource tags."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where ALB will be created."
  type        = string
}

variable "public_subnet_ids" {
  description = "IDs of public subnets for ALB deployment."
  type        = list(string)
}

variable "alb_sg_id" {
  description = "Security group ID for the ALB."
  type        = string
}

variable "alarm_sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarm notifications. Alarms without actions are silent."
  type        = string
}
