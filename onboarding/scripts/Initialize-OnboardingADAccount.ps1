# One-time setup under an authorized AD administrator/SSM LocalSystem on dc01.
# Requires temporary Secrets Manager PutSecretValue permission on the existing
# onboarding AD-credential secret. Remove that permission after setup.
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
Import-Module AWS.Tools.SecretsManager
$domain = Get-ADDomain
if ($domain.DNSRoot -ne 'ad.olrstech.com') { throw 'Unexpected AD domain.' }
$ou = 'OU=Users,OU=OLRS,DC=ad,DC=olrstech,DC=com'
$username = 'svc-olrs-onboard'
$group = Get-ADGroup -Identity 'Entra-Sync-Users'
Get-ADOrganizationalUnit -Identity $ou | Out-Null
if (Get-ADUser -Filter { SamAccountName -eq $username }) {
    throw 'Service account already exists. Inspect it rather than replacing its password or permissions.'
}
# Fail before changing AD if a credential version already exists.
try {
    Get-SECSecretValue -SecretId 'olrs-onboarding-ad-credential' -Region 'us-west-2' | Out-Null
    throw 'Credential secret is already populated. Inspect it before changing AD.'
} catch [Amazon.SecretsManager.Model.ResourceNotFoundException] {
    # Terraform creates the empty secret; no AWSCURRENT version is expected yet.
}
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$bytes = New-Object byte[] 32
$rng.GetBytes($bytes)
$rng.Dispose()
$password = 'Aa1!' + [Convert]::ToBase64String($bytes)
$securePassword = ConvertTo-SecureString $password -AsPlainText -Force
$account = New-ADUser -Name 'OLRS Onboarding Service' -SamAccountName $username -UserPrincipalName "$username@ad.olrstech.com" -Path $ou -AccountPassword $securePassword -Enabled $true -PasswordNeverExpires $true -ChangePasswordAtLogon $false -Description 'Dedicated OLRS portal onboarding account; not an employee and not included in Entra-Sync-Users.' -PassThru
$account = Get-ADUser $account -Properties SID
$sid = $account.SID
$schema = (Get-ADRootDSE).schemaNamingContext
$userClass = [Guid]'bf967aba-0de6-11d0-a285-00aa003049e2'
$allow = [Security.AccessControl.AccessControlType]::Allow
$none = [DirectoryServices.ActiveDirectorySecurityInheritance]::None
$descendants = [DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents
$acl = Get-Acl -Path ('AD:\' + $ou)
$acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new($sid, [DirectoryServices.ActiveDirectoryRights]::CreateChild, $allow, $userClass, $none))
foreach ($attribute in @('cn','name','givenName','sn','displayName','sAMAccountName','userPrincipalName','userAccountControl','pwdLastSet','department','title','manager')) {
    $definition = Get-ADObject -SearchBase $schema -LDAPFilter "(lDAPDisplayName=$attribute)" -Properties schemaIDGUID
    $guid = [Guid]::new([byte[]]$definition.schemaIDGUID)
    $acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new($sid, [DirectoryServices.ActiveDirectoryRights]::WriteProperty, $allow, $guid, $descendants, $userClass))
}
$resetPassword = [Guid]'00299570-246d-11d0-a768-00aa006e0529'
$acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new($sid, [DirectoryServices.ActiveDirectoryRights]::ExtendedRight, $allow, $resetPassword, $descendants, $userClass))
Set-Acl -Path ('AD:\' + $ou) -AclObject $acl
$groupAcl = Get-Acl -Path ('AD:\' + $group.DistinguishedName)
$memberAttribute = [Guid]'bf9679c0-0de6-11d0-a285-00aa003049e2'
$groupAcl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new($sid, [DirectoryServices.ActiveDirectoryRights]::WriteProperty, $allow, $memberAttribute, $none))
Set-Acl -Path ('AD:\' + $group.DistinguishedName) -AclObject $groupAcl
$credential = @{ username = "$($domain.NetBIOSName)\$username"; password = $password } | ConvertTo-Json -Compress
Write-SECSecretValue -SecretId 'olrs-onboarding-ad-credential' -SecretString $credential -Region 'us-west-2' | Out-Null
$password = $null
$credential = $null
$check = [PSCredential]::new("$($domain.NetBIOSName)\$username", $securePassword)
Get-ADOrganizationalUnit -Identity $ou -Credential $check -Server 'ad.olrstech.com' | Out-Null
$securePassword = $null
$check = $null
Write-Output 'Dedicated AD service account created; delegated only user creation/required attributes/password reset in the employee OU and membership writes on Entra-Sync-Users. Credentials saved in Secrets Manager. No employee was created.'
Write-Output 'Service credential rotation must be managed together in AD and Secrets Manager; this service account is configured without automatic AD password expiry.'
