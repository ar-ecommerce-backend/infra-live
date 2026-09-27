# The whole running platform. Created by "demo up", deleted by "demo down" and by the
# hourly auto-shutdown. Nothing here should need to survive a destroy.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    time   = { source = "hashicorp/time", version = "~> 0.12" }
  }
  # bucket is passed at init: -backend-config="bucket=<bootstrap state_bucket output>"
  backend "s3" {
    key          = "aws/terraform.tfstate"
    region       = "us-east-2"
    use_lockfile = true
  }
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "domain" {
  description = "Registered in Route 53; its certificate is created by bootstrap/."
  type        = string
  default     = "ar-ecommerce-backend.com"
}

variable "image_tag" {
  description = "GHCR tag to run for every service."
  type        = string
  default     = "main"
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { project = "ecom", managed-by = "terraform" }
  }
}

locals {
  name = "ecom"

  # config-server is not deployed: every service imports it as optional (docs ADR 0004)
  # and its native backend reads files that only exist in the local compose setup.
  services = {
    discovery-server     = { port = 8761, db = "" }
    auth-service         = { port = 8081, db = "authdb" }
    user-service         = { port = 8087, db = "userdb" }
    product-service      = { port = 8083, db = "productdb" }
    inventory-service    = { port = 8084, db = "inventorydb" }
    payment-service      = { port = 8085, db = "paymentdb" }
    order-service        = { port = 8082, db = "orderdb" }
    notification-service = { port = 8086, db = "" }
    api-gateway          = { port = 8080, db = "" }
  }

  extra_env = {
    auth-service    = { JWT_ISSUER = "ecommerce-auth", JWT_EXPIRATION_MS = "3600000" }
    payment-service = { PAYMENT_AUTO_DECLINE_ABOVE_CENTS = "500000" }
    api-gateway     = { JWT_ISSUER = "ecommerce-auth" }
  }

  jwt_services = ["auth-service", "api-gateway"]
}

# Stamped at creation; the auto-shutdown workflow destroys the stack once it is old.
resource "time_static" "up_since" {}

output "url" {
  value = "https://${var.domain}"
}

output "up_since" {
  value = time_static.up_since.rfc3339
}
