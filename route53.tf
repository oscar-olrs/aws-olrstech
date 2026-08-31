resource "aws_route53_zone" "olrstech" {
  name = "olrstech.com"

  tags = {
    Name        = "olrstech.com"
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}


####### M365 DNS Records

resource "aws_route53_record" "m365_mx" {
  zone_id = aws_route53_zone.olrstech.zone_id
  name    = "olrstech.com"
  type    = "MX"
  ttl     = 300

  records = [
    "0 olrstech-com.mail.protection.outlook.com"
  ]
}

resource "aws_route53_record" "m365_spf" {
  zone_id = aws_route53_zone.olrstech.zone_id
  name    = "olrstech.com"
  type    = "TXT"
  ttl     = 300

  records = [
    "v=spf1 include:spf.protection.outlook.com -all"
  ]
}

resource "aws_route53_record" "m365_autodiscover" {
  zone_id = aws_route53_zone.olrstech.zone_id
  name    = "autodiscover.olrstech.com"
  type    = "CNAME"
  ttl     = 300

  records = [
    "autodiscover.outlook.com"
  ]
}