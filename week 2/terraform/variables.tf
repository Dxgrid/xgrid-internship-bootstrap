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
  description = "The CIDR block allowed to SSH into the instance (e.g., your public IP /32)"
  type        = string
  default     = "0.0.0.0/0" # PLACEHOLDER: Replace with your IP for security
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
