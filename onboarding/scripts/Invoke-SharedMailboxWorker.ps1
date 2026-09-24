[CmdletBinding()]
param([Parameter(Mandatory)][PSCustomObject]$Request)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$addresses = @('it@olrstech.com','hr@olrstech.com','safety@olrstech.com','sales@olrstech.com','payroll@olrstech.com')
function Result($value) { Write-Output ('OLRS_RESULT:' + ($value | ConvertTo-Json -Depth 8 -Compress)) }
function Entry($list, $address) { return @($list | Where-Object address -eq $address) | Select-Object -First 1 }
function Read-ADCredential {
    $code = '$ErrorActionPreference = ''Stop''; Import-Module AWS.Tools.SecretsManager; (Get-SECSecretValue -SecretId ''olrs-onboarding-ad-credential'' -Region us-west-2 -ErrorAction Stop).SecretString'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -EncodedCommand $encoded 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) { throw 'Credential retrieval failed.' }
    $secret = ($output -join "`n") | ConvertFrom-Json
    return [PSCredential]::new($secret.username, (ConvertTo-SecureString $secret.password -AsPlainText -Force))
}
function Access($recipient, $ownership = $Request.managed) {
    $result = @()
    foreach ($address in $addresses) {
        $mailbox = Get-Mailbox -Identity $address -ErrorAction Stop
        if ($mailbox.RecipientTypeDetails -ne 'SharedMailbox') { throw 'Target must remain a shared mailbox.' }
        $rules = @(Get-MailboxPermission -Identity $address -User $recipient.PrimarySmtpAddress -ErrorAction Stop)
        $full = @($rules | Where-Object { -not $_.IsInherited -and -not $_.Deny -and $_.AccessRights -contains 'FullAccess' }).Count -gt 0
        $deny = @($rules | Where-Object { $_.Deny -and $_.AccessRights -contains 'FullAccess' }).Count -gt 0
        $behalf = $false
        foreach ($delegate in @($mailbox.GrantSendOnBehalfTo)) {
            if (-not $delegate) { continue }
            $resolved = Get-Recipient -Identity $delegate -ErrorAction Stop
            if ($resolved.ExternalDirectoryObjectId -eq $recipient.ExternalDirectoryObjectId) { $behalf = $true }
        }
        $owned = Entry $ownership $address
        $ownedFull = $null -ne $owned -and $owned.fullAccess
        $ownedBehalf = $null -ne $owned -and $owned.sendOnBehalf
        $result += @{ address=$address; fullAccess=$full; sendOnBehalf=$behalf; deny=$deny;
            externalFullAccess=($full -and -not $ownedFull); externalSendOnBehalf=($behalf -and -not $ownedBehalf) }
    }
    return $result
}
try {
    if ($Request.jobId -notmatch '^[a-f0-9-]{36}$' -or $Request.operation -notin @('List','Search','Inspect','UpdateProfile','Apply')) { throw 'Invalid task.' }
    Import-Module ActiveDirectory -ErrorAction Stop
    $credential = Read-ADCredential
    $adOptions = @{ SearchBase='OU=Users,OU=OLRS,DC=ad,DC=olrstech,DC=com'; Server='ad.olrstech.com'; Credential=$credential; ErrorAction='Stop'; Properties=@('DisplayName','GivenName','Surname','Department','Title','Manager','UserPrincipalName','Enabled','AdminCount','ObjectGUID','SID') }
    if ($Request.operation -in @('List','Search')) {
        if ($Request.operation -eq 'List') {
            if ($Request.cursor.Length -gt 100 -or $Request.cursor -match '[\x00-\x1f]') { throw 'Invalid cursor.' }
            $all = @(Get-ADUser @adOptions -LDAPFilter '(objectClass=user)' | Where-Object { $_.SamAccountName -notlike 'svc-*' } | Sort-Object SamAccountName)
            $remaining = @($all | Where-Object { -not $Request.cursor -or $_.SamAccountName -gt $Request.cursor })
            $slice = @($remaining | Select-Object -First 25)
            $rows = @($slice | ForEach-Object { @{ username=$_.SamAccountName.ToLowerInvariant(); name=$_.DisplayName; email=$_.UserPrincipalName; department=$_.Department; enabled=[bool]$_.Enabled } })
            $cursor = ''
            if ($remaining.Count -gt 25) { $cursor = $slice[-1].SamAccountName }
            Result @{ status='Complete'; users=$rows; nextCursor=$cursor; total=$all.Count; ou='OLRS / Users' }
            return
        }
        if ($Request.query -notmatch '^[a-zA-Z0-9 @._-]{2,80}$') { throw 'Invalid search.' }
        # Query allowlist excludes LDAP filter syntax; bound output stays below SSM limits.
        $query = [string]$Request.query
        $users = @(Get-ADUser @adOptions -LDAPFilter "(|(sAMAccountName=*$query*)(displayName=*$query*)(userPrincipalName=*$query*))" -ResultSetSize 25 | ForEach-Object {
            @{ username=$_.SamAccountName.ToLowerInvariant(); name=$_.DisplayName; email=$_.UserPrincipalName; department=$_.Department; enabled=[bool]$_.Enabled }
        })
        Result @{ status='Complete'; users=$users; limited=($users.Count -eq 25) }
        return
    }
    if ($Request.username -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,19}$') { throw 'Invalid username.' }
    $username = [string]$Request.username
    $users = @(Get-ADUser @adOptions -LDAPFilter "(sAMAccountName=$username)")
    if ($users.Count -ne 1) { throw 'User must match one managed AD account.' }
    $adUser = $users[0]
    $managerEmail = ''
    if ($adUser.Manager) { $managerEmail = [string](Get-ADUser -Identity $adUser.Manager -Server 'ad.olrstech.com' -Credential $credential -Properties UserPrincipalName -ErrorAction Stop).UserPrincipalName }
    $protected = ($adUser.AdminCount -eq 1 -or $adUser.SamAccountName -like 'svc-*' -or [int]($adUser.SID.Value.Split('-')[-1]) -lt 1000)
    $profile = @{ objectId=$adUser.ObjectGUID.ToString(); username=$adUser.SamAccountName; firstName=[string]$adUser.GivenName; lastName=[string]$adUser.Surname; department=[string]$adUser.Department; jobTitle=[string]$adUser.Title; managerEmail=$managerEmail; email=[string]$adUser.UserPrincipalName; enabled=[bool]$adUser.Enabled; protected=[bool]$protected }
    if ($Request.operation -eq 'UpdateProfile') {
        if ($protected) { throw 'Protected accounts cannot be edited.' }
        foreach ($name in @('objectId','firstName','lastName','department','jobTitle','managerEmail')) {
            if ($Request.expectedProfile.$name -cne $profile[$name]) { throw 'Employee details changed since review.' }
        }
        $changes = $Request.changes
        foreach ($name in @('firstName','lastName','department','jobTitle','managerEmail')) {
            if ($changes.$name -isnot [string] -or $changes.$name.Length -gt 100 -or $changes.$name -match '[\x00-\x1f]') { throw 'Invalid profile field.' }
        }
        if (-not $changes.firstName.Trim() -or -not $changes.lastName.Trim()) { throw 'Employee name required.' }
        $replace = @{ givenName=$changes.firstName; sn=$changes.lastName; displayName=($changes.firstName + ' ' + $changes.lastName) }
        $clear = @()
        foreach ($pair in @(@('department','department'),@('jobTitle','title'))) {
            if ($changes.($pair[0])) { $replace[$pair[1]] = $changes.($pair[0]) } else { $clear += $pair[1] }
        }
        if ($changes.managerEmail) {
            $managerUPN = [string]$changes.managerEmail
            $matches = @(Get-ADUser -Server 'ad.olrstech.com' -Credential $credential -Filter { UserPrincipalName -eq $managerUPN } -ErrorAction Stop)
            if ($matches.Count -ne 1 -or $matches[0].ObjectGUID -eq $adUser.ObjectGUID) { throw 'Manager must match another existing AD user.' }
            $replace['manager'] = $matches[0].DistinguishedName
        } else { $clear += 'manager' }
        $directory = 'C:\ProgramData\OLRS\ExchangeAutomation\Requests'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $journal = Join-Path $directory ($Request.jobId + '.json')
        $userLock = [IO.File]::Open((Join-Path $directory ($username + '.lock')), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::None)
        if (Test-Path $journal) { throw 'Prior profile attempt exists. Inspect before retrying.' }
        @{ Stage='UpdatingProfile'; JobId=$Request.jobId; Username=$username } | ConvertTo-Json | Set-Content $journal
        $options = @{ Identity=$adUser.ObjectGUID; Server='ad.olrstech.com'; Credential=$credential; Replace=$replace; ErrorAction='Stop' }
        if ($clear.Count) { $options.Clear = $clear }
        Set-ADUser @options
        $updated = Get-ADUser -Identity $adUser.ObjectGUID -Server 'ad.olrstech.com' -Credential $credential -Properties GivenName,Surname,DisplayName,Department,Title,Manager -ErrorAction Stop
        if ($updated.GivenName -cne $changes.firstName -or $updated.Surname -cne $changes.lastName -or [string]$updated.Department -cne $changes.department -or [string]$updated.Title -cne $changes.jobTitle) { throw 'AD profile verification failed.' }
        if (($replace.ContainsKey('manager') -and $updated.Manager -ine $replace['manager']) -or (-not $replace.ContainsKey('manager') -and $updated.Manager)) { throw 'Manager verification failed.' }
        @{ Stage='Complete'; JobId=$Request.jobId; Username=$username } | ConvertTo-Json | Set-Content $journal
        Result @{ status='Complete'; profileSaved=$true; objectId=$adUser.ObjectGUID.ToString() }
        return
    }
    if ($Request.operation -eq 'Apply' -and -not $users[0].Enabled) { throw 'Disabled employees cannot receive mailbox changes.' }
    foreach ($list in @('desired','managed','expected')) {
        $seen = @{}
        foreach ($item in @($Request.$list)) {
            if ($item.address -notin $addresses -or $seen.ContainsKey($item.address)) { throw 'Invalid mailbox target.' }
            $seen[$item.address] = $true
        }
    }
    try {
    Import-Module ExchangeOnlineManagement -RequiredVersion 3.10.1 -ErrorAction Stop
    $certificate = Get-Item 'Cert:\LocalMachine\My\80894C4AF9D30F38DEB059E227F63384D84C6C10' -ErrorAction Stop
    Connect-ExchangeOnline -AppId '3fbbf739-8989-4d09-9c7c-4b00f3ccd7bb' -Organization 'OlrsTech.onmicrosoft.com' -Certificate $certificate -ShowBanner:$false -ErrorAction Stop
    # A not-yet-provisioned recipient is a read-only waiting state, not a failed create.
    $recipient = Get-Recipient -Identity $adUser.UserPrincipalName -ErrorAction SilentlyContinue
    if (-not $recipient -or $recipient.RecipientTypeDetails -ne 'UserMailbox') {
        if ($Request.operation -eq 'Inspect') { Result @{ status='Complete'; ready=$false; profile=$profile; access=@(); managed=@(); m365State='Mailbox not available' } }
        else { Result @{ status='Waiting' } }
        return
    }
    $current = @(Access $recipient)
    if ($Request.operation -eq 'Inspect') { Result @{ status='Complete'; ready=$true; profile=$profile; access=$current; managed=@($Request.managed); m365State='Mailbox ready' }; return }
    } catch {
        if ($Request.operation -eq 'Inspect') { Result @{ status='Complete'; ready=$false; profile=$profile; access=@(); managed=@(); m365State='Access check needs review' }; return }
        throw
    }
    # Preflight all targets before any write; reject stale views and direct Deny entries.
    foreach ($entry in $current) {
        $expected = Entry $Request.expected $entry.address
        if ($expected -and ($expected.fullAccess -ne $entry.fullAccess -or $expected.sendOnBehalf -ne $entry.sendOnBehalf -or $expected.deny -ne $entry.deny)) { throw 'Permissions changed since review.' }
        if ($entry.deny -and (Entry $Request.desired $entry.address)) { throw 'Direct deny requires IT review.' }
        $target = Entry $Request.desired $entry.address
        if ($entry.externalFullAccess -and -not $target) { continue }
        if ($entry.externalSendOnBehalf -and $target -and -not $target.sendOnBehalf) { throw 'Cannot remove externally granted send-on-behalf access.' }
    }
    $directory = 'C:\ProgramData\OLRS\ExchangeAutomation\Requests'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $journal = Join-Path $directory ($Request.jobId + '.json')
    $userLock = [IO.File]::Open((Join-Path $directory ($username + '.lock')), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::None)
    if (Test-Path $journal) { throw 'A prior apply attempt exists; inspect before retrying.' }
    @{ Stage='Applying'; JobId=$Request.jobId; Username=$username } | ConvertTo-Json | Set-Content $journal
    $ownedResult = @()
    foreach ($entry in $current) {
        $target = Entry $Request.desired $entry.address
        $owned = Entry $Request.managed $entry.address
        $ownFull = $null -ne $owned -and $owned.fullAccess
        $ownBehalf = $null -ne $owned -and $owned.sendOnBehalf
        if ($target) {
            if (-not $entry.fullAccess) {
                Add-MailboxPermission -Identity $entry.address -User $recipient.PrimarySmtpAddress -AccessRights FullAccess -InheritanceType All -AutoMapping $true -Confirm:$false -ErrorAction Stop | Out-Null
                $ownFull = $true
            }
            if ($target.sendOnBehalf -and -not $entry.sendOnBehalf) {
                Set-Mailbox -Identity $entry.address -GrantSendOnBehalfTo @{Add=$recipient.PrimarySmtpAddress.ToString()} -ErrorAction Stop
                $ownBehalf = $true
            } elseif (-not $target.sendOnBehalf -and $ownBehalf -and $entry.sendOnBehalf) {
                Set-Mailbox -Identity $entry.address -GrantSendOnBehalfTo @{Remove=$recipient.PrimarySmtpAddress.ToString()} -ErrorAction Stop
                $ownBehalf = $false
            }
        } else {
            if ($ownBehalf -and $entry.sendOnBehalf) { Set-Mailbox -Identity $entry.address -GrantSendOnBehalfTo @{Remove=$recipient.PrimarySmtpAddress.ToString()} -ErrorAction Stop }
            if ($ownFull -and $entry.fullAccess) { Remove-MailboxPermission -Identity $entry.address -User $recipient.PrimarySmtpAddress -AccessRights FullAccess -InheritanceType All -Confirm:$false -ErrorAction Stop }
            $ownFull = $false; $ownBehalf = $false
        }
        if ($ownFull -or $ownBehalf) { $ownedResult += @{ address=$entry.address; fullAccess=[bool]$ownFull; sendOnBehalf=[bool]$ownBehalf } }
    }
    $verified = @(Access $recipient $ownedResult)
    foreach ($target in @($Request.desired)) {
        $actual = Entry $verified $target.address
        if (-not $actual.fullAccess -or ($target.sendOnBehalf -and -not $actual.sendOnBehalf) -or (-not $target.sendOnBehalf -and $actual.sendOnBehalf -and -not $actual.externalSendOnBehalf)) { throw 'Access verification failed; inspect journal.' }
    }
    foreach ($prior in @($Request.managed)) {
        if (-not (Entry $Request.desired $prior.address)) {
            $actual = Entry $verified $prior.address
            if (($prior.fullAccess -and $actual.fullAccess) -or ($prior.sendOnBehalf -and $actual.sendOnBehalf)) { throw 'Removal verification failed.' }
        }
    }
    @{ Stage='Complete'; JobId=$Request.jobId; Username=$username; Managed=$ownedResult } | ConvertTo-Json -Depth 5 | Set-Content $journal
    Result @{ status='Complete'; managed=$ownedResult; access=$verified; ready=$true }
} catch {
    $diagnostics = @{ Stage='Failed'; JobId=$Request.jobId; Operation=$Request.operation; Line=$_.InvocationInfo.ScriptLineNumber; ErrorId=$_.FullyQualifiedErrorId; Message=$_.Exception.Message }
    $errorPath = 'C:\ProgramData\OLRS\ExchangeAutomation\' + $Request.jobId + '-error.json'
    $diagnostics | ConvertTo-Json | Set-Content -LiteralPath $errorPath
    Write-Error ('Mailbox task failed. Inspect protected journal. ' + $_.Exception.GetType().Name) -ErrorAction Continue
    exit 1
} finally {
    $credential = $null
    if (Get-Variable userLock -ErrorAction SilentlyContinue) { if ($userLock) { $userLock.Dispose() } }
    if (Get-Module ExchangeOnlineManagement) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue }
}
