locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  ecr_public_cache_prefix = "${var.name}-ecr-public"

  # Bootstrap image: same digest as app/Dockerfile's base, pulled from ECR
  # Public *through our private ECR* (pull-through cache), because tasks have
  # no internet route. Only used until the pipeline's first release.
  bootstrap_image = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com/${local.ecr_public_cache_prefix}/docker/library/python@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1"

  # Tiny stdlib HTTP server: 200 on every path, so the first deploy is healthy
  # before the pipeline exists. deploy.sh deletes `command` on real releases.
  # Logs a startup line and every request (stderr -> awslogs), like gunicorn.
  bootstrap_command = <<-EOT
    import http.server, sys
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            b = b'{"status":"ok","version":"bootstrap"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
    print("bootstrap server listening on 0.0.0.0:8080", file=sys.stderr, flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
  EOT

  container_health_cmd = "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2)"
}

# ---------- ECR pull-through cache (ECR Public) ----------

resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  ecr_repository_prefix = local.ecr_public_cache_prefix
  upstream_registry_url = "public.ecr.aws"
}

# ---------- IAM ----------

# Both roles: only ECS tasks in THIS account may assume them (confused deputy).
data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:ecs:${var.region}:${local.account_id}:*"]
    }
  }
}

# Execution role: used by the ECS agent to pull the image and ship logs.
resource "aws_iam_role" "execution" {
  name               = "${var.name}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The first pull through the cache creates the cached repo and imports the
# image; scoped to the cache prefix only.
data "aws_iam_policy_document" "execution_pull_through" {
  statement {
    actions = [
      "ecr:CreateRepository",
      "ecr:BatchImportUpstreamImage",
    ]
    resources = ["arn:${local.partition}:ecr:${var.region}:${local.account_id}:repository/${local.ecr_public_cache_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "execution_pull_through" {
  name   = "ecr-pull-through-cache"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_pull_through.json
}

# Task role: the app's own AWS identity. Intentionally has no permissions.
resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

# ---------- Cluster ----------

resource "aws_ecs_cluster" "main" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# ---------- Task security group ----------

resource "aws_security_group" "tasks" {
  name        = "${var.name}-tasks"
  description = "App tasks: 8080 from the ALB only; 443 out to AWS endpoints only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name}-tasks" }
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "App port from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
  referenced_security_group_id = aws_security_group.alb.id
}

# Egress 443, but only to the interface endpoints and S3 (ECR image layers)
# rather than 0.0.0.0/0. There is no internet route anyway; this makes the
# intent explicit and survives someone adding a NAT later.
resource "aws_vpc_security_group_egress_rule" "tasks_to_endpoints" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "HTTPS to interface VPC endpoints (ECR, Logs)"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.endpoints.id
}

resource "aws_vpc_security_group_egress_rule" "tasks_to_s3" {
  security_group_id = aws_security_group.tasks.id
  description       = "HTTPS to S3 via gateway endpoint (ECR image layers)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
}

# ---------- Task definition ----------

resource "aws_ecs_task_definition" "app" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  # Keep old revisions ACTIVE: they are rollback targets.
  skip_destroy = true

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # CI builds linux/amd64 images
  }

  # Fargate ephemeral storage mounted at /tmp: the only writable path.
  volume {
    name                = "tmp"
    configure_at_launch = false
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = local.bootstrap_image
    command   = ["python", "-c", local.bootstrap_command]
    essential = true
    user      = "10001:10001"

    readonlyRootFilesystem = true
    privileged             = false
    linuxParameters = {
      capabilities = { add = [], drop = ["ALL"] }
    }

    # Empty lists / hostPort are spelled out because ECS returns them; leaving
    # them implicit causes a perpetual replace diff in terraform plan.
    environment    = []
    systemControls = []
    volumesFrom    = []

    portMappings = [{
      containerPort = local.container_port
      hostPort      = local.container_port
      protocol      = "tcp"
    }]

    mountPoints = [{
      sourceVolume  = "tmp"
      containerPath = "/tmp"
      readOnly      = false
    }]

    healthCheck = {
      command     = ["CMD", "python", "-c", local.container_health_cmd]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 15
    }

    stopTimeout = 30

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "app"
        mode                  = "non-blocking" # logging can never stall the app
        max-buffer-size       = "4m"
      }
    }
  }])
}

# ---------- Service ----------

resource "aws_ecs_service" "app" {
  name             = var.name
  cluster          = aws_ecs_cluster.main.id
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  # Rolling deploy that never drops below full capacity.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Layer 1 of auto-rollback: tasks that keep failing to start or pass health
  # checks trip the breaker and ECS restores the previous task definition.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Layer 2: roll back if a rollback alarm fires while the deployment runs.
  alarms {
    enable   = true
    rollback = true
    alarm_names = [
      aws_cloudwatch_metric_alarm.target_5xx.alarm_name,
      aws_cloudwatch_metric_alarm.target_p99_latency.alarm_name,
    ]
  }

  health_check_grace_period_seconds = 30

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = local.container_port
  }

  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"

  # The pipeline owns releases (deploy.sh registers new task definitions).
  lifecycle {
    ignore_changes = [task_definition]
  }

  # The target group must be attached to a listener before ECS can use it.
  depends_on = [aws_lb_listener.http]
}
