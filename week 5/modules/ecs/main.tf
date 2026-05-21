# Fetch the latest ECS-optimized Amazon Linux 2023 AMI dynamically.
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# CloudWatch log group for WordPress container logs; must exist before task startup.
resource "aws_cloudwatch_log_group" "wordpress" {
  name              = "/ecs/${var.project_name}/${var.environment}/wordpress"
  retention_in_days = 7

  tags = {
    Name        = "${var.project_name}-${var.environment}-ecs-logs"
    Project     = var.project_name
    Environment = var.environment
  }
}

# IAM role assumed by the EC2 instance itself (not the container).
resource "aws_iam_role" "ecs_instance_role" {
  name_prefix = "${var.project_name}-${var.environment}-ecs-instance-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-ecs-instance-role"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "ecs_instance_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ecs_instance_ssm_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name_prefix = "${var.project_name}-${var.environment}-ecs-instance-"
  role        = aws_iam_role.ecs_instance_role.name

  lifecycle {
    create_before_destroy = true
  }
}

# IAM role used by the ECS agent before container start to pull images and read secrets.
resource "aws_iam_role" "ecs_task_execution" {
  name_prefix = "${var.project_name}-${var.environment}-ecs-exec-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowECSTaskExecution"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-ecs-exec-role"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name = "${var.project_name}-${var.environment}-execution-secrets"
  role = aws_iam_role.ecs_task_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSecretsManagerGetSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = var.secret_arn
      },
      {
        Sid    = "AllowKMSDecryptForSecrets"
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = var.kms_key_arn
      }
    ]
  })
}

# IAM role assumed by the WordPress container at runtime with minimal permissions.
resource "aws_iam_role" "ecs_task_role" {
  name_prefix = "${var.project_name}-${var.environment}-ecs-task-"
  description = "Task role for WordPress container - minimal permissions (least privilege)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowECSTaskAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-ecs-task-role"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "ecs_task_efs" {
  name   = "${var.project_name}-${var.environment}-efs-access"
  role   = aws_iam_role.ecs_task_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEFSMount"
        Effect = "Allow"
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:ClientRootAccess"
        ]
        Resource = var.efs_arn
        Condition = {
          StringEquals = {
            "elasticfilesystem:AccessPointArn" = var.access_point_arn
          }
        }
      }
    ]
  })
}

# ECS Cluster with Container Insights enabled for CPU, memory, and task count metrics.
resource "aws_ecs_cluster" "wordpress" {
  name = "${var.project_name}-${var.environment}-cluster"

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

resource "aws_ecs_cluster_capacity_providers" "wordpress" {
  cluster_name = aws_ecs_cluster.wordpress.name

  capacity_providers = [aws_ecs_capacity_provider.ec2.name]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 1
    capacity_provider = aws_ecs_capacity_provider.ec2.name
  }

  depends_on = [aws_ecs_capacity_provider.ec2]
}

# Launch template for ECS instances configuring the ECS agent and EFS volume plugin.
resource "aws_launch_template" "ecs_instance" {
  name_prefix   = "${var.project_name}-${var.environment}-ecs-lt-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = "t2.micro"

  iam_instance_profile {
    arn = aws_iam_instance_profile.ecs_instance.arn
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              # Join the cluster first to ensure instance registers even if other steps are slow
              mkdir -p /etc/ecs
              echo ECS_CLUSTER=${aws_ecs_cluster.wordpress.name} > /etc/ecs/ecs.config
              echo ECS_ENABLE_TASK_IAM_ROLE=true >> /etc/ecs/ecs.config
              echo ECS_ENABLE_AWSLOGS_EXECUTIONROLE_OVERRIDE=true >> /etc/ecs/ecs.config
              systemctl restart ecs --no-block

              # Install EFS tools and other dependencies
              yum install -y amazon-efs-utils
              systemctl enable --now amazon-ecs-volume-plugin
              systemctl restart docker

              # Start Node Exporter for Prometheus scraping (host network mode for accurate metrics)
              docker run -d \
                --name node_exporter \
                --restart always \
                --net host \
                --pid host \
                -v /proc:/host/proc:ro \
                -v /sys:/host/sys:ro \
                -v /:/rootfs:ro \
                quay.io/prometheus/node-exporter:v1.8.1 \
                  --path.procfs=/host/proc \
                  --path.sysfs=/host/sys \
                  --path.rootfs=/rootfs \
                  "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|var/lib/docker/.+)($$|/)" \
                  --web.listen-address=:9100
              EOF
  )

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

  lifecycle {
    create_before_destroy = true
  }
}

