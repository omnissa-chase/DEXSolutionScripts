<#
.SYNOPSIS
    Builds the Workspace ONE deployment artifacts for TroubleshootWizard.

.DESCRIPTION
    Reads the version from Install-TroubleshootWizard.ps1 and writes:

      Releases\v<ver>\SFD\TroubleshootWizard_v<ver>.zip
          Everything (payload + installer + uninstaller), folders preserved.
          Upload as the single SFD application file.

      Releases\v<ver>\ProductProvisioning\
          Install-TroubleshootWizard.ps1
          Uninstall-TroubleshootWizard.ps1
          TroubleshootWizard.zip               (payload only)
          Upload these files to a Product Provisioning Files/Actions record.

    Optionally signs every .ps1 in the staged payload first (-CertificateThumbprint),
    via Sign-Package.ps1, so the archives contain signed scripts.

.PARAMETER SourceDir
    Folder containing the project files. Defaults to this script's folder.

.PARAMETER OutputRoot
    Where Releases\ is created. Defaults to <SourceDir>\Releases.

.PARAMETER CertificateThumbprint
    Code-signing certificate thumbprint (CurrentUser\My or LocalMachine\My). When
    given, scripts are signed in the staging folder before zipping.

.PARAMETER TimestampServer
    RFC 3161 timestamp URL used when signing. Default: http://timestamp.digicert.com

.EXAMPLE
    .\Create-ZipPackage.ps1
.EXAMPLE
    .\Create-ZipPackage.ps1 -CertificateThumbprint 508D2951E2DE747EDFB4E0A003985975EEAE9541

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding()]
param(
    [string] $SourceDir             = $PSScriptRoot,
    [string] $OutputRoot            = '',
    [string] $CertificateThumbprint = '',
    [string] $TimestampServer       = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'
if (-not $OutputRoot) { $OutputRoot = Join-Path $SourceDir 'Releases' }

$installerName   = 'Install-TroubleshootWizard.ps1'
$uninstallerName = 'Uninstall-TroubleshootWizard.ps1'
$signerName      = 'Sign-Package.ps1'
$payloadZipName  = 'TroubleshootWizard.zip'

$payloadFiles = @(
    'TroubleshootWizard.ps1',
    'TroubleshootWizard-UI.ps1',
    'TroubleshootWizard-Common.ps1',
    'Send-TroubleshootWizardEvent.ps1',
    'Invoke-TroubleshootWizardFromEvent.ps1',
    'UI-Modern.xaml',
    'UI-Modern-Light.xaml',
    'Branding.json'
)
$payloadFolders = @('DiagSteps', 'Resources')

# -- Version from installer ------------------------------------------------
$installerText = Get-Content (Join-Path $SourceDir $installerName) -Raw
if ($installerText -notmatch "(?m)^\`$AppVersion\s*=\s*'([^']+)'") { throw "Could not read `$AppVersion from $installerName" }
$version = $Matches[1]

Write-Output "`r`n=== TroubleshootWizard - Create Package v$version ==="
Write-Output "Source : $SourceDir"
Write-Output "Output : $OutputRoot\v$version"

# -- Validate source -------------------------------------------------------
$missing = @()
foreach ($f in ($payloadFiles + $installerName + $uninstallerName)) {
    if (-not (Test-Path (Join-Path $SourceDir $f))) { $missing += $f }
}
foreach ($d in $payloadFolders) {
    if (-not (Test-Path (Join-Path $SourceDir $d))) { $missing += "$d\" }
}
if ($missing) {
    Write-Output "`r`nMissing files:"; $missing | ForEach-Object { Write-Output "  $_" }
    exit 1
}

# -- Stage ------------------------------------------------------------------
$releaseDir = Join-Path $OutputRoot "v$version"
$sfdDir     = Join-Path $releaseDir 'SFD'
$ppDir      = Join-Path $releaseDir 'ProductProvisioning'
$stagingDir = Join-Path $env:TEMP "TroubleshootWizard_Staging_$([guid]::NewGuid().ToString('N'))"
$payloadDir = Join-Path $stagingDir 'payload'
$fullDir    = Join-Path $stagingDir 'full'

foreach ($d in $releaseDir, $sfdDir, $ppDir, $payloadDir, $fullDir) {
    if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

foreach ($f in $payloadFiles) { Copy-Item (Join-Path $SourceDir $f) (Join-Path $payloadDir $f) }
foreach ($d in $payloadFolders) {
    Copy-Item (Join-Path $SourceDir $d) (Join-Path $payloadDir $d) -Recurse
    Get-ChildItem (Join-Path $payloadDir $d) -Recurse -File | Where-Object { $_.Extension -notin '.json', '.png' } | Remove-Item -Force
}
foreach ($f in $installerName, $uninstallerName) { Copy-Item (Join-Path $SourceDir $f) (Join-Path $stagingDir $f) }

# -- Sign (optional) --------------------------------------------------------
if ($CertificateThumbprint) {
    $signer = Join-Path $SourceDir $signerName
    if (-not (Test-Path $signer)) { throw "$signerName not found next to this script." }
    Write-Output "`r`nSigning scripts with certificate $CertificateThumbprint ..."
    & $signer -Path $stagingDir -CertificateThumbprint $CertificateThumbprint -TimestampServer $TimestampServer
    if ($LASTEXITCODE -ne 0) { throw 'Signing failed - package not built.' }
}

# -- Build archives ---------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Product Provisioning: payload zip + installer/uninstaller alongside
$ppZip = Join-Path $ppDir $payloadZipName
[System.IO.Compression.ZipFile]::CreateFromDirectory($payloadDir, $ppZip)
Copy-Item (Join-Path $stagingDir $installerName)   (Join-Path $ppDir $installerName)
Copy-Item (Join-Path $stagingDir $uninstallerName) (Join-Path $ppDir $uninstallerName)

# SFD: one zip with everything
Copy-Item "$payloadDir\*" $fullDir -Recurse
Copy-Item (Join-Path $stagingDir $installerName)   (Join-Path $fullDir $installerName)
Copy-Item (Join-Path $stagingDir $uninstallerName) (Join-Path $fullDir $uninstallerName)
$sfdZip = Join-Path $sfdDir "TroubleshootWizard_v$version.zip"
[System.IO.Compression.ZipFile]::CreateFromDirectory($fullDir, $sfdZip)

Remove-Item $stagingDir -Recurse -Force

$kb = { param($p) [math]::Round((Get-Item $p).Length / 1KB, 1) }
Write-Output "`r`n  SFD                : $sfdZip  ($(& $kb $sfdZip) KB)"
Write-Output "  ProductProvisioning: $ppZip  ($(& $kb $ppZip) KB) + installer/uninstaller"

Write-Output @"

Workspace ONE configuration (both methods):
  Install command   : powershell.exe -ExecutionPolicy Bypass -File Install-TroubleshootWizard.ps1
  Uninstall command : powershell.exe -ExecutionPolicy Bypass -File Uninstall-TroubleshootWizard.ps1
  Detection         : registry value exists
                      HKLM\SOFTWARE\AirWatch\Extensions\TroubleshootWizard -> Version = $version
  Run as            : System (required: ACLs, HKLM, event source, scheduled task)
"@
exit 0
