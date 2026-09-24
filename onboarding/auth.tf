resource "aws_cognito_user_pool" "admins" {

  name                     = "${local.name}-admins"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  username_configuration {
    case_sensitive = false
  }

  admin_create_user_config {
    allow_admin_create_user_only = true
    invite_message_template {
      sms_message   = "OLRS Tech onboarding invitation. Username: {username}. Temporary password: {####}"
      email_subject = "You’re invited to the OLRS Tech Onboarding Portal"
      email_message = "<div style='font-family:Arial;background:#112643;color:#eef4ff;padding:32px'><img src='https://onboarding.olrstech.com/logo.png' width='200' alt='OLRS Tech'><h1>You’re invited to onboarding.</h1><p>You’ve been invited to create users and onboard employees using the OLRS Tech Onboarding Portal. Your assigned role and permissions determine which tasks you can perform.</p><p>Username: {username}</p><p>Temporary password: {####}</p><p><a style='color:#99bcff' href='https://onboarding.olrstech.com'>Activate portal access →</a></p><p>Set your own password and configure your authenticator on first sign-in. Never reply with a password or verification code.</p><p>OLRS Tech Onboarding</p></div>"
    }
  }

  dynamic "email_configuration" {
    for_each = var.email_enabled ? [1] : []
    content {
      email_sending_account  = "DEVELOPER"
      source_arn             = aws_ses_domain_identity.onboarding.arn
      from_email_address     = "OLRS Tech Onboarding <onboarding@olrstech.com>"
      reply_to_email_address = "onboarding@olrstech.com"
    }
  }

  mfa_configuration = "ON"
  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 3

  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1

    }


  }

  deletion_protection = "ACTIVE"

}

resource "aws_cognito_user_pool_domain" "admins" {
  managed_login_version = 2

  domain       = "${local.name}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.admins.id

}

resource "aws_cognito_user_pool_client" "web" {

  name                                 = local.name
  user_pool_id                         = aws_cognito_user_pool.admins.id
  generate_secret                      = false
  explicit_auth_flows                  = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["${local.url}/"]
  logout_urls                          = ["${local.url}/"]
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true
  access_token_validity                = 15
  id_token_validity                    = 15
  refresh_token_validity               = 1
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"

  }


}

resource "aws_cognito_user_pool_ui_customization" "midnight" {
  user_pool_id = aws_cognito_user_pool.admins.id
  client_id    = aws_cognito_user_pool_client.web.id
  css          = file("${path.module}/login-theme.css")
  image_file   = filebase64("${path.module}/site/logo.png")
  depends_on   = [aws_cognito_user_pool_domain.admins]
}

resource "aws_cognito_managed_login_branding" "waves" {
  user_pool_id = aws_cognito_user_pool.admins.id
  client_id    = aws_cognito_user_pool_client.web.id
  settings     = file("${path.module}/managed-login-settings.json")
  asset {
    category   = "PAGE_BACKGROUND"
    color_mode = "LIGHT"
    extension  = "SVG"
    bytes      = filebase64("${path.module}/site/network-background.svg")
  }
  asset {
    category   = "FORM_LOGO"
    color_mode = "LIGHT"
    extension  = "PNG"
    bytes      = filebase64("${path.module}/site/logo-light.png")
  }
  asset {
    category   = "PAGE_HEADER_LOGO"
    color_mode = "LIGHT"
    extension  = "PNG"
    bytes      = filebase64("${path.module}/site/logo-light.png")
  }
}
