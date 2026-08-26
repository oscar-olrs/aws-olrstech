data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

output "aws_account_id" {
  description = "AWS account ID Terraform is authenticated to"
  value       = data.aws_caller_identity.current.account_id
}

output "aws_caller_arn" {
  description = "AWS ARN Terraform is using for authentication"
  value       = data.aws_caller_identity.current.arn
}

output "aws_region" {
  description = "AWS region Terraform is configured to use"
  value       = data.aws_region.current.region
}