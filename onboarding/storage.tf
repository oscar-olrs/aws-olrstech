resource "aws_dynamodb_table" "records" {

  name         = local.name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  attribute {
    name = "pk"
    type = "S"

  }

  attribute {
    name = "kind"
    type = "S"

  }

  attribute {
    name = "created"
    type = "S"

  }

  global_secondary_index {

    name            = "by-kind"
    hash_key        = "kind"
    range_key       = "created"
    projection_type = "ALL"

  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  deletion_protection_enabled = true

}

resource "aws_s3_bucket" "site" {
  bucket = "${local.name}-site-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "site" {

  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

}

resource "aws_s3_bucket_ownership_controls" "site" {

  bucket = aws_s3_bucket.site.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }


}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {

  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

  }


}

resource "aws_s3_bucket_versioning" "site" {

  bucket = aws_s3_bucket.site.id
  versioning_configuration {
    status = "Enabled"
  }


}

resource "aws_s3_bucket_policy" "site" {

  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17", Statement = [
      {
        Effect = "Allow", Principal = {
          Service = "cloudfront.amazonaws.com"
          }, Action = "s3:GetObject", Resource = "${aws_s3_bucket.site.arn}/*", Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.site.arn
          }

        }

      },
      {
        Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.site.arn, "${aws_s3_bucket.site.arn}/*"], Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }

        }

    }]
    }
  )
  depends_on = [aws_s3_bucket_public_access_block.site]

}

resource "aws_s3_object" "files" {

  for_each      = fileset("${path.module}/site", "*")
  bucket        = aws_s3_bucket.site.id
  key           = each.value
  source        = "${path.module}/site/${each.value}"
  etag          = filemd5("${path.module}/site/${each.value}")
  content_type  = lookup(local.mime, reverse(split(".", each.value))[0], "application/octet-stream")
  cache_control = "no-store"
  depends_on    = [aws_s3_bucket_server_side_encryption_configuration.site]

}

resource "aws_s3_object" "config" {

  bucket = aws_s3_bucket.site.id
  key    = "config.json"
  content = jsonencode({
    siteUrl  = local.url, apiUrl = aws_apigatewayv2_api.api.api_endpoint,
    clientId = aws_cognito_user_pool_client.web.id,
    authUrl  = "https://${aws_cognito_user_pool_domain.admins.domain}.auth.us-west-2.amazoncognito.com"

    }
  )
  content_type  = "application/json"
  cache_control = "no-store"
  depends_on    = [aws_s3_bucket_server_side_encryption_configuration.site]

}

