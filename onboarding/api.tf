resource "aws_iam_role" "api" {
  name = "${local.name}-api"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{
      Effect = "Allow", Principal = {
        Service = "lambda.amazonaws.com"
      }, Action = "sts:AssumeRole"
    }]
    }
  )

}

resource "aws_cloudwatch_log_group" "api" {

  name              = "/aws/lambda/${local.name}"
  retention_in_days = 30

}

resource "aws_iam_role_policy" "api" {

  role = aws_iam_role.api.id
  policy = jsonencode({
    Version = "2012-10-17", Statement = [
      {
        Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.api.arn}:*"
      },
      {
        Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"], Resource = [aws_dynamodb_table.records.arn, "${aws_dynamodb_table.records.arn}/index/*"]
      },
      {
        Effect = "Allow", Action = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], Resource = aws_sqs_queue.jobs.arn
      },
      {
        Effect = "Allow", Action = ["cognito-idp:AdminCreateUser", "cognito-idp:AdminGetUser"], Resource = aws_cognito_user_pool.admins.arn
      },
      {
        Effect = "Allow", Action = "ssm:SendCommand", Resource = [aws_ssm_document.onboard.arn, aws_ssm_document.mailboxes.arn, data.aws_instance.dc.arn]
      },
      {
        Effect   = "Allow", Action = ["secretsmanager:CreateSecret", "secretsmanager:TagResource", "secretsmanager:GetSecretValue", "secretsmanager:DeleteSecret"],
        Resource = "arn:aws:secretsmanager:us-west-2:${data.aws_caller_identity.current.account_id}:secret:olrs-onboarding-password-*"
      },
      # GetCommandInvocation has no resource-level IAM scope. API never accepts arbitrary command IDs.
      {
        Effect = "Allow", Action = "ssm:GetCommandInvocation", Resource = "*"
    }]
    }
  )

}

data "archive_file" "api" {
  type = "zip"
  source {
    content  = file("${path.module}/api/app.py")
    filename = "app.py"
  }
  source {
    content  = file("${path.module}/emails/account-created.html")
    filename = "account-created.html"
  }
  source {
    content  = file("${path.module}/api/mailboxes.py")
    filename = "mailboxes.py"
  }
  output_path = "${path.module}/.build/api.zip"

}

resource "aws_lambda_function" "api" {
  lifecycle {
    precondition {
      condition     = !var.provisioning_enabled || (var.bootstrap_admin_sub != "" && var.graph_tenant_id != "" && var.graph_client_id != "" && var.graph_certificate_thumbprint != "")
      error_message = "Owner identity and unattended Graph certificate configuration must be set before enabling employee provisioning."
    }
  }

  function_name    = local.name
  role             = aws_iam_role.api.arn
  runtime          = "python3.12"
  handler          = "app.handler"
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256
  timeout          = 30
  memory_size      = 256
  environment {
    variables = {

      MAILBOX_ENABLED          = "true"
      MAILBOX_DOCUMENT         = aws_ssm_document.mailboxes.name
      MAILBOX_DOCUMENT_VERSION = aws_ssm_document.mailboxes.document_version
      EMAIL_ENABLED            = tostring(var.email_enabled)
      EMAIL_FROM               = "onboarding@olrstech.com"
      SITE_URL                 = local.url
      TABLE_NAME               = aws_dynamodb_table.records.name
      USER_POOL_ID             = aws_cognito_user_pool.admins.id
      CLIENT_ID                = aws_cognito_user_pool_client.web.id
      BOOTSTRAP_SUB            = var.bootstrap_admin_sub
      OWNER_EMAIL              = var.owner_email
      QUEUE_URL                = aws_sqs_queue.jobs.url
      INSTANCE_ID              = data.aws_instance.dc.id
      DOCUMENT_NAME            = aws_ssm_document.onboard.name
      DOCUMENT_VERSION         = aws_ssm_document.onboard.document_version
      PASSWORD_PREFIX          = "olrs-onboarding-password-"
      PROVISIONING_ENABLED     = tostring(var.provisioning_enabled)

    }

  }

  depends_on = [aws_iam_role_policy.api, aws_cloudwatch_log_group.api]

}

resource "aws_lambda_event_source_mapping" "jobs" {
  scaling_config {
    maximum_concurrency = 2
  }

  event_source_arn        = aws_sqs_queue.jobs.arn
  function_name           = aws_lambda_function.api.arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]

}

resource "aws_cloudwatch_event_rule" "poll" {
  name                = "${local.name}-status"
  schedule_expression = "rate(1 minute)"

}

resource "aws_cloudwatch_event_target" "poll" {

  rule = aws_cloudwatch_event_rule.poll.name
  arn  = aws_lambda_function.api.arn

}

resource "aws_lambda_permission" "poll" {
  statement_id  = "StatusPoll"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.poll.arn

}

resource "aws_apigatewayv2_api" "api" {
  name          = local.name
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = [local.url]
    allow_methods = ["GET", "POST", "PATCH", "OPTIONS"]
    allow_headers = ["Authorization", "Content-Type"]
    max_age       = 300

  }


}

resource "aws_apigatewayv2_authorizer" "admins" {

  api_id           = aws_apigatewayv2_api.api.id
  authorizer_type  = "JWT"
  name             = "portal-admins"
  identity_sources = ["$request.header.Authorization"]
  jwt_configuration {

    audience = [aws_cognito_user_pool_client.web.id]
    issuer   = "https://cognito-idp.us-west-2.amazonaws.com/${aws_cognito_user_pool.admins.id}"

  }


}

resource "aws_apigatewayv2_integration" "api" {

  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"

}

resource "aws_apigatewayv2_route" "api" {

  for_each             = toset(["GET /mailboxes", "POST /users/search", "POST /users/access", "POST /users/profile", "GET /mailbox-jobs/{id}", "GET /me", "GET /requests", "POST /requests", "POST /requests/{id}/password", "GET /admins", "POST /admins", "PATCH /admins/{sub}"])
  api_id               = aws_apigatewayv2_api.api.id
  route_key            = each.value
  target               = "integrations/${aws_apigatewayv2_integration.api.id}"
  authorization_type   = "JWT"
  authorizer_id        = aws_apigatewayv2_authorizer.admins.id
  authorization_scopes = ["openid", "aws.cognito.signin.user.admin"]

}

resource "aws_apigatewayv2_stage" "api" {

  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
  default_route_settings {
    throttling_burst_limit = 10
    throttling_rate_limit  = 5

  }


}

resource "aws_lambda_permission" "gateway" {
  statement_id  = "ApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"

}

