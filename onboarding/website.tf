resource "aws_acm_certificate" "site" {

  provider          = aws.certificate
  domain_name       = local.domain
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }


}

resource "aws_route53_record" "validation" {

  for_each = {
    for dvo in aws_acm_certificate.site.domain_validation_options : dvo.domain_name => dvo
  }

  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 300

}

resource "aws_acm_certificate_validation" "site" {

  provider                = aws.certificate
  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]

}

resource "aws_cloudfront_origin_access_control" "site" {

  name                              = local.name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"

}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

resource "aws_cloudfront_response_headers_policy" "site" {

  name = "${local.name}-security"
  security_headers_config {

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true

    }

    referrer_policy {
      referrer_policy = "no-referrer"
      override        = true

    }

    strict_transport_security {
      access_control_max_age_sec = 31536000
      override                   = true

    }

    content_security_policy {

      override                = true
      content_security_policy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'self' https://cognito-idp.us-west-2.amazonaws.com ${aws_apigatewayv2_api.api.api_endpoint} https://${aws_cognito_user_pool_domain.admins.domain}.auth.us-west-2.amazoncognito.com; frame-ancestors 'none'; object-src 'none'; base-uri 'none'; form-action 'self'"

    }


  }


}

resource "aws_cloudfront_distribution" "site" {

  enabled             = true
  is_ipv6_enabled     = true
  aliases             = [local.domain]
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "onboarding"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id

  }

  default_cache_behavior {

    target_origin_id           = "onboarding"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.site.id

  }

  viewer_certificate {

    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"

  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }

  }


}

resource "aws_route53_record" "site" {

  for_each = toset(["A", "AAAA"])
  zone_id  = data.aws_route53_zone.main.zone_id
  name     = local.domain
  type     = each.value
  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false

  }


}

