terraform {
  required_version = ">= 1.10.0" # S3 native state locking (use_lockfile)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }

  # Remote state: versioned, encrypted, TLS-only bucket with public access
  # blocked. use_lockfile = S3-native locking (no DynamoDB table needed).
  backend "s3" {
    bucket       = "kamsichiamaka"
    key          = "ecs-devsecops-autorollback/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.name
      ManagedBy = "terraform"
      Repo      = var.github_repo
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
