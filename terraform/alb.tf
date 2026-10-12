locals {
  container_port = 8080
  https_enabled  = var.certificate_arn != ""
}

# ---------- Security group ----------

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public HTTP(S) in; only the container port out to the private subnets"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

# 443 is opened only when an HTTPS listener exists (least privilege).
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = local.https_enabled ? toset(var.allowed_ingress_cidrs) : toset([])

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

# Egress limited to the container port, and only toward the private subnets
# where tasks live (tighter than the whole VPC CIDR).
resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  for_each = toset(local.private_subnet_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "To tasks on ${local.container_port} in ${each.value}"
  ip_protocol       = "tcp"
  from_port         = local.container_port
  to_port           = local.container_port
  cidr_ipv4         = each.value
}

# ---------- Load balancer ----------

resource "aws_lb" "main" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]

  drop_invalid_header_fields = true        # reject malformed headers (request smuggling)
  desync_mitigation_mode     = "strictest" # block ambiguous requests outright
  enable_deletion_protection = var.alb_deletion_protection
  enable_http2               = true
  idle_timeout               = 60

  tags = { Name = "${var.name}-alb" }
}

resource "aws_lb_target_group" "app" {
  name                 = "${var.name}-tg"
  target_type          = "ip" # required for Fargate awsvpc networking
  protocol             = "HTTP"
  port                 = local.container_port
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30 # drain quickly; requests are short-lived

  health_check {
    enabled             = true
    path                = "/health"
    matcher             = "200"
    protocol            = "HTTP"
    port                = "traffic-port"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${var.name}-tg" }
}

# ---------- Listeners ----------

# HTTP: forwards when there is no certificate; otherwise only redirects.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.https_enabled ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.app.arn
    }
  }

  dynamic "default_action" {
    for_each = local.https_enabled ? [1] : []
    content {
      type = "redirect"
      redirect {
        protocol    = "HTTPS"
        port        = "443"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06" # TLS 1.3 + 1.2 only
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
