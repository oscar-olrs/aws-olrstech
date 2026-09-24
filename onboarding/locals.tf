locals {

  name   = "olrs-onboarding"
  domain = "onboarding.olrstech.com"
  url    = "https://${local.domain}"
  mime = {
    html = "text/html; charset=utf-8", css = "text/css; charset=utf-8", js = "application/javascript; charset=utf-8", png = "image/png", svg = "image/svg+xml"
  }


}

