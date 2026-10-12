variable "name" {
  description = "Name prefix for every resource (ECR repo, log group, SSM paths, ...)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name))
    error_message = "name must be 3-31 chars: lowercase letters, digits, hyphens; start with a letter."
  }
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR for the dedicated VPC. Must not overlap networks you may peer with."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid IPv4 CIDR of /20 or larger."
  }
}

variable "availability_zone_ids" {
  description = "AZ IDs to use (IDs, not names: names map to different physical AZs per account). ALB and tasks share these AZs."
  type        = list(string)
  default     = ["use1-az2", "use1-az4"] # us-east-1a / us-east-1b in this account

  validation {
    condition     = length(var.availability_zone_ids) >= 2 && length(var.availability_zone_ids) <= 3
    error_message = "Provide 2 or 3 AZ IDs (ALB requires at least 2)."
  }
}

variable "github_repo" {
  description = "GitHub repo allowed to deploy, as owner/name."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must be in owner/name form."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention for app and VPC flow logs."
  type        = number
  default     = 365
}

variable "allowed_ingress_cidrs" {
  description = "IPv4 CIDRs allowed to reach the ALB on 80/443. Narrow this to your IP for a private demo."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0 && alltrue([for c in var.allowed_ingress_cidrs : can(cidrnetmask(c))])
    error_message = "allowed_ingress_cidrs must be a non-empty list of valid IPv4 CIDRs."
  }
}

variable "certificate_arn" {
  description = "ACM certificate ARN. Empty = HTTP only; set = HTTP redirects to HTTPS."
  type        = string
  default     = ""

  validation {
    condition     = var.certificate_arn == "" || can(regex("^arn:aws[a-z-]*:acm:", var.certificate_arn))
    error_message = "certificate_arn must be empty or an ACM certificate ARN."
  }
}

variable "alb_deletion_protection" {
  description = "Block ALB deletion. Keep true in production; set false to allow terraform destroy."
  type        = bool
  default     = true
}

variable "desired_count" {
  description = "Number of running tasks (one per AZ by default)."
  type        = number
  default     = 2
}

variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory (MiB)."
  type        = number
  default     = 512
}

variable "alarm_5xx_threshold" {
  description = "Target 5xx count per minute that (for 2 consecutive minutes) triggers rollback."
  type        = number
  default     = 5

  validation {
    condition     = var.alarm_5xx_threshold >= 1
    error_message = "alarm_5xx_threshold must be at least 1."
  }
}

variable "alarm_p99_latency_seconds" {
  description = "p99 target response time (seconds) that (2 of 3 minutes) triggers rollback."
  type        = number
  default     = 1

  validation {
    condition     = var.alarm_p99_latency_seconds > 0
    error_message = "alarm_p99_latency_seconds must be positive."
  }
}

variable "github_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider to reuse. Empty = create one (only one per account is allowed)."
  type        = string
  default     = ""

  validation {
    condition     = var.github_oidc_provider_arn == "" || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "Must be empty or a token.actions.githubusercontent.com OIDC provider ARN."
  }
}

# Numeric IDs for GitHub's immutable OIDC subject. Find them with:
#   gh api repos/<owner>/<repo> --jq '"repo_id=\(.id) owner_id=\(.owner.id)"'
variable "github_owner_id" {
  description = "Numeric ID of the GitHub repo owner (immutable OIDC subject)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be numeric."
  }
}

variable "github_repo_id" {
  description = "Numeric ID of the GitHub repo (immutable OIDC subject)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repo_id))
    error_message = "github_repo_id must be numeric."
  }
}
