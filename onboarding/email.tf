resource "aws_ses_domain_identity" "onboarding" {
  domain = "olrstech.com"
}
resource "aws_ses_domain_dkim" "onboarding" {
  domain = aws_ses_domain_identity.onboarding.domain
}
resource "aws_route53_record" "ses_verification" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "_amazonses.olrstech.com"
  type    = "TXT"
  ttl     = 300
  records = [aws_ses_domain_identity.onboarding.verification_token]
}
resource "aws_route53_record" "ses_dkim" {
  count   = 3
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${aws_ses_domain_dkim.onboarding.dkim_tokens[count.index]}._domainkey.olrstech.com"
  type    = "CNAME"
  ttl     = 300
  records = ["${aws_ses_domain_dkim.onboarding.dkim_tokens[count.index]}.dkim.amazonses.com"]
}

variable "email_enabled" {
  type    = bool
  default = false
}
resource "aws_iam_role_policy" "email" {
  role = aws_iam_role.api.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Action = ["ses:SendEmail"], Resource = aws_ses_domain_identity.onboarding.arn,
    Condition = { StringEquals = { "ses:FromAddress" = "onboarding@olrstech.com" } }
  }] })
}
