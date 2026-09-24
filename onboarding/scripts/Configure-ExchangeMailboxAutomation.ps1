param(
    [Parameter(Mandatory)][guid]$AppId,
    # Enterprise applications OBJECT ID, not App registrations Object ID.
    [Parameter(Mandatory)][guid]$EnterpriseApplicationObjectId
)
# Run in an administrator's connected Exchange Online PowerShell session.
$ErrorActionPreference = 'Stop'
if ((Get-OrganizationConfig -ErrorAction Stop).IsDehydrated) {
    throw 'Run Enable-OrganizationCustomization, confirm IsDehydrated is False, then rerun this script.'
}
$addresses = @('it@olrstech.com','hr@olrstech.com','safety@olrstech.com','sales@olrstech.com','payroll@olrstech.com')
foreach ($address in $addresses) {
    $mailbox = Get-Mailbox -Identity $address -ErrorAction Stop
    if ($mailbox.RecipientTypeDetails -ne 'SharedMailbox') { throw "$address is not a shared mailbox." }
}
$scopeName = 'OLRS-Onboarding-Shared-Mailboxes'
$roleName = 'OLRS-Onboarding-Mailbox-Delegation'
$groupName = 'OLRS-Onboarding-Mailbox-Automation'
$cmdlets = @('Get-Mailbox','Get-Recipient','Get-MailboxPermission','Add-MailboxPermission','Remove-MailboxPermission','Set-Mailbox')
# Preflight role availability before modifying Exchange configuration.
foreach ($cmdlet in $cmdlets) {
    Get-ManagementRoleEntry "Mail Recipients\$cmdlet" -ErrorAction Stop | Out-Null
}
$filter = "(RecipientTypeDetails -eq 'SharedMailbox') -and (" + (($addresses | ForEach-Object { "PrimarySmtpAddress -eq '$_'" }) -join ' -or ') + ')'
if (-not (Get-ManagementScope -Identity $scopeName -ErrorAction SilentlyContinue)) {
    New-ManagementScope -Name $scopeName -RecipientRestrictionFilter $filter -ErrorAction Stop | Out-Null
} else {
    Set-ManagementScope -Identity $scopeName -RecipientRestrictionFilter $filter -ErrorAction Stop
}
if (-not (Get-ManagementRole -Identity $roleName -ErrorAction SilentlyContinue)) {
    New-ManagementRole -Name $roleName -Parent 'Mail Recipients' -ErrorAction Stop | Out-Null
}
Get-ManagementRoleEntry "$roleName\*" -ErrorAction Stop | Where-Object { $_.Name -notin $cmdlets } | ForEach-Object {
    Remove-ManagementRoleEntry -Identity "$roleName\$($_.Name)" -Confirm:$false -ErrorAction Stop
}
# Restrict Set-Mailbox to delegation only; no licensing, forwarding or mailbox configuration.
Set-ManagementRoleEntry -Identity "$roleName\Set-Mailbox" -Parameters Identity,GrantSendOnBehalfTo -ErrorAction Stop
Set-ManagementRoleEntry -Identity "$roleName\Add-MailboxPermission" -Parameters Identity,User,AccessRights,InheritanceType,AutoMapping -ErrorAction Stop
Set-ManagementRoleEntry -Identity "$roleName\Remove-MailboxPermission" -Parameters Identity,User,AccessRights,InheritanceType -ErrorAction Stop
$principal = Get-ServicePrincipal -Identity $EnterpriseApplicationObjectId -ErrorAction SilentlyContinue
if (-not $principal) {
    New-ServicePrincipal -AppId $AppId -ObjectId $EnterpriseApplicationObjectId -DisplayName 'OLRS Exchange Mailbox Automation' -ErrorAction Stop | Out-Null
    $principal = Get-ServicePrincipal -Identity $EnterpriseApplicationObjectId -ErrorAction Stop
}
if (-not (Get-RoleGroup -Identity $groupName -ErrorAction SilentlyContinue)) {
    New-RoleGroup -Name $groupName -Roles $roleName -CustomRecipientWriteScope $scopeName -ErrorAction Stop | Out-Null
} else {
    throw 'Role group already exists. Review its scope and membership before rerunning.'
}
Add-RoleGroupMember -Identity $groupName -Member $principal.Identity -ErrorAction Stop
Get-ManagementRoleAssignment -RoleAssignee $groupName -ErrorAction Stop | Select-Object Role,CustomRecipientWriteScope
Write-Output 'Configured mailbox delegation only. Verify app-only access before enabling the onboarding feature.'
