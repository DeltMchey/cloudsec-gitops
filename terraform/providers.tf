provider "aws" {
  region = var.aws_region

  # CI uses offline_plan=true, -refresh=false and non-secret dummy credentials.
  # No AWS data sources exist in this configuration, so plan needs no account
  # lookups. Normal execution leaves all provider validation enabled.
  # (skip_get_ec2_platforms existed in aws provider v5 and was removed in v6.)
  skip_credentials_validation = var.offline_plan
  skip_metadata_api_check     = var.offline_plan
  skip_region_validation      = var.offline_plan
  skip_requesting_account_id  = var.offline_plan

  default_tags {
    tags = var.tags
  }
}
