output "efs_id" {
  description = "EFS file system ID."
  value       = aws_efs_file_system.wordpress.id
}

output "efs_arn" {
  description = "EFS file system ARN."
  value       = aws_efs_file_system.wordpress.arn
}

output "efs_dns_name" {
  description = "EFS DNS name."
  value       = aws_efs_file_system.wordpress.dns_name
}

output "access_point_id" {
  description = "EFS access point ID for WordPress."
  value       = aws_efs_access_point.wordpress.id
}

output "access_point_arn" {
  description = "EFS access point ARN."
  value       = aws_efs_access_point.wordpress.arn
}