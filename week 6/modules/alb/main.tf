locals {
  default_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_lb" "main" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false
  idle_timeout               = var.idle_timeout

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-alb"
  })
}

# Target group for demo app ECS tasks. target_type=ip required for awsvpc networking.
resource "aws_lb_target_group" "app" {
  name_prefix = "app-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = var.health_check_path
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = var.health_check_matcher
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }

  deregistration_delay = 30

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-app-tg"
  })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# target_type=ip required because Grafana runs as an awsvpc ECS task — ALB registers task IPs, not EC2 instance IDs.
resource "aws_lb_target_group" "grafana" {
  name_prefix = "gf-tg-"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/api/health"
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }

  deregistration_delay = 30

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.default_tags, {
    Name = "${var.project_name}-${var.environment}-grafana-tg"
  })
}

# Path-based rule routing /grafana* traffic to the Grafana ECS service.
# Priority 10 ensures evaluation before the default app forward.
resource "aws_lb_listener_rule" "grafana" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  condition {
    path_pattern {
      values = ["/grafana", "/grafana/*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}

# Fires when 5xx rate > 0.5% — the SLO breach boundary for 99.5% availability.
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 0.5
  alarm_description   = "ALB 5xx error rate > 0.5% for 2 minutes (SLO breach boundary for 99.5% availability)"
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "e1"
    return_data = false
    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.main.arn_suffix
      }
    }
  }

  metric_query {
    id          = "r1"
    return_data = false
    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.main.arn_suffix
      }
    }
  }

  metric_query {
    id          = "error_rate"
    expression  = "IF(r1 > 0, e1/r1*100, 0)"
    label       = "5xx Error Rate %"
    return_data = true
  }

  alarm_actions             = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  ok_actions                = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  insufficient_data_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-unhealthy-hosts"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "One or more ECS tasks failing ALB health checks"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }

  alarm_actions             = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  ok_actions                = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  insufficient_data_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
}

# Alarm on traffic drop — fewer than 5 requests/minute indicates upstream failure or DNS issue.
resource "aws_cloudwatch_metric_alarm" "alb_traffic_drop" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-traffic-drop"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "RequestCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "ALB receiving fewer than 5 requests/min for 3 minutes (possible upstream failure or DNS issue)"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  alarm_actions             = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  ok_actions                = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  insufficient_data_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
}
