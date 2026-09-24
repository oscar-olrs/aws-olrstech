# Noninteractive adaptation of the user's Onboarding App.ps1.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][PSCustomObject]$Request,
    [Parameter(Mandatory = $true)][PSCustomObject]$Configuration
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$UserOU = 'OU=Users,OU=OLRS,DC=ad,DC=olrstech,DC=com'
$SyncGroup = 'Entra-Sync-Users'
$UPNSuffix = 'olrstech.com'
$ServicePrincipalId = '5cad060d-6c92-4abf-a0cf-03c21a185fda'
$JobId = 'AD2AADProvisioning.66a779ef28f44e14b00754bccfa9c67e.699d7c2d-e60f-4864-8699-16468342c5ca'
$RuleId = '6c409270-f78a-4bc6-af23-7cf3ab6482fe'

function Read-SecretJson([string]$Name) {
    if ($Name -notmatch '^olrs-onboarding-(ad-credential|password-[a-f0-9-]{36})$') { throw 'Invalid secret name.' }
    # Isolate AWS dependencies from Graph. Capture credentials only in memory.
    $code = '$ErrorActionPreference = ''Stop''; Import-Module AWS.Tools.SecretsManager; (Get-SECSecretValue -SecretId ''' + $Name + ''' -Region us-west-2 -ErrorAction Stop).SecretString'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -EncodedCommand $encoded 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) { throw 'Secure credential retrieval failed.' }
    return ($output -join "`n" | ConvertFrom-Json)
}
function Set-Journal([string]$Stage) {
    @{ RequestId = $Request.requestId; Username = $Request.username; Stage = $Stage } |
        ConvertTo-Json | Set-Content -LiteralPath $script:JournalPath -Encoding UTF8
}
try {
    if ($Request.username -cnotmatch '^[a-z][a-z0-9._-]{0,19}$') { throw 'Invalid username.' }
    if ($Request.requestId -notmatch '^[a-f0-9-]{36}$') { throw 'Invalid request ID.' }
    if ($Request.passwordSecret -cne ('olrs-onboarding-password-' + $Request.requestId)) { throw 'Invalid password secret reference.' }
    foreach ($field in @('firstName', 'lastName', 'department')) {
        if ([string]::IsNullOrWhiteSpace($Request.$field) -or $Request.$field.Length -gt 100) { throw 'Invalid employee field.' }
    }
    if ($Configuration.TenantId -notmatch '^[a-fA-F0-9-]{36}$' -or $Configuration.ClientId -notmatch '^[a-fA-F0-9-]{36}$' -or $Configuration.CertificateThumbprint -notmatch '^[a-fA-F0-9]{40}$') {
        throw 'Unattended Graph authentication is not configured.'
    }
    Import-Module ActiveDirectory -ErrorAction Stop
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Import-Module Microsoft.Graph.Applications -ErrorAction Stop
    # AD commands use a delegated service account. Do not implicitly use the
    # domain controller's highly privileged LocalSystem computer identity.
    $adSecret = Read-SecretJson $Configuration.ADCredentialSecret
    $adCredential = [PSCredential]::new($adSecret.username, (ConvertTo-SecureString $adSecret.password -AsPlainText -Force))
    $adSecret = $null
    $certificate = Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + $Configuration.CertificateThumbprint)
    if (-not $certificate.HasPrivateKey) { throw 'The Graph private key is unavailable.' }
    Connect-MgGraph -TenantId $Configuration.TenantId -ClientId $Configuration.ClientId -Certificate $certificate -ContextScope Process -NoWelcome -ErrorAction Stop
    $context = Get-MgContext
    if ($context.AuthType -ne 'AppOnly') { throw 'Application-only Graph authentication is required.' }
    # Validate prerequisites BEFORE creating an AD account.
    $server = 'ad.olrstech.com'
    Get-ADOrganizationalUnit -Identity $UserOU -Server $server -Credential $adCredential -ErrorAction Stop | Out-Null
    $group = Get-ADGroup -Identity $SyncGroup -Server $server -Credential $adCredential -ErrorAction Stop
    $journalDirectory = 'C:\ProgramData\OLRS\Onboarding\Requests'
    if (-not (Test-Path -LiteralPath $journalDirectory)) { throw 'Protected request journal is not installed.' }
    $script:JournalPath = Join-Path $journalDirectory ($Request.requestId + '.json')
    if (Test-Path -LiteralPath $script:JournalPath) {
        $prior = Get-Content -LiteralPath $script:JournalPath -Raw | ConvertFrom-Json
        if ($prior.Username -cne $Request.username) { throw 'Request ID belongs to another username.' }
        if ($prior.Stage -eq 'SyncRequested') { Write-Output 'Previously completed request; no account was recreated.'; return }
        throw 'A prior partial attempt exists. IT must inspect it before retrying.'
    }
    $username = [string]$Request.username
    $existing = Get-ADUser -Filter { SamAccountName -eq $username } -Server $server -Credential $adCredential -ErrorAction Stop
    if ($existing) { throw 'Username already exists. No existing account was modified.' }
    $password = Read-SecretJson $Request.passwordSecret
    $securePassword = ConvertTo-SecureString $password.password -AsPlainText -Force
    $password = $null
    # Keep an exclusive lock on failure to prevent ambiguous retries.
    $lockPath = Join-Path $journalDirectory ($Request.requestId + '.lock')
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $lock.Dispose()
    Set-Journal 'CreatingADUser'
    $displayName = "$($Request.firstName) $($Request.lastName)"
    $arguments = @{
        Name = $displayName; GivenName = $Request.firstName; Surname = $Request.lastName
        DisplayName = $displayName; SamAccountName = $username
        UserPrincipalName = "$username@$UPNSuffix"; Path = $UserOU
        AccountPassword = $securePassword; Enabled = $true; ChangePasswordAtLogon = $true
        Department = $Request.department; Server = $server; Credential = $adCredential
        ErrorAction = 'Stop'; PassThru = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($Request.jobTitle)) { $arguments.Title = $Request.jobTitle }
    if (-not [string]::IsNullOrWhiteSpace($Request.managerEmail)) {
        $managerUPN = [string]$Request.managerEmail
        $manager = @(Get-ADUser -Filter { UserPrincipalName -eq $managerUPN } -Server $server -Credential $adCredential -ErrorAction Stop)
        if ($manager.Count -ne 1) { throw 'Manager email must match one existing AD user UPN.' }
        $arguments.Manager = $manager[0].DistinguishedName
    }
    $adUser = New-ADUser @arguments
    $securePassword = $null
    Set-Journal 'ADUserCreated'
    Add-ADGroupMember -Identity $group -Members $adUser -Server $server -Credential $adCredential -ErrorAction Stop
    Set-Journal 'SyncGroupAdded'
    $membership = @(Get-ADGroupMember -Identity $group -Server $server -Credential $adCredential -ErrorAction Stop | Where-Object { $_.DistinguishedName -eq $adUser.DistinguishedName })
    if ($membership.Count -ne 1) { throw 'Sync group membership could not be verified.' }
    Start-Sleep -Seconds 3
    $parameters = @{ Parameters = @(@{ RuleId = $RuleId; Subjects = @(@{ ObjectId = $adUser.DistinguishedName; ObjectTypeName = 'user' }) }) }
    $result = New-MgServicePrincipalSynchronizationJobOnDemand -ServicePrincipalId $ServicePrincipalId -SynchronizationJobId $JobId -BodyParameter $parameters -ErrorAction Stop
    # An HTTP-successful response can still contain per-step failures.
    $outcome = $result.Key | ConvertFrom-Json
    $details = $result.Value | ConvertFrom-Json
    $steps = @($details.provisioningSteps)
    if ($outcome.result -notin @('Success', 'Skipped') -or $steps.Count -eq 0 -or @($steps | Where-Object { $_.Status -notin @('success', 'skipped', 'warning') }).Count -gt 0) {
        Set-Journal 'GraphResultNeedsReview'
        throw 'Graph returned an incomplete or unsuccessful provisioning result.'
    }
    Set-Journal 'SyncRequested'
    Write-Output 'AD user created; sync group verified; Graph provision-on-demand completed. M365 licensing and mailbox readiness are not verified.'
} catch {
    Write-Error ('Onboarding failed; inspect the protected journal. ' + $_.Exception.GetType().Name) -ErrorAction Continue
    exit 1
} finally {
    $adCredential = $null
    if (Get-Module Microsoft.Graph.Authentication) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
}
