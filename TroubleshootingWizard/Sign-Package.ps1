<#
.SYNOPSIS
    Authenticode-signs (or verifies) every PowerShell script in a folder tree.

.DESCRIPTION
    Signs *.ps1 / *.psm1 / *.psd1 under -Path with a code-signing certificate from
    the Windows certificate store, SHA-256, with an RFC 3161 timestamp so the
    signatures stay valid after the certificate expires. Files are converted to
    UTF-8 with BOM first: PowerShell hashes scripts by their detected encoding and
    BOM-less files containing non-ASCII characters are a classic cause of
    "HashMismatch" after signing.

    The Releases\ folder is skipped.

.PARAMETER Path
    Root folder to process. Default: this script's folder.

.PARAMETER CertificateThumbprint
    Thumbprint of a certificate with the Code Signing EKU in CurrentUser\My or
    LocalMachine\My (private key required).

.PARAMETER TimestampServer
    RFC 3161 timestamp URL. Default: http://timestamp.digicert.com

.PARAMETER Verify
    Don't sign; just report the signature status of every script.

.EXAMPLE
    .\Sign-Package.ps1 -CertificateThumbprint 508D2951E2DE747EDFB4E0A003985975EEAE9541
.EXAMPLE
    .\Sign-Package.ps1 -Verify

.NOTES
    Exit 0 when every file is Valid afterwards, 1 otherwise.
    Hosted signing services (Azure Artifact Signing, DigiCert KeyLocker, ...) sign
    .ps1 files with signtool.exe instead; see SECURITY-AND-SIGNING.md.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding(DefaultParameterSetName = 'Sign')]
param(
    [string] $Path = $PSScriptRoot,

    [Parameter(ParameterSetName = 'Sign', Mandatory)]
    [ValidatePattern('^[0-9A-Fa-f]{40}$')]
    [string] $CertificateThumbprint,

    [Parameter(ParameterSetName = 'Sign')]
    [string] $TimestampServer = 'http://timestamp.digicert.com',

    [Parameter(ParameterSetName = 'Verify', Mandatory)]
    [switch] $Verify
)

$ErrorActionPreference = 'Stop'

$scripts = Get-ChildItem -Path $Path -Recurse -File -Include *.ps1, *.psm1, *.psd1 |
    Where-Object { $_.FullName -notmatch '\\Releases\\' }

if (-not $scripts) { Write-Output "No scripts found under $Path"; exit 1 }

if (-not $Verify) {
    $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $CertificateThumbprint } | Select-Object -First 1
    if (-not $cert)            { throw "No code-signing certificate with thumbprint $CertificateThumbprint in CurrentUser\My or LocalMachine\My." }
    if (-not $cert.HasPrivateKey) { throw "Certificate $CertificateThumbprint has no private key." }
    if ($cert.NotAfter -lt (Get-Date)) { throw "Certificate $CertificateThumbprint expired on $($cert.NotAfter)." }
    try {
        $null = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    } catch {
        throw "Private key for $CertificateThumbprint is not accessible in this session ($($_.Exception.InnerException.Message)). LocalMachine\My keys usually need an elevated session or an ACL on the key; token/HSM keys need their provider installed."
    }

    Write-Output "Signing with: $($cert.Subject)  (expires $($cert.NotAfter.ToString('yyyy-MM-dd')))"
    Write-Output "Timestamp   : $TimestampServer`r`n"

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    foreach ($s in $scripts) {
        # Normalise to UTF-8 with BOM (strip any existing signature block first so it is replaced cleanly).
        $text = [IO.File]::ReadAllText($s.FullName)
        $text = $text -replace '(?s)\r?\n# SIG # Begin signature block.*# SIG # End signature block\r?\n?', "`r`n"
        [IO.File]::WriteAllText($s.FullName, $text, $utf8Bom)

        $sig = Set-AuthenticodeSignature -FilePath $s.FullName -Certificate $cert -HashAlgorithm SHA256 -TimestampServer $TimestampServer
        $note = if ($sig.Status -ne 'Valid') { "  ($($sig.StatusMessage))" } else { '' }
        Write-Output ("  {0,-14} {1}{2}" -f $sig.Status, $s.FullName.Substring($Path.Length).TrimStart('\'), $note)
    }
    Write-Output ''
}

Write-Output 'Verification:'
$allValid = $true
foreach ($s in $scripts) {
    $sig = Get-AuthenticodeSignature -FilePath $s.FullName
    $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '-' }
    $ts     = if ($sig.TimeStamperCertificate) { 'timestamped' } else { 'no timestamp' }
    $note   = if ($sig.Status -ne 'Valid' -and $sig.SignerCertificate) { "  ($($sig.StatusMessage))" } else { '' }
    Write-Output ("  {0,-14} {1,-45} {2}  [{3}]{4}" -f $sig.Status, $s.FullName.Substring($Path.Length).TrimStart('\'), $signer, $ts, $note)
    if ($sig.Status -ne 'Valid') { $allValid = $false }
}

if ($allValid) { Write-Output "`r`nAll scripts carry a valid signature."; exit 0 }
Write-Output "`r`nOne or more scripts are unsigned, tampered, or signed by a publisher this machine does not trust (see notes above)."
exit 1
