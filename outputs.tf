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


