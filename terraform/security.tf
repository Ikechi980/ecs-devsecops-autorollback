locals {
  ecs_log_group_name = "/ecs/${var.name}"
}

# Encryption at rest uses AWS-managed / service-owned keys (no customer-managed
# KMS key, which costs $1/month + requests). Trade-off: no custom key policy,
# rotation schedule, or crypto-shredding. See README "hardening" list.

# ---------- ECR ----------

resource "aws_ecr_repository" "app" {
  name                 = var.name
  image_tag_mutability = "IMMUTABLE" # a tag can never be repointed at different bits
  force_delete         = false       # refuse to destroy a repo that still has images

  image_scanning_configuration {
    scan_on_push = true
  }

  # KMS with no key given = AWS-managed aws/ecr key (no monthly key fee).
  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 30 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

# ---------- SSM: release state owned by the pipeline ----------
# Terraform creates these once; deploy.sh writes the values. ignore_changes
# stops terraform from reverting a release back to "bootstrap".

resource "aws_ssm_parameter" "image_current" {
  name        = "/${var.name}/image/current"
  description = "Image digest (repo@sha256:...) currently being deployed"
  type        = "String"
  value       = "bootstrap"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "image_last_known_good" {
  name        = "/${var.name}/image/last-known-good"
  description = "Image digest of the last release that passed rollout + bake"
  type        = "String"
  value       = "bootstrap"

  lifecycle {
    ignore_changes = [value]
  }
}

# ---------- Logs ----------

resource "aws_cloudwatch_log_group" "ecs" {
  name              = local.ecs_log_group_name
  retention_in_days = var.log_retention_days
  # No kms_key_id: encrypted at rest with a CloudWatch-owned key (free).
}
