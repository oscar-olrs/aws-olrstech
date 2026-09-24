# Run as Administrator on olrs-dc01. No private key is exported.
$ErrorActionPreference = 'Stop'
$directory = 'C:\ProgramData\OLRS\Onboarding'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
New-Item -ItemType Directory -Path "$directory\Requests" -Force | Out-Null
# Protect adapter, journal, locks and certificate export against nonadmins.
& icacls.exe $directory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not protect the onboarding directory.' }
$certificate = New-SelfSignedCertificate -Subject 'CN=OLRS-Onboarding-Automation' -CertStoreLocation 'Cert:\LocalMachine\My' -Provider 'Microsoft Software Key Storage Provider' -KeyAlgorithm RSA -KeyLength 3072 -KeyExportPolicy NonExportable -KeySpec None -KeyUsage DigitalSignature -NotAfter (Get-Date).AddYears(1)
# Give only LocalSystem and local administrators access to the certificate key.
$rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
$keyPath = Join-Path $env:ProgramData ('Microsoft\Crypto\Keys\' + $rsa.Key.UniqueName)
& icacls.exe $keyPath /inheritance:r /grant:r '*S-1-5-18:R' '*S-1-5-32-544:F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not protect the certificate private key.' }
Export-Certificate -Cert $certificate -FilePath "$directory\Onboarding-Public.cer" | Out-Null
Write-Output ('Certificate thumbprint: ' + $certificate.Thumbprint)
Write-Output ('Public certificate for Entra app registration: ' + "$directory\Onboarding-Public.cer")
Write-Output 'Upload only the public .cer file. Keep the private key on this server.'
