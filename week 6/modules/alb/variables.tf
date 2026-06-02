variable "project_name" {
  description = "Project name used for resource naming and tagging."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, or prod)."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "vpc_id" {
  description = "VPC ID where the ALB and target groups are created."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the ALB (one per AZ for high availability)."
  type        = list(string)
}

variable "alb_sg_id" {
  description = "Security group ID attached to the ALB."
  type        = string
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarm notifications. Pass empty string to disable alarm actions."
  type        = string
  default     = ""
}

variable "health_check_path" {
  description = "HTTP path the ALB uses for app target group health checks."
  type        = string
  default     = "/health"
}

variable "health_check_matcher" {
  description = "HTTP response codes considered healthy by the ALB health check."
  type        = string
  default     = "200"
}

variable "idle_timeout" {
  description = "Seconds the ALB keeps an idle connection open before closing it."
  type        = number
  default     = 60
  validation {
    condition     = var.idle_timeout >= 1 && var.idle_timeout <= 4000
    error_message = "idle_timeout must be between 1 and 4000 seconds."
  }
}
