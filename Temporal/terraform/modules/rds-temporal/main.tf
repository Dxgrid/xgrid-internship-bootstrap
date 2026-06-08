# PostgreSQL RDS Instance for Temporal Workflow Execution History
# Separate from Week 3 WordPress database for clean data isolation
# Schema migration handled by temporal-sql-tool one-shot ECS task

# Stable random suffix for final snapshot — avoids perpetual diff caused by timestamp()
resource "random_id" "rds_snapshot_suffix" {
  byte_length = 4
}

# DB Parameter Group for PostgreSQL 15
resource "aws_db_parameter_group" "temporal" {
  family      = "postgres15"
  name_prefix = "${var.project_name}-${var.environment}-pg15-"
  description = "Parameter group for Temporal PostgreSQL database"

  parameter {
    name         = "max_connections"
    value        = "100"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "shared_buffers"
    value        = "{DBInstanceClassMemory/32768}"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "log_statement"
    value        = "all"
    apply_method = "immediate"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-temporal-pg"
    Environment = var.environment
  }
}

# DB Subnet Group — Private subnets only
resource "aws_db_subnet_group" "temporal" {
  name        = "${var.project_name}-${var.environment}-temporal-db-subnet-group"
  subnet_ids  = var.private_subnet_ids
  description = "Subnet group for Temporal RDS instance (private subnets only)"

  tags = {
    Name        = "${var.project_name}-${var.environment}-temporal-db-subnet-group"
    Environment = var.environment
  }
}

# RDS PostgreSQL Instance
resource "aws_db_instance" "temporal" {
  identifier            = "${var.project_name}-${var.environment}-temporal-db"
  engine                = "postgres"
  engine_version        = "15.17"
  instance_class        = "db.t3.micro"  # Free tier
  allocated_storage     = 20             # GiB, free tier includes 20 GiB
  # gp3 provides 3000 IOPS and 125 MB/s baseline at the same cost as gp2
  storage_type          = "gp3"
  storage_encrypted     = true

  # Database credentials — db_name intentionally omitted; auto-setup creates temporal + temporal_visibility
  username = var.db_username
  password = var.db_password

  # Network & Security
  db_subnet_group_name            = aws_db_subnet_group.temporal.name
  vpc_security_group_ids          = [var.rds_sg_id]
  publicly_accessible             = false
  availability_zone               = null  # Let AWS choose
  multi_az                        = false # Free tier — no multi-AZ

  # Backup & Maintenance
  backup_retention_period         = 7
  backup_window                   = "03:00-04:00"
  maintenance_window              = "sun:04:00-sun:05:00"
  auto_minor_version_upgrade      = true
  copy_tags_to_snapshot           = true

  # Enhanced Monitoring
  enabled_cloudwatch_logs_exports = ["postgresql"]
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_monitoring.arn

  # Database Parameters
  parameter_group_name = aws_db_parameter_group.temporal.name

  # Deletion Protection
  deletion_protection = false  # Change to true in production
  skip_final_snapshot = true # clean teardown — no final snapshot (data is reproducible from code)
  final_snapshot_identifier = "${var.project_name}-${var.environment}-temporal-final-${random_id.rds_snapshot_suffix.hex}"

  tags = {
    Name        = "${var.project_name}-${var.environment}-temporal-db"
    Environment = var.environment
  }

  depends_on = [aws_iam_role_policy_attachment.rds_monitoring]
}

# IAM Role for RDS Enhanced Monitoring
resource "aws_iam_role" "rds_monitoring" {
  name_prefix = "${var.project_name}-${var.environment}-rds-mon-"
  description = "Role for RDS enhanced monitoring to CloudWatch"

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
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# CloudWatch Alarms for RDS

# CPU Utilization
resource "aws_cloudwatch_metric_alarm" "temporal_cpu" {
  alarm_name          = "${var.project_name}-${var.environment}-temporal-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.temporal.id
  }

  alarm_description = "Alert when Temporal RDS CPU exceeds 80%"
}

resource "aws_cloudwatch_metric_alarm" "temporal_connections" {
  alarm_name          = "${var.project_name}-${var.environment}-temporal-connections"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.temporal.id
  }

  alarm_description = "Alert when Temporal RDS connections exceed 80"
}

resource "aws_cloudwatch_metric_alarm" "temporal_storage" {
  alarm_name          = "${var.project_name}-${var.environment}-temporal-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 2147483648  # 2 GB in bytes
  alarm_actions       = [var.alarm_sns_topic_arn]

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.temporal.id
  }

  alarm_description = "Alert when Temporal RDS free storage drops below 2 GB"
}
