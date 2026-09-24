# ============================================================
# OLRS Tech Public Website
#
# Architecture:
#
# Route 53
#    |
# CloudFront
#    |
# Origin Access Control
#    |
# Private S3 Bucket
#
# ============================================================


# ============================================================
# LOCAL WEBSITE CONFIGURATION
# ============================================================

locals {
  website_domain     = "olrstech.com"
  website_www_domain = "www.olrstech.com"

  # Globally unique S3 bucket name.
  website_bucket_name = "${var.project_name}-${var.environment}-website-${data.aws_caller_identity.current.account_id}"

  website_mime_types = {
    ".html" = "text/html; charset=utf-8"
    ".css"  = "text/css; charset=utf-8"
    ".js"   = "application/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".svg"  = "image/svg+xml"
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".webp" = "image/webp"
    ".ico"  = "image/x-icon"
    ".txt"  = "text/plain; charset=utf-8"
  }
}


# ============================================================
# S3 WEBSITE ORIGIN
# ============================================================

resource "aws_s3_bucket" "website" {
  bucket = local.website_bucket_name

  tags = {
    Name        = "${var.project_name}-website"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Purpose     = "PublicWebsiteOrigin"
  }
}


# ------------------------------------------------------------
# Block ALL Public S3 Access
# ------------------------------------------------------------

resource "aws_s3_bucket_public_access_block" "website" {
  bucket = aws_s3_bucket.website.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


# ------------------------------------------------------------
# Disable ACL Usage
# ------------------------------------------------------------

resource "aws_s3_bucket_ownership_controls" "website" {
  bucket = aws_s3_bucket.website.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}


# ------------------------------------------------------------
# Enable Versioning
# ------------------------------------------------------------

resource "aws_s3_bucket_versioning" "website" {
  bucket = aws_s3_bucket.website.id

  versioning_configuration {
    status = "Enabled"
  }
}


# ------------------------------------------------------------
# Encrypt Website Objects At Rest
# ------------------------------------------------------------

resource "aws_s3_bucket_server_side_encryption_configuration" "website" {
  bucket = aws_s3_bucket.website.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}


# ------------------------------------------------------------
# Remove Old Versions After 30 Days
# ------------------------------------------------------------

resource "aws_s3_bucket_lifecycle_configuration" "website" {
  bucket = aws_s3_bucket.website.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}


# ============================================================
# ACM CERTIFICATE
# ============================================================

resource "aws_acm_certificate" "website" {
  provider = aws.us_east_1

  domain_name = local.website_domain

  subject_alternative_names = [
    local.website_www_domain
  ]

  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-website-cert"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}


# ------------------------------------------------------------
# ACM DNS Validation
# ------------------------------------------------------------

resource "aws_route53_record" "website_certificate_validation" {
  for_each = {
    for dvo in aws_acm_certificate.website.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = aws_route53_zone.olrstech.zone_id

  name    = each.value.name
  type    = each.value.type
  ttl     = 300
  records = [each.value.record]
}


resource "aws_acm_certificate_validation" "website" {
  provider = aws.us_east_1

  certificate_arn = aws_acm_certificate.website.arn

  validation_record_fqdns = [
    for record in aws_route53_record.website_certificate_validation :
    record.fqdn
  ]
}


# ============================================================
# CLOUDFRONT ORIGIN ACCESS CONTROL
# ============================================================

resource "aws_cloudfront_origin_access_control" "website" {
  name = "${var.project_name}-${var.environment}-website-oac"

  description = "CloudFront access to private OLRS Tech website bucket"

  origin_access_control_origin_type = "s3"

  signing_behavior = "always"
  signing_protocol = "sigv4"
}


# ============================================================
# CLOUDFRONT CACHE POLICY
# ============================================================

data "aws_cloudfront_cache_policy" "website" {
  name = "Managed-CachingOptimized"
}


# ============================================================
# SECURITY HEADERS
# ============================================================

resource "aws_cloudfront_response_headers_policy" "website_security" {
  name = "${var.project_name}-${var.environment}-website-security"

  security_headers_config {

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }

    xss_protection {
      protection = true
      mode_block = true
      override   = true
    }

    content_security_policy {
      content_security_policy = "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'none'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; upgrade-insecure-requests"
      override                = true
    }
  }

  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
      override = true
    }
  }
}


# ============================================================
# CLOUDFRONT DISTRIBUTION
# ============================================================

