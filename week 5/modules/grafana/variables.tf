variable "project_name" {
  description = "Project name used for resource naming and tagging."
  type        = string
}

variable "environment" {
  description = "Deployment environment name (dev, staging, prod)."
  type        = string
}

variable "grafana_tg_arn_suffix" {
  description = "Grafana ALB target group ARN suffix for CloudWatch alarm dimensions."
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix for CloudWatch alarm dimensions."
  type        = string
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for alarm notifications."
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "AWS region for CloudWatch resources."
  type        = string
  default     = "us-east-1"
}
