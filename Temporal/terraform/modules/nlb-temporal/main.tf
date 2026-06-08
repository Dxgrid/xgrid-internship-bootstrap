# Internal Network Load Balancer for Temporal gRPC (port 7233)
# NLB (Layer 4 TCP) is required because Temporal Workers use long-polling —
# ALB's 60-second idle timeout kills these connections and returns 502.
# NLB passes raw TCP packets through with no timeout interference.

resource "aws_lb" "temporal_internal" {
  name               = "${var.project_name}-${var.environment}-temporal-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids

  # The temporal-server runs as a single task pinned to one AZ (distinctInstance,
  # desired=1). Without cross-zone, an NLB node only routes to targets in its own
  # AZ — so any client task (worker/API/UI) in the OTHER AZ times out connecting
  # to 7233. Cross-zone makes every node route to the one healthy target.
  enable_cross_zone_load_balancing = true

  enable_deletion_protection = false

  tags = {
    Name        = "${var.project_name}-${var.environment}-temporal-nlb"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Target group — TCP passthrough on gRPC port 7233.
# target_type = "ip": the temporal-server runs in awsvpc, so the NLB registers and
# health-checks the task's ENI IP directly on 7233 — no bridge host-port DNAT/FORWARD
# path (that path was unreachable off-host and caused the server to flap).
resource "aws_lb_target_group" "temporal_grpc" {
  name        = "${var.project_name}-${var.environment}-tgrpc"
  port        = 7233
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # Disable client IP preservation — keeps the NLB hairpin fix for any client task
  # co-located with the server target (NLB SNATs to its own IP).
  preserve_client_ip = false

  health_check {
    protocol            = "TCP"
    port                = 7233
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-temporal-grpc-tg"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Listener — pure TCP passthrough, no SSL termination
resource "aws_lb_listener" "temporal_grpc" {
  load_balancer_arn = aws_lb.temporal_internal.arn
  port              = 7233
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.temporal_grpc.arn
  }
}
