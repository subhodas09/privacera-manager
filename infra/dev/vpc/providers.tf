provider "aws" {
  region              = var.aws_region
  profile             = var.aws_profile
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = local.common_tags
  }
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
