# SNS topic for centralized alerting across RDS, ALB, and ECS services.
resource "aws_sns_topic" "wordpress_alerts" {
  name = "${var.project_name}-${var.environment}-alerts"

  tags = {
    Name        = "${var.project_name}-${var.environment}-alerts"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Email subscription for alarm notifications; requires manual confirmation via the link sent by AWS.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.wordpress_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# CloudWatch alarms monitoring ECS performance and availability metrics.
resource "aws_cloudwatch_metric_alarm" "ecs_high_cpu" {
  alarm_name          = "${var.project_name}-${var.environment}-ecs-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "ECS WordPress service CPU above 80% for 10 minutes"

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }

  alarm_actions = [aws_sns_topic.wordpress_alerts.arn]
  ok_actions    = [aws_sns_topic.wordpress_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_high_memory" {
  alarm_name          = "${var.project_name}-${var.environment}-ecs-high-memory"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "ECS WordPress service memory above 80% for 10 minutes"

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }

  alarm_actions = [aws_sns_topic.wordpress_alerts.arn]
  ok_actions    = [aws_sns_topic.wordpress_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_low_task_count" {
  alarm_name          = "${var.project_name}-${var.environment}-ecs-low-task-count"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Average"
  threshold           = 2
  alarm_description   = "ECS running task count below 2 — HA degraded"
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }

  alarm_actions = [aws_sns_topic.wordpress_alerts.arn]
  ok_actions    = [aws_sns_topic.wordpress_alerts.arn]
}

# Composite alarm combining task count and ALB health checks to confirm a critical service outage.
resource "aws_cloudwatch_composite_alarm" "wordpress_service_degraded" {
  alarm_name        = "${var.project_name}-${var.environment}-service-degraded"
  alarm_description = "ECS task count and ALB health checks failing; service completely down."

  alarm_rule = "ALARM(${aws_cloudwatch_metric_alarm.ecs_low_task_count.alarm_name}) AND ALARM(${var.alb_unhealthy_hosts_alarm_name})"

  alarm_actions = [aws_sns_topic.wordpress_alerts.arn]
}

# Unified CloudWatch dashboard providing visibility into ECS, ALB, and RDS metrics.
resource "aws_cloudwatch_dashboard" "wordpress" {
  dashboard_name = "${var.project_name}-${var.environment}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name]
          ]
          period = 300
          stat   = "Average"
          region = "us-east-1"
          title  = "ECS CPU %"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name]
          ]
          period = 300
          stat   = "Average"
          region = "us-east-1"
          title  = "ECS Memory %"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", var.cluster_name, "ServiceName", var.service_name]
          ]
          period = 60
          stat   = "Average"
          region = "us-east-1"
          title  = "Running Tasks"
          view   = "singleValue"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix]
          ]
          period = 60
          stat   = "Sum"
          region = "us-east-1"
          title  = "ALB Requests/min"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix]
          ]
          period = 60
          stat   = "Sum"
          region = "us-east-1"
          title  = "5XX Errors"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix]
          ]
          period = 60
          stat   = "Average"
          region = "us-east-1"
          title  = "Response Time (s)"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds_identifier]
          ]
          period = 300
          stat   = "Average"
          region = "us-east-1"
          title  = "RDS CPU %"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 12
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.rds_identifier]
          ]
          period = 300
          stat   = "Average"
          region = "us-east-1"
          title  = "DB Connections"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 12
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.rds_identifier]
          ]
          period = 300
          stat   = "Average"
          region = "us-east-1"
          title  = "RDS Free Storage (bytes)"
        }
      }
    ]
  })
}
