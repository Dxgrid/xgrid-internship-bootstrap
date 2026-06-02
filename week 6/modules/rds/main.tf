# Custom parameter group for MySQL 8.0 with performance and logging optimizations.
resource "aws_db_parameter_group" "main" {
  family      = "mysql8.0"
  name_prefix = "${var.project_name}-${var.environment}-mysql8-"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "2"
  }

  parameter {
    name  = "log_output"
    value = "FILE"
  }

  parameter {
    name  = "general_log"
    value = "0"
  }

  parameter {
    name  = "max_connections"
    value = "100"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-pg"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Database subnet group restricted to private subnets only.
resource "aws_db_subnet_group" "main" {
  name        = "${var.project_name}-${var.environment}-db-subnet-group"
  subnet_ids  = var.private_subnet_ids
  description = "Subnet group for ${var.project_name}-${var.environment} RDS instance"

  tags = {
    Name        = "${var.project_name}-${var.environment}-db-subnet-group"
    Project     = var.project_name
    Environment = var.environment
  }
}

# IAM role allowing RDS to send enhanced monitoring metrics to CloudWatch.
resource "aws_iam_role" "rds_monitoring" {
  name_prefix = "${var.project_name}-${var.environment}-rds-mon-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRDSMonitoring"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-${var.environment}-rds-monitoring-role"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# RDS MySQL instance using free tier eligible t3.micro and encrypted storage.
resource "aws_db_instance" "main" {
  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = "db.t3.micro"
  parameter_group_name = aws_db_parameter_group.main.name

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]
  publicly_accessible    = false

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project_name}-${var.environment}-final" # must be unique; delete existing snapshot if re-running destroy

  maintenance_window         = "mon:04:00-mon:04:30"
  auto_minor_version_upgrade = true
  apply_immediately          = false

  multi_az            = false
  deletion_protection = var.deletion_protection

  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]

  tags = {
    Name        = "${var.project_name}-${var.environment}-mysql"
    Project     = var.project_name
    Environment = var.environment
  }
}

# CloudWatch alarms for monitoring RDS health including CPU, storage, and connection limits.
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.project_name}-${var.environment}-rds-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 70

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.identifier
  }

  alarm_description         = "RDS CPU utilization above 70% for 15 minutes (warning — check for slow queries)"
  treat_missing_data        = "breaching"
  alarm_actions             = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  insufficient_data_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  tags = {
    Name        = "${var.project_name}-${var.environment}-rds-alarm-cpu"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.project_name}-${var.environment}-rds-low-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 2000000000

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.identifier
  }

  alarm_description         = "RDS free storage below 2GB"
  treat_missing_data        = "breaching"
  alarm_actions             = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  insufficient_data_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  tags = {
    Name        = "${var.project_name}-${var.environment}-rds-alarm-storage"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.project_name}-${var.environment}-rds-high-connections"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 60

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.identifier
  }

  alarm_description         = "RDS connections above 60 (70% of max_connections≈85 for t3.micro; prevents connection exhaustion)"
  treat_missing_data        = "breaching"
  alarm_actions             = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  insufficient_data_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  tags = {
    Name        = "${var.project_name}-${var.environment}-rds-alarm-connections"
    Project     = var.project_name
    Environment = var.environment
  }
}
