resource "aws_secretsmanager_secret" "ad_credential" {
  name                    = "olrs-onboarding-ad-credential"
  description             = "Delegated AD onboarding account credentials. Populate securely outside Terraform."
  recovery_window_in_days = 7
}
resource "aws_iam_role_policy" "dc_secret_reader" {
  name = "olrs-onboarding-dc-only-secrets"
  role = data.aws_iam_instance_profile.dc.role_name
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Action = "secretsmanager:GetSecretValue",
    Resource  = [aws_secretsmanager_secret.ad_credential.arn, "arn:aws:secretsmanager:us-west-2:${data.aws_caller_identity.current.account_id}:secret:olrs-onboarding-password-*"],
    Condition = { ArnEquals = { "ec2:SourceInstanceARN" = data.aws_instance.dc.arn } }
  }] })
}

resource "aws_sqs_queue" "dead" {
  name                      = "${local.name}-dead"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600

}

resource "aws_sqs_queue" "jobs" {
  name                       = "${local.name}-jobs"
  sqs_managed_sse_enabled    = true
  visibility_timeout_seconds = 180
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead.arn, maxReceiveCount = 3
    }
  )

}

resource "aws_ssm_document" "onboard" {

  name            = "${local.name}-verified-adapter"
  document_type   = "Command"
  document_format = "JSON"
  content = jsonencode({

    schemaVersion = "2.2"
    description   = "Invoke the locally installed and verified OLRS onboarding adapter. No arbitrary commands accepted."
    parameters = {
      Payload = {
        type = "String", interpolationType = "ENV_VAR", allowedPattern = "^[A-Za-z0-9+/=]+$", maxChars = 12000
      }

    }

    mainSteps = [{
      action = "aws:runPowerShellScript", name = "onboard",
      precondition = {
        StringEquals = ["platformType", "Windows"]
      },
      inputs = {
        timeoutSeconds = "900", runCommand = [
          "$ErrorActionPreference = 'Stop'",
          "if (-not $env:SSM_Payload) { throw 'Update SSM Agent: ENV_VAR support is required.' }",
          "$request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:SSM_Payload)) | ConvertFrom-Json",
          "$adapter = '${var.adapter_path}'",
          "if (-not (Test-Path -LiteralPath $adapter)) { throw 'Verified onboarding adapter is not installed.' }",
          "$configuration = '${jsonencode({ TenantId = var.graph_tenant_id, ClientId = var.graph_client_id, CertificateThumbprint = var.graph_certificate_thumbprint, ADCredentialSecret = aws_secretsmanager_secret.ad_credential.name })}' | ConvertFrom-Json",
          "& $adapter -Request $request -Configuration $configuration",
          "if (-not $?) { throw 'Onboarding adapter failed.' }"
        ]
      }


    }]

    }
  )

}

resource "aws_ssm_document" "mailboxes" {
  name            = "olrs-onboarding-shared-mailboxes"
  document_type   = "Command"
  document_format = "JSON"
  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Restricted shared-mailbox and AD directory worker."
    parameters    = { Payload = { type = "String", interpolationType = "ENV_VAR", allowedPattern = "^[A-Za-z0-9+/=]+$", maxChars = 16000 } }
    mainSteps = [{
      action       = "aws:runPowerShellScript", name = "mailboxes"
      precondition = { StringEquals = ["platformType", "Windows"] }
      inputs = { timeoutSeconds = "600", runCommand = [
        "$ErrorActionPreference = 'Stop'",
        "if (-not $env:SSM_Payload) { throw 'ENV_VAR support required.' }",
        "$request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:SSM_Payload)) | ConvertFrom-Json",
        "& 'C:\\ProgramData\\OLRS\\ExchangeAutomation\\Invoke-SharedMailboxWorker.ps1' -Request $request",
        "if (-not $?) { throw 'Mailbox worker failed.' }"
      ] }
    }]
  })
}

