# GitHub Actions -> AWS with short-lived OIDC credentials. No long-lived
# access keys exist anywhere (not in GitHub secrets, not on disk).

locals {
  github_oidc_url = "token.actions.githubusercontent.com"

  github_oidc_provider_arn = (
    var.github_oidc_provider_arn != ""
    ? var.github_oidc_provider_arn
    : aws_iam_openid_connect_provider.github[0].arn
  )

  github_owner               = split("/", var.github_repo)[0]
  github_name                = split("/", var.github_repo)[1]
  github_oidc_subject_prefix = "repo:${local.github_owner}@${var.github_owner_id}/${local.github_name}@${var.github_repo_id}"

  ecs_service_arn = "arn:${local.partition}:ecs:${var.region}:${local.account_id}:service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
}

# One provider per account per URL; set github_oidc_provider_arn to reuse an
# existing one instead of creating it. No thumbprint: AWS validates GitHub's
# certificate against its trusted root CAs.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.github_oidc_provider_arn == "" ? 1 : 0

  url            = "https://${local.github_oidc_url}"
  client_id_list = ["sts.amazonaws.com"]
}

# ---------- Trust: ONLY this repo's `production` environment ----------
# GitHub's immutable subject embeds numeric owner/repo IDs:
#   repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:production
# so a renamed, deleted-and-recreated, or squatted repo with the same name
# can't obtain these credentials. PR jobs, other branches (blocked by the
# environment's branch policy), forks and other repos are refused.

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_url}:sub"
      values   = ["${local.github_oidc_subject_prefix}:environment:production"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.name}-github-deploy"
  description          = "Assumed by GitHub Actions (${var.github_repo}, environment production) to release to ECS"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

# ---------- Permissions: exactly what build + deploy.sh call ----------

data "aws_iam_policy_document" "deploy" {
  # GetAuthorizationToken has no resource-level permissions: AWS requires "*".
  # It only returns a registry login token; push rights are scoped below.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushThisRepoOnly"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages", # resolve the pushed tag to its sha256 digest
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid       = "EcsDeployThisServiceOnly"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = [local.ecs_service_arn]
  }

  # Describe/RegisterTaskDefinition do not support resource-level permissions
  # (AWS requires "*"). Registering a revision changes nothing by itself; only
  # UpdateService (scoped above) can put it into service, and PassRole (below)
  # limits which roles a new revision can carry.
  statement {
    sid       = "EcsTaskDefinitions"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }

  # A task definition names its roles; registering one requires PassRole.
  # Only our two task roles, and only to ECS tasks: the pipeline can't hand
  # any other role (e.g. an admin role) to a container.
  statement {
    sid       = "PassOnlyTaskRolesToEcsTasks"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.execution.arn, aws_iam_role.task.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # Release bookkeeping. SecureString with the AWS-managed aws/ssm key needs no
  # kms:* grant here (that key's policy allows use via SSM within the account).
  statement {
    sid     = "SsmDigestParamsOnly"
    actions = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [
      aws_ssm_parameter.image_current.arn,
      aws_ssm_parameter.image_last_known_good.arn,
    ]
  }

  # Bake window reads alarm state. Scoped to the two rollback alarms
  # (tighter than account-wide DescribeAlarms).
  statement {
    sid     = "ReadRollbackAlarmsOnly"
    actions = ["cloudwatch:DescribeAlarms"]
    resources = [
      aws_cloudwatch_metric_alarm.target_5xx.arn,
      aws_cloudwatch_metric_alarm.target_p99_latency.arn,
    ]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "release-to-ecs"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
