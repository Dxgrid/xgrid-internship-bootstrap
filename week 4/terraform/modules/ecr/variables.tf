variable "project_name" {
  description = "Project name used in resource names."
  type        = string
}

variable "environment" {
  description = "Environment name used in resource tags."
  type        = string
}

variable "image_scan_enabled" {
  description = "Enable image scanning on push for vulnerability detection."
  type        = bool
  default     = true
}
