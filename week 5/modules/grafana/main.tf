# CloudWatch log group for Grafana container logs forwarded from the monitoring EC2.
resource "aws_cloudwatch_log_group" "grafana" {
  name              = "/monitoring/${var.project_name}/${var.environment}/grafana"
  retention_in_days = 7

  tags = {
    Name        = "${var.project_name}-${var.environment}-grafana-logs"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Alarm fires when the Grafana ALB target group reports unhealthy hosts.
# This means the monitoring EC2 or the Grafana container is down.
resource "aws_cloudwatch_metric_alarm" "grafana_unhealthy" {
  alarm_name          = "${var.project_name}-${var.environment}-grafana-unhealthy"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "Grafana monitoring UI is unreachable via the ALB — monitoring EC2 may be down."
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.grafana_tg_arn_suffix
  }

  alarm_actions             = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  ok_actions                = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  insufficient_data_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
}
