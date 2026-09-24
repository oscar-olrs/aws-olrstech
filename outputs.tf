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

output "vpc_id" {
  description = "ID of the OLRS Tech VPC"
  value       = aws_vpc.main.id
}


output "public_subnet_id" {
  description = "ID of the OLRS public edge subnet"
  value       = aws_subnet.edge_a.id
}

output "private_subnet_id" {
  description = "ID of the OLRS private subnet"
  value       = aws_subnet.private_a.id
}

output "internet_gateway_id" {
  description = "ID of the OLRS Internet Gateway"
  value       = aws_internet_gateway.main.id
}





output "public_route_table_id" {
  description = "ID of the OLRS public route table"
  value       = aws_route_table.public.id
}

output "private_route_table_id" {
  description = "ID of the OLRS private route table"
  value       = aws_route_table.private.id
}




########### Route 53

output "route53_zone_id" {
  description = "Route 53 hosted zone ID for olrstech.com"
  value       = aws_route53_zone.olrstech.zone_id
}

output "route53_name_servers" {
  description = "Route 53 authoritative name servers for olrstech.com"
  value       = aws_route53_zone.olrstech.name_servers
}


########## EC2 Instances

output "ec2_olrs-ts01_id" {
  description = "Instance ID of olrs-ts01"
  value       = aws_instance.ts01.id
}

output "ec2_olrs-dc01_id" {
  description = "Instance ID of olrs-dc01"
  value       = aws_instance.dc01.id
}


########## OLRS Tech Website

output "website_url" {
  description = "Primary OLRS Tech website URL"
  value       = "https://${local.website_domain}"
}

output "website_www_url" {
  description = "WWW OLRS Tech website URL"
  value       = "https://${local.website_www_domain}"
}

output "website_s3_bucket" {
  description = "Private S3 bucket containing OLRS Tech website files"
  value       = aws_s3_bucket.website.id
}

output "website_cloudfront_domain" {
  description = "CloudFront-generated domain name"
  value       = aws_cloudfront_distribution.website.domain_name
}

output "website_cloudfront_distribution_id" {
  description = "CloudFront distribution ID"
  value       = aws_cloudfront_distribution.website.id
}


########### Onboarding S3

data "terraform_remote_state" "onboarding" {
  backend = "s3"

  config = {
    bucket  = "olrs-terraform-state"
    key     = "lab/onboarding/terraform.tfstate"
    region  = "us-west-2"
    profile = "olrstech-admin"
  }
}

output "onboarding_s3_bucket" {
  description = "Private S3 bucket containing the onboarding application"
  value       = data.terraform_remote_state.onboarding.outputs.site_s3_bucket
}
