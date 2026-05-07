# Public Application Load Balancer serving as the entry point for the WordPress service.
resource "aws_lb" "wordpress" {
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

  tags = {
    Name        = "${var.project_name}-${var.environment}-alb"
    Project     = var.project_name
    Environment = var.environment
  }
}

# ALB target group configured for ECS task IP addresses with health check and session stickiness.
resource "aws_lb_target_group" "wordpress" {
  name_prefix = "wp-tg-"
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

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-wp-tg"
    Project     = var.project_name
    Environment = var.environment
  }
}

# HTTP listener routing external traffic to the WordPress target group.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.wordpress.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.wordpress.arn
  }
}

# CloudWatch alarms for ALB monitoring including 5xx errors and unhealthy host counts.
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project_name}-${var.environment}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "ALB receiving 5xx errors from WordPress targets"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.wordpress.arn_suffix
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
    LoadBalancer = aws_lb.wordpress.arn_suffix
    TargetGroup  = aws_lb_target_group.wordpress.arn_suffix
  }

  alarm_actions             = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  ok_actions                = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  insufficient_data_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
}
