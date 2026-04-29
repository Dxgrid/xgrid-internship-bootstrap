variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project for tagging"
  type        = string
  default     = "xgrid-sre-sprint"
}

variable "instance_type" {
  description = "EC2 instance type (Free Tier eligible)"
  type        = string
  default     = "t2.micro"
}

variable "allowed_ssh_ip" {
  description = "The CIDR block allowed to SSH into the instance (use your-ip/32 for security)"
  type        = string
  # Removed 0.0.0.0/0 default for security. 
  # Will be overridden by dynamic data source in main.tf or a tfvars file.
}

variable "app_port" {
  description = "Port the Python Health API listens on"
  type        = number
  default     = 8000
}

variable "key_pair_name" {
  description = "AWS EC2 Key Pair name for SSH access"
  type        = string
  default     = "xgrid-key"
}
