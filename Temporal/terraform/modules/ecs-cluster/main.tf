# ECS Cluster with EC2 capacity — instance role, profile, launch template, ASG, capacity provider
# Mirrors the Week 3 ECS module pattern but stripped of WordPress/EFS-specific resources.

data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

# ─── EC2 INSTANCE IAM ROLE ───────────────────────────────────────────────────

resource "aws_iam_role" "ecs_instance_role" {
  name_prefix = "${var.project_name}-${var.environment}-ecs-instance-"
  description = "IAM role assumed by EC2 instances that run ECS tasks"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEC2AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })

  lifecycle { create_before_destroy = true }

  tags = {
    Name        = "${var.project_name}-${var.environment}-ecs-instance-role"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "ecs_instance_ecs" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ecs_instance_ssm" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name_prefix = "${var.project_name}-${var.environment}-ecs-instance-"
  role        = aws_iam_role.ecs_instance_role.name

  lifecycle { create_before_destroy = true }
}

# ─── ECS CLUSTER ─────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "temporal" {
  name = var.cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-cluster"
    Project     = var.project_name
    Environment = var.environment
  }
}

# ─── LAUNCH TEMPLATE ─────────────────────────────────────────────────────────

resource "aws_launch_template" "ecs_instance" {
  name_prefix   = "${var.project_name}-${var.environment}-ecs-lt-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ecs_instance.arn
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    mkdir -p /etc/ecs
    echo ECS_CLUSTER=${var.cluster_name} >> /etc/ecs/ecs.config
    echo ECS_ENABLE_TASK_IAM_ROLE=true >> /etc/ecs/ecs.config
    echo ECS_ENABLE_AWSLOGS_EXECUTIONROLE_OVERRIDE=true >> /etc/ecs/ecs.config
    echo ECS_ENABLE_CONTAINER_METADATA=true >> /etc/ecs/ecs.config
    systemctl restart ecs --no-block
  EOF
  )

  metadata_options {
    http_endpoint               = "enabled"
    # Enforce IMDSv2 — IMDSv1 allows SSRF attacks to steal instance credentials
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [var.ecs_sg_id]
    delete_on_termination       = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project_name}-${var.environment}-ecs-instance"
      Project     = var.project_name
      Environment = var.environment
    }
  }

  lifecycle { create_before_destroy = true }
}

# ─── AUTO SCALING GROUP ───────────────────────────────────────────────────────

resource "aws_autoscaling_group" "ecs" {
  name_prefix = "${var.project_name}-${var.environment}-ecs-asg-"

  # min=2 ensures one instance always available during rolling replacement.
  # max=7 / desired=6: awsvpc tasks each consume an ENI, and ENI trunking is not
  # attaching on these instances, so each t3.large holds only 2 awsvpc tasks. We run
  # ~10 awsvpc tasks (server + 2 workers + 5 mocks + prometheus + grafana), needing
  # 6 instances (12 slots). desired_capacity is ignored below (capacity provider owns
  # it); the live value is set to 6 out-of-band.
  min_size            = 2
  max_size            = 7
  desired_capacity    = 6
  vpc_zone_identifier = var.private_subnet_ids

  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.ecs_instance.id
    version = "$Latest"
  }

  protect_from_scale_in = true

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  # ignore_changes on launch_template and desired_capacity lets the ECS capacity
  # provider manage instance count and AMI updates without Terraform fighting it.
  # Without this, Terraform hangs: desired_capacity=1 can never be reached because
  # ECS sets scale-in protection on all running instances.
  lifecycle {
    create_before_destroy = true
    ignore_changes        = [launch_template, desired_capacity]
  }
}

# ─── CAPACITY PROVIDER ────────────────────────────────────────────────────────

resource "aws_ecs_capacity_provider" "ec2" {
  name = "${var.project_name}-${var.environment}-ec2-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 85
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 2
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "temporal" {
  cluster_name       = aws_ecs_cluster.temporal.name
  capacity_providers = [aws_ecs_capacity_provider.ec2.name]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 1
    capacity_provider = aws_ecs_capacity_provider.ec2.name
  }

  depends_on = [aws_ecs_capacity_provider.ec2]
}
