# One-time setup, applied from a laptop (see README). Everything here must outlive
# "demo down": the Terraform state bucket and the role GitHub Actions assumes.
#
# State for this root stays local: it is two resources that change ~never.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "github_repo" {
  description = "Only workflows on this repo's main branch may assume the deploy role."
  type        = string
  default     = "ar-ecommerce-backend/infra-live"
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { project = "ecom", managed-by = "terraform" }
  }
}

data "aws_caller_identity" "current" {}

# --- Terraform state -------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = "ecom-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- GitHub Actions -> AWS without stored keys (OIDC) -----------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "github_deploy" {
  name = "github-actions-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

# ponytail: admin, because this role runs terraform over VPC/IAM/RDS/ECS. The trust
# above limits it to workflows on infra-live's main branch (merged via PR). Split into
# a read-only plan role + scoped apply role if anyone else gets write access to the org.
resource "aws_iam_role_policy_attachment" "github_deploy_admin" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# --- Cost alerts ------------------------------------------------------------------
# Alerts only - AWS has no hard cap on this account type. The hourly auto-shutdown
# workflow is what actually stops spend; these emails catch it if that ever breaks.

variable "alert_email" {
  description = "Where budget alerts go. Asked for at apply time, never committed."
  type        = string
}

resource "aws_budgets_budget" "monthly" {
  name         = "ecom-monthly"
  budget_type  = "COST"
  limit_amount = "20"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [50, 75, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "deploy_role_arn" {
  value = aws_iam_role.github_deploy.arn
}
