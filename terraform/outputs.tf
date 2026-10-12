output "alb_url" {
  description = "Application URL."
  value       = "${local.https_enabled ? "https" : "http"}://${aws_lb.main.dns_name}"
}

output "ecs_cluster" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service" {
  description = "ECS service name."
  value       = aws_ecs_service.app.name
}

output "rollback_alarm_names" {
  description = "CloudWatch alarms ECS (and deploy.sh's bake window) watch for rollback."
  value       = [aws_cloudwatch_metric_alarm.target_5xx.alarm_name, aws_cloudwatch_metric_alarm.target_p99_latency.alarm_name]
}

# Everything the workflow needs, as GitHub `production` environment variables.
# None of these are secrets (the role ARN is useless without a GitHub OIDC
# token for this repo's production environment).
output "github_environment_variables" {
  description = "Set these as variables on the GitHub `production` environment."
  value = {
    AWS_REGION        = var.region
    AWS_DEPLOY_ROLE   = aws_iam_role.deploy.arn
    ECR_REPOSITORY    = aws_ecr_repository.app.repository_url
    ECS_CLUSTER       = aws_ecs_cluster.main.name
    ECS_SERVICE       = aws_ecs_service.app.name
    SSM_IMAGE_CURRENT = aws_ssm_parameter.image_current.name
    SSM_IMAGE_LKG     = aws_ssm_parameter.image_last_known_good.name
    ROLLBACK_ALARMS   = join(" ", [aws_cloudwatch_metric_alarm.target_5xx.alarm_name, aws_cloudwatch_metric_alarm.target_p99_latency.alarm_name])
  }
}
