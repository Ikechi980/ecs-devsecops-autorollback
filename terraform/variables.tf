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

variable "az_count" {
  description = "Number of AZs. ALB and tasks always share the same AZs."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3 (ALB requires at least 2)."
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
