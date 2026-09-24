# Run interactively as a tenant administrator on the Windows server after
# Create-OnboardingCertificate.ps1. Consent requires an appropriate Entra role.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$CertificateThumbprint)
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Applications
$certificate = Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + $CertificateThumbprint)
Connect-MgGraph -Scopes 'Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All' -ContextScope Process -NoWelcome
$context = Get-MgContext
$existing = @(Get-MgApplication -Filter "displayName eq 'OLRS Onboarding Automation'" -All)
if ($existing.Count -gt 0) { throw 'An app with this name already exists. Inspect it before creating another.' }
$key = @{ Type = 'AsymmetricX509Cert'; Usage = 'Verify'; Key = $certificate.RawData; DisplayName = 'OLRS onboarding server certificate'; StartDateTime = $certificate.NotBefore; EndDateTime = $certificate.NotAfter }
$application = New-MgApplication -DisplayName 'OLRS Onboarding Automation' -SignInAudience 'AzureADMyOrg' -KeyCredentials @($key)
$principal = New-MgServicePrincipal -AppId $application.AppId
$graph = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$permission = $graph.AppRoles | Where-Object { $_.Value -eq 'Synchronization.ReadWrite.All' -and $_.AllowedMemberTypes -contains 'Application' }
if (-not $permission) { throw 'Microsoft Graph synchronization application permission was not found.' }
# This grants admin consent for unattended synchronization of the existing Cloud
# Sync job. The app does not own that existing job, so OwnedBy is insufficient.
New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $principal.Id -PrincipalId $principal.Id -ResourceId $graph.Id -AppRoleId $permission.Id | Out-Null
Write-Output ('Tenant ID: ' + $context.TenantId)
Write-Output ('Onboarding client ID: ' + $application.AppId)
Write-Output ('Certificate thumbprint: ' + $CertificateThumbprint)
Write-Output 'Keep these non-secret identifiers for the onboarding Terraform variables.'
Disconnect-MgGraph | Out-Null
