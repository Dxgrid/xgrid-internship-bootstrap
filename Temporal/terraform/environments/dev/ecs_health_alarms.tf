# Real-time "service is DOWN" alarms.
#
# CloudWatch alarms on ECS Container Insights `RunningTaskCount` per service.
# Fires when a critical service drops to 0 running tasks and emails via the
# existing SNS topic. These are AWS-native and INDEPENDENT of the Prometheus/
# AlertManager stack — so they still fire even if the monitoring stack itself is
# down (which the Prometheus TemporalWorkerDown/ServerDown alerts cannot do).
#
# Covers the components that have no other down-signal — notably the Temporal UI,
# which exposes no metrics endpoint and is otherwise invisible to Prometheus.

locals {
  # label => ECS service name (as reported by Container Insights ServiceName dim)
  critical_services = {
    "temporal-server" = "temporal-order-temporal-server"
    "worker"          = "temporal-order-worker"
    "temporal-ui"     = "temporal-order-temporal-ui"
    "api"             = "temporal-order-api"
    "prometheus"      = "temporal-order-dev-prometheus"
    "grafana"         = "temporal-order-dev-grafana"
  }
}

resource "aws_cloudwatch_metric_alarm" "service_down" {
  for_each = local.critical_services

  alarm_name        = "${local.project_name}-${local.environment}-${each.key}-DOWN"
  alarm_description  = "${each.key} (${each.value}) has 0 running tasks — service is DOWN."

  namespace   = "ECS/ContainerInsights"
  metric_name = "RunningTaskCount"
  dimensions = {
    ClusterName = module.ecs_cluster.cluster_name
    ServiceName = each.value
  }

  # Minimum over 1-minute periods; fires after 2 consecutive minutes at 0 tasks
  # (rides out normal rolling-deploy task churn, catches a real outage in ~2 min).
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1

  # If the metric disappears entirely (service deleted / totally gone), treat that
  # as DOWN rather than "insufficient data".
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.alarms.arn] # email on DOWN
  ok_actions    = [aws_sns_topic.alarms.arn] # email on RECOVERED

  tags = {
    Project     = local.project_name
    Environment = local.environment
  }
}
