<#
.SYNOPSIS
    Builds a Product Provisioning deployment package for TroubleshootWizard.

.DESCRIPTION
    Zips all payload files into TroubleshootWizard.zip, then bundles that
    archive together with Install-TroubleshootWizard.ps1 into a final
    ProductProvisioning/ folder ready to upload to Workspace ONE.

    Layout of ProductProvisioning/:
        Install-TroubleshootWizard.ps1   - install script (the PP manifest script)
        TroubleshootWizard.zip           - all 11 payload files

    WS1 Product Provisioning config:
        Install Command  : powershell.exe -ExecutionPolicy Bypass -File Install-TroubleshootWizard.ps1
        Detection Rule   : Registry value exists
                           HKLM\SOFTWARE\AirWatch\Extensions\TroubleshootWizard -> Version

.PARAMETER PublishedDir
    Path to the Published/ folder containing all payload files and the installer.
    Defaults to the directory containing this script.

.PARAMETER OutputDir
    Where to write ProductProvisioning/. Defaults to a sibling of PublishedDir.

.EXAMPLE
    .\Create-ZipPackage.ps1
#>

[CmdletBinding()]
param(
    [string] $PublishedDir = $PSScriptRoot,
    [string] $OutputDir    = (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProductProvisioning')
)

$ErrorActionPreference = 'Stop'

$payloadFiles = @(
    'Troubleshooter-Modular.ps1',
    'UI-Modern.xaml',
    'UI-Modern-Light.xaml',
    'Branding.json',
    'omnissa.png',
    'hub.png',
    'NetworkDiagSteps.json',
    'AudioBluetoothDiagSteps.json',
    'PrinterDiagSteps.json',
    'VPNDiagSteps.json',
    'WindowsUpdateDiagSteps.json'
)

$installerName = 'Install-TroubleshootWizard.ps1'
$zipName       = 'TroubleshootWizard.zip'

Write-Host "`n=== TroubleshootWizard - Create Zip Package ===" -ForegroundColor Cyan
Write-Host "Source   : $PublishedDir"
Write-Host "Output   : $OutputDir"

# -- Validate source -------------------------------------------------------
$missing = @()
foreach ($f in ($payloadFiles + $installerName)) {
    if (-not (Test-Path (Join-Path $PublishedDir $f))) { $missing += $f }
}
if ($missing) {
    Write-Host "`nMissing files:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

# -- Prepare output folder -------------------------------------------------
if (Test-Path $OutputDir) { Remove-Item $OutputDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# -- Build payload zip -----------------------------------------------------
$zipPath    = Join-Path $OutputDir $zipName
$stagingDir = Join-Path $env:TEMP 'TroubleshootWizard_Staging'
if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

foreach ($f in $payloadFiles) {
    Copy-Item (Join-Path $PublishedDir $f) (Join-Path $stagingDir $f)
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stagingDir, $zipPath)
Remove-Item $stagingDir -Recurse -Force

$zipSize = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)
Write-Host "`n  Created : $zipName  ($zipSize KB)" -ForegroundColor Green

# -- Copy installer --------------------------------------------------------
Copy-Item (Join-Path $PublishedDir $installerName) (Join-Path $OutputDir $installerName)
Write-Host "  Copied  : $installerName" -ForegroundColor Green

# -- Summary ---------------------------------------------------------------
Write-Host "`n=== Package ready: $OutputDir ===" -ForegroundColor Cyan
Write-Host @"

Workspace ONE Product Provisioning setup:
  Upload both files:
    - Install-TroubleshootWizard.ps1
    - TroubleshootWizard.zip

  Install Command:
    powershell.exe -ExecutionPolicy Bypass -File Install-TroubleshootWizard.ps1

  Detection Rule (registry value exists):
    Key:   HKLM\SOFTWARE\AirWatch\Extensions\TroubleshootWizard
    Value: Version
"@

exit 0
