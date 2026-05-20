data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "amazon_linux_2" {
  name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}

# IAM role assumed by the monitoring EC2 instance.
resource "aws_iam_role" "monitoring_ec2" {
  name_prefix = "${var.project_name}-${var.environment}-monitoring-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-${var.environment}-monitoring-role"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Read-only AWS permissions for Prometheus service discovery and the daily report script.
resource "aws_iam_policy" "monitoring_read" {
  name_prefix = "${var.project_name}-${var.environment}-monitoring-read-"
  description = "Allows the monitoring EC2 to read ECS, CloudWatch, RDS, and EC2 metrics for Prometheus discovery and daily reporting."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarms"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogsRead"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:GetQueryResults"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECSRead"
        Effect = "Allow"
        Action = [
          "ecs:ListClusters",
          "ecs:ListServices",
          "ecs:ListTasks",
          "ecs:DescribeTasks",
          "ecs:DescribeServices",
          "ecs:DescribeClusters"
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2DescribeForServiceDiscovery"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeAvailabilityZones"
        ]
        Resource = "*"
      },
      {
        Sid    = "RDSRead"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances"
        ]
        Resource = "*"
      },
      {
        Sid    = "ALBRead"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTargetGroups"
        ]
        Resource = "*"
      },
      {
        Sid    = "S3MonitoringAssets"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.monitoring_assets.arn,
          "${aws_s3_bucket.monitoring_assets.arn}/*"
        ]
      },
      {
        Sid    = "SNSPublish"
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "monitoring_read" {
  role       = aws_iam_role.monitoring_ec2.name
  policy_arn = aws_iam_policy.monitoring_read.arn
}

# SSM Session Manager allows SSH-free instance access for debugging.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.monitoring_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "monitoring_ec2" {
  name_prefix = "${var.project_name}-${var.environment}-monitoring-"
  role        = aws_iam_role.monitoring_ec2.name
}

# S3 bucket for storing monitoring assets (Grafana dashboard, daily report script).
# These files are downloaded by user_data.sh.tpl at EC2 boot instead of being embedded,
# which keeps user_data under AWS's 16KB limit.
resource "aws_s3_bucket" "monitoring_assets" {
  bucket        = "${var.project_name}-${var.environment}-monitoring-assets"
  force_destroy = true  # dev only — allows terraform destroy to clean up

  tags = {
    Name        = "${var.project_name}-${var.environment}-monitoring-assets"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "monitoring_assets" {
  bucket                  = aws_s3_bucket.monitoring_assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "monitoring_assets" {
  bucket = aws_s3_bucket.monitoring_assets.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "grafana_dashboard" {
  bucket = aws_s3_bucket.monitoring_assets.id
  key    = "grafana/wordpress-overview.json"
  source = "${path.module}/../../dashboards/wordpress-overview.json"
  etag   = filemd5("${path.module}/../../dashboards/wordpress-overview.json")

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_s3_object" "daily_report_script" {
  bucket = aws_s3_bucket.monitoring_assets.id
  key    = "scripts/daily-reliability-report.py"
  source = "${path.module}/../../scripts/daily-reliability-report.py"
  etag   = filemd5("${path.module}/../../scripts/daily-reliability-report.py")

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# Dedicated t2.micro monitoring EC2 running Prometheus + Grafana via Docker Compose.
# Placed in a public subnet with a public IP so it can pull Docker images without
# depending on NAT Gateway availability. Monitoring must stay up if WordPress infra degrades.
resource "aws_instance" "monitoring" {
  ami                         = data.aws_ssm_parameter.amazon_linux_2.value
  instance_type               = var.instance_type
  subnet_id                   = var.public_subnet_ids[0]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.monitoring_ec2.name
  vpc_security_group_ids      = [var.monitoring_sg_id]

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    cluster_name              = var.cluster_name
    environment               = var.environment
    aws_region                = var.aws_region
    grafana_admin_password    = var.grafana_admin_password
    rds_identifier            = var.rds_identifier
    alb_arn_suffix            = var.alb_arn_suffix
    tg_arn_suffix             = var.tg_arn_suffix
    monitoring_assets_bucket  = aws_s3_bucket.monitoring_assets.id
    sns_topic_arn             = var.sns_topic_arn
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    http_tokens                 = "optional"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-monitoring"
    Project     = var.project_name
    Environment = var.environment
    Role        = "monitoring"
  }

  depends_on = [
    aws_s3_object.grafana_dashboard,
    aws_s3_object.daily_report_script,
  ]
}

# Register the monitoring EC2 with the Grafana ALB target group.
resource "aws_lb_target_group_attachment" "grafana" {
  target_group_arn = var.grafana_target_group_arn
  target_id        = aws_instance.monitoring.id
  port             = 3000
}
