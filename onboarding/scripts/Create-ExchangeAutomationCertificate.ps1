# Run as Administrator on the Windows onboarding worker. Export PUBLIC certificate only.
$ErrorActionPreference = 'Stop'
$directory = 'C:\ProgramData\OLRS\ExchangeAutomation'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
& icacls.exe $directory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not protect the certificate directory.' }
$subject = 'CN=OLRS-Exchange-Mailbox-Automation'
$existing = @(Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq $subject -and $_.NotAfter -gt (Get-Date).AddDays(30) })
if ($existing.Count -gt 1) { throw 'Multiple certificates found. Review before continuing.' }
$certificate = $existing | Select-Object -First 1
if (-not $certificate) {
    # Exchange app-only authentication requires a legacy CSP, not a CNG key.
    $certificate = New-SelfSignedCertificate -Subject $subject -CertStoreLocation 'Cert:\LocalMachine\My' -Provider 'Microsoft Enhanced RSA and AES Cryptographic Provider' -KeyAlgorithm RSA -KeyLength 3072 -KeyExportPolicy NonExportable -KeySpec Signature -KeyUsage DigitalSignature -NotAfter (Get-Date).AddYears(1)
}
$rsa = $certificate.PrivateKey
if ($rsa -isnot [Security.Cryptography.RSACryptoServiceProvider]) { throw 'Exchange requires a CSP certificate.' }
$keyPath = Join-Path $env:ProgramData ('Microsoft\Crypto\RSA\MachineKeys\' + $rsa.CspKeyContainerInfo.UniqueKeyContainerName)
& icacls.exe $keyPath /inheritance:r /grant:r '*S-1-5-18:R' '*S-1-5-32-544:F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not protect the private key.' }
Export-Certificate -Cert $certificate -FilePath "$directory\Exchange-Automation-Public.cer" | Out-Null
Write-Output ('Certificate thumbprint: ' + $certificate.Thumbprint)
Write-Output ('Public certificate: ' + "$directory\Exchange-Automation-Public.cer")
Write-Output 'Only upload the public .cer file to Entra. No private key is exported.'
