# Application Load Balancer for Temporal Order Management System
# Serves API on port 8000 and Temporal Web UI on port 8080
# Separate from Week 3's WordPress ALB for clean separation

resource "aws_lb" "temporal" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false
  idle_timeout               = 60

  tags = {
    Name        = "${var.project_name}-${var.environment}-alb"
    Environment = var.environment
  }
}

# Target Group for API (port 8000)
resource "aws_lb_target_group" "api" {
  name_prefix = "api-"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }

  deregistration_delay = 30

  tags = {
    Name        = "${var.project_name}-${var.environment}-api-tg"
    Environment = var.environment
  }
}

# Target Group for Temporal UI (port 8080)
resource "aws_lb_target_group" "temporal_ui" {
  name_prefix = "ui-"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/"
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = "200,301,302"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }

  deregistration_delay = 30

  tags = {
    Name        = "${var.project_name}-${var.environment}-ui-tg"
    Environment = var.environment
  }
}

# Target Group for Grafana (port 3000) — awsvpc tasks register by IP.
resource "aws_lb_target_group" "grafana" {
  name_prefix = "graf-"
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

  tags = {
    Name        = "${var.project_name}-${var.environment}-grafana-tg"
    Environment = var.environment
  }
}

# HTTP Listener on Port 8000 for API
resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.temporal.arn
  port              = "8000"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# HTTP Listener on Port 8080 for Temporal UI
resource "aws_lb_listener" "temporal_ui" {
  load_balancer_arn = aws_lb.temporal.arn
  port              = "8080"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.temporal_ui.arn
  }
}

# HTTP Listener on Port 80 for Grafana (monitoring UI)
resource "aws_lb_listener" "grafana" {
  load_balancer_arn = aws_lb.temporal.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}

# HTTP Listener on Port 8443 for Grafana (alternative — corporate firewalls often allow 8443)
# Use this if port 80 is blocked by your network's firewall
resource "aws_lb_listener" "grafana_alt" {
  load_balancer_arn = aws_lb.temporal.arn
  port              = "8443"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}

# CloudWatch Alarm — Unhealthy hosts in API target group
resource "aws_cloudwatch_metric_alarm" "api_unhealthy_hosts" {
  alarm_name          = "${var.project_name}-${var.environment}-api-unhealthy"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  dimensions = {
    TargetGroup  = aws_lb_target_group.api.arn_suffix
    LoadBalancer = aws_lb.temporal.arn_suffix
  }

  alarm_description = "Alert when API target group has unhealthy hosts"
}

resource "aws_cloudwatch_metric_alarm" "temporal_ui_unhealthy_hosts" {
  alarm_name          = "${var.project_name}-${var.environment}-temporal-ui-unhealthy"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_actions       = [var.alarm_sns_topic_arn]
  ok_actions          = [var.alarm_sns_topic_arn]

  dimensions = {
    TargetGroup  = aws_lb_target_group.temporal_ui.arn_suffix
    LoadBalancer = aws_lb.temporal.arn_suffix
  }

  alarm_description = "Alert when Temporal UI target group has unhealthy hosts"
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx_errors" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_actions       = [var.alarm_sns_topic_arn]

  dimensions = {
    LoadBalancer = aws_lb.temporal.arn_suffix
  }

  alarm_description = "Alert when ALB sees more than 5 target 5xx errors in 2 minutes"
}
