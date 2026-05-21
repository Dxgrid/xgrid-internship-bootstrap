output "monitoring_ec2_id" {
  description = "EC2 instance ID of the monitoring server."
  value       = aws_instance.monitoring.id
}

output "monitoring_ec2_private_ip" {
  description = "Private IP of the monitoring EC2 (used for debugging from within the VPC)."
  value       = aws_instance.monitoring.private_ip
}

output "monitoring_ec2_public_ip" {
  description = "Public IP of the monitoring EC2. Use this for direct browser access during development."
  value       = aws_instance.monitoring.public_ip
}

output "prometheus_direct_url" {
  description = "Direct Prometheus UI URL for development debugging (bypasses ALB)."
  value       = "http://${aws_instance.monitoring.public_ip}:9090"
}

output "grafana_direct_url" {
  description = "Direct Grafana UI URL for development debugging (bypasses ALB)."
  value       = "http://${aws_instance.monitoring.public_ip}:3000"
}

output "monitoring_assets_bucket_id" {
  description = "S3 bucket name holding Grafana dashboard and daily report script."
  value       = aws_s3_bucket.monitoring_assets.id
}
