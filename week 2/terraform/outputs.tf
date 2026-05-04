output "ec2_public_ip" {
  description = "The public IP of the EC2 instance"
  value       = aws_instance.app_server.public_ip
}

output "instance_id" {
  description = "The ID of the EC2 instance"
  value       = aws_instance.app_server.id
}
