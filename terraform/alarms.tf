# Layer 2 of auto-rollback: ECS watches these alarms during a deployment and
# rolls back if any goes into ALARM. Target-group metrics only measure real
# traffic served by tasks (ALB health checks are not counted).

locals {
  alb_tg_dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name        = "${var.name}-target-5xx"
  alarm_description = "Tasks returned >= ${var.alarm_5xx_threshold} HTTP 5xx per minute for 2 consecutive minutes. Triggers ECS deployment rollback."

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"
  dimensions  = local.alb_tg_dimensions
  statistic   = "Sum"
  period      = 60

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.alarm_5xx_threshold
  evaluation_periods  = 2
  datapoints_to_alarm = 2

  # No traffic = no errors; don't alarm on an idle service.
  treat_missing_data = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "target_p99_latency" {
  alarm_name        = "${var.name}-target-p99-latency"
  alarm_description = "p99 target response time > ${var.alarm_p99_latency_seconds}s in 2 of 3 minutes. Triggers ECS deployment rollback."

  namespace          = "AWS/ApplicationELB"
  metric_name        = "TargetResponseTime"
  dimensions         = local.alb_tg_dimensions
  extended_statistic = "p99"
  period             = 60

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alarm_p99_latency_seconds
  evaluation_periods  = 3
  datapoints_to_alarm = 2

  treat_missing_data = "notBreaching"
}
