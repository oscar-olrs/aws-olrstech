output "site_url" {
  value = local.url
}

output "site_s3_bucket" {
  description = "Private S3 bucket containing the onboarding application"
  value       = aws_s3_bucket.site.id
}

output "user_pool_id" {
  value = aws_cognito_user_pool.admins.id
}

output "windows_instance_id" {
  value = data.aws_instance.dc.id
}

output "ssm_document_name" {
  value = aws_ssm_document.onboard.name
}

output "api_url" {
  value = aws_apigatewayv2_api.api.api_endpoint
}