# Auto Scaling Group for ECS instances with managed scaling and rolling updates.
resource "aws_autoscaling_group" "ecs" {
  name_prefix = "${var.project_name}-${var.environment}-ecs-asg-"

  min_size            = var.min_instances
  max_size            = var.max_instances
  desired_capacity    = var.desired_count
  vpc_zone_identifier = var.private_subnet_ids

  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.ecs_instance.id
    version = "$Latest"
  }

  protect_from_scale_in = true

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ECS capacity provider pairing with the ASG for cluster reservation managed scaling.
resource "aws_ecs_capacity_provider" "ec2" {
  name = "${var.project_name}-${var.environment}-ec2-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = var.managed_scaling_target_capacity
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 2
    }
  }
}

# ECS task definition for WordPress with awsvpc networking and EFS volume configuration.
resource "aws_ecs_task_definition" "wordpress" {
  family                   = "${var.project_name}-${var.environment}-wordpress"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  cpu                      = "256"
  memory                   = "512"

  volume {
    name = "wordpress-efs"

    efs_volume_configuration {
      file_system_id      = var.efs_id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = var.access_point_id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "wordpress"
      image     = "wordpress:6.5-apache"
      essential = true
      cpu       = 256
      memory    = 512

      portMappings = [
        {
          containerPort = 80
          protocol      = "tcp"
        }
      ]

      secrets = [
        {
          name      = "WORDPRESS_DB_HOST"
          valueFrom = "${var.secret_arn}:host::"
        },
        {
          name      = "WORDPRESS_DB_USER"
          valueFrom = "${var.secret_arn}:username::"
        },
        {
          name      = "WORDPRESS_DB_PASSWORD"
          valueFrom = "${var.secret_arn}:password::"
        },
        {
          name      = "WORDPRESS_DB_NAME"
          valueFrom = "${var.secret_arn}:dbname::"
        }
      ]

      environment = [
        {
          name  = "WORDPRESS_TABLE_PREFIX"
          value = "wp_"
        }
      ]

      mountPoints = [
        {
          sourceVolume  = "wordpress-efs"
          containerPath = "/var/www/html"
          readOnly      = false
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.wordpress.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "wordpress"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost/wp-login.php || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 120
      }
    }
  ])

  tags = {
    Name        = "${var.project_name}-${var.environment}-wordpress-task"
    Project     = var.project_name
    Environment = var.environment
  }

  depends_on = [
    aws_iam_role_policy_attachment.ecs_task_execution_policy,
    aws_iam_role_policy.ecs_execution_secrets,
    aws_cloudwatch_log_group.wordpress
  ]
}

# ECS service maintaining WordPress tasks with deployment circuit breaker and placement spread.
resource "aws_ecs_service" "wordpress" {
  name            = "${var.project_name}-${var.environment}-wordpress-svc"
  cluster         = aws_ecs_cluster.wordpress.id
  task_definition = aws_ecs_task_definition.wordpress.arn
  desired_count   = var.desired_count

  health_check_grace_period_seconds = 120

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 1
    base              = 1
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_sg_id]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn != "" ? [1] : []
    content {
      target_group_arn = var.target_group_arn
      container_name   = "wordpress"
      container_port   = 80
    }
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  enable_execute_command = false

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.wordpress,
    aws_iam_role_policy_attachment.ecs_task_execution_policy,
    aws_cloudwatch_log_group.wordpress
  ]

  tags = {
    Name        = "${var.project_name}-${var.environment}-wordpress-svc"
    Project     = var.project_name
    Environment = var.environment
  }
}
