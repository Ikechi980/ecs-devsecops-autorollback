# Private connectivity to the AWS APIs Fargate tasks need, instead of a NAT
# gateway. Tasks get no internet path at all.
#   ecr.api + ecr.dkr : image manifest/auth
#   s3 (gateway)      : image layers (ECR stores them in S3)
#   logs              : awslogs driver

locals {
  interface_endpoints = toset(["ecr.api", "ecr.dkr", "logs"])
}

resource "aws_security_group" "endpoints" {
  name        = "${var.name}-vpc-endpoints"
  description = "HTTPS from private subnets to interface VPC endpoints"
  vpc_id      = aws_vpc.main.id

  # No egress rules: endpoint ENIs only answer inbound connections.
  tags = { Name = "${var.name}-vpc-endpoints" }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  for_each = toset(local.private_subnet_cidrs)

  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from private subnet ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

# Only principals from this account may use the endpoints, so they can't be
# used to reach (or exfiltrate to) another account's resources.
data "aws_iam_policy_document" "endpoint_same_account" {
  statement {
    actions   = ["*"]
    resources = ["*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  policy              = data.aws_iam_policy_document.endpoint_same_account.json

  tags = { Name = "${var.name}-${each.value}" }
}

# S3 gateway endpoint (free). Restricted to the bucket ECR serves image
# layers from; nothing else in S3 is reachable from the private subnets.
data "aws_iam_policy_document" "s3_ecr_layers_only" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::prod-${var.region}-starport-layer-bucket/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  policy            = data.aws_iam_policy_document.s3_ecr_layers_only.json

  tags = { Name = "${var.name}-s3" }
}