resource "aws_cloudfront_distribution" "website" {
  enabled         = true
  is_ipv6_enabled = true

  comment = "OLRS Tech public website"

  default_root_object = "index.html"

  aliases = [
    local.website_domain,
    local.website_www_domain
  ]

  price_class  = "PriceClass_100"
  http_version = "http2and3"


  # ----------------------------------------------------------
  # Private S3 Origin
  # ----------------------------------------------------------

  origin {
    domain_name = aws_s3_bucket.website.bucket_regional_domain_name

    origin_id = "olrs-website-s3"

    origin_access_control_id = aws_cloudfront_origin_access_control.website.id
  }


  # ----------------------------------------------------------
  # Cache Behavior
  # ----------------------------------------------------------

  default_cache_behavior {
    target_origin_id = "olrs-website-s3"

    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = [
      "GET",
      "HEAD",
      "OPTIONS"
    ]

    cached_methods = [
      "GET",
      "HEAD",
      "OPTIONS"
    ]

    compress = true

    cache_policy_id = data.aws_cloudfront_cache_policy.website.id

    response_headers_policy_id = aws_cloudfront_response_headers_policy.website_security.id
  }


  # ----------------------------------------------------------
  # No Country Restrictions
  # ----------------------------------------------------------

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }


  # ----------------------------------------------------------
  # HTTPS Certificate
  # ----------------------------------------------------------

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate_validation.website.certificate_arn

    ssl_support_method = "sni-only"

    minimum_protocol_version = "TLSv1.2_2021"
  }


  depends_on = [
    aws_acm_certificate_validation.website
  ]

  tags = {
    Name        = "${var.project_name}-website-cdn"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}


# ============================================================
# S3 BUCKET POLICY
# ============================================================

data "aws_iam_policy_document" "website" {

  # ----------------------------------------------------------
  # CloudFront Can Read Objects
  # ----------------------------------------------------------

  statement {
    sid    = "AllowCloudFrontRead"
    effect = "Allow"

    principals {
      type = "Service"

      identifiers = [
        "cloudfront.amazonaws.com"
      ]
    }

    actions = [
      "s3:GetObject"
    ]

    resources = [
      "${aws_s3_bucket.website.arn}/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"

      values = [
        aws_cloudfront_distribution.website.arn
      ]
    }
  }


  # ----------------------------------------------------------
  # Deny HTTP Access To S3
  # ----------------------------------------------------------

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:*"
    ]

    resources = [
      aws_s3_bucket.website.arn,
      "${aws_s3_bucket.website.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}


resource "aws_s3_bucket_policy" "website" {
  bucket = aws_s3_bucket.website.id

  policy = data.aws_iam_policy_document.website.json

  depends_on = [
    aws_s3_bucket_public_access_block.website
  ]
}


# ============================================================
# UPLOAD WEBSITE FILES
# ============================================================

resource "aws_s3_object" "website" {
  for_each = {
    for file in fileset("${path.module}/site", "**/*") :
    file => file
    if basename(file) != ".DS_Store"
  }

  bucket = aws_s3_bucket.website.id

  key = each.value

  source = "${path.module}/site/${each.value}"

  etag = filemd5("${path.module}/site/${each.value}")

  content_type = lookup(
    local.website_mime_types,
    lower(regex("\\.[^.]+$", each.value)),
    "application/octet-stream"
  )

  cache_control = endswith(each.value, ".html") ? "public,max-age=0,must-revalidate" : "public,max-age=86400"

  depends_on = [
    aws_s3_bucket_server_side_encryption_configuration.website,
    aws_s3_bucket_public_access_block.website
  ]
}


# ============================================================
# ROUTE 53 WEBSITE RECORDS
# ============================================================


# ------------------------------------------------------------
# olrstech.com IPv4
# ------------------------------------------------------------

resource "aws_route53_record" "website_apex_a" {
  zone_id = aws_route53_zone.olrstech.zone_id

  name = local.website_domain
  type = "A"

  alias {
    name                   = aws_cloudfront_distribution.website.domain_name
    zone_id                = aws_cloudfront_distribution.website.hosted_zone_id
    evaluate_target_health = false
  }
}


# ------------------------------------------------------------
# olrstech.com IPv6
# ------------------------------------------------------------

resource "aws_route53_record" "website_apex_aaaa" {
  zone_id = aws_route53_zone.olrstech.zone_id

  name = local.website_domain
  type = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.website.domain_name
    zone_id                = aws_cloudfront_distribution.website.hosted_zone_id
    evaluate_target_health = false
  }
}


# ------------------------------------------------------------
# www.olrstech.com IPv4
# ------------------------------------------------------------

resource "aws_route53_record" "website_www_a" {
  zone_id = aws_route53_zone.olrstech.zone_id

  name = local.website_www_domain
  type = "A"

  alias {
    name                   = aws_cloudfront_distribution.website.domain_name
    zone_id                = aws_cloudfront_distribution.website.hosted_zone_id
    evaluate_target_health = false
  }
}


# ------------------------------------------------------------
# www.olrstech.com IPv6
# ------------------------------------------------------------

resource "aws_route53_record" "website_www_aaaa" {
  zone_id = aws_route53_zone.olrstech.zone_id

  name = local.website_www_domain
  type = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.website.domain_name
    zone_id                = aws_cloudfront_distribution.website.hosted_zone_id
    evaluate_target_health = false
  }
}