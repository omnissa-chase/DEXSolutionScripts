<#
.SYNOPSIS
    Installs TroubleshootWizard to C:\ProgramData\AirWatch\Extensions\TroubleshootWizard

.DESCRIPTION
    Supports two deployment modes, auto-detected or forced via -Mode:

    SFD  (Workspace ONE Software Distribution)
         All payload files sit alongside this installer script.
         The script copies them to the destination folder.
         Use this for standard SFD deployments.

    ZIP  (Workspace ONE Product Provisioning / Registered Mode)
         A single ZIP archive (TroubleshootWizard.zip) sits alongside this
         installer script. The script extracts it then moves files to the
         destination folder.
         Use this for Product Provisioning where only one file can be staged.

    Auto-detection order:
         1. If TroubleshootWizard.zip is found next to the script → ZIP mode
         2. If Troubleshooter-Modular.ps1 is found next to the script  → SFD mode
         3. Error — cannot determine mode

.PARAMETER Mode
    Force a specific mode: 'SFD' or 'ZIP'. Defaults to auto-detect.

.PARAMETER Destination
    Override the default install path.
    Default: C:\ProgramData\AirWatch\Extensions\TroubleshootWizard

.PARAMETER ZipName
    Name of the ZIP archive to look for in ZIP mode.
    Default: TroubleshootWizard.zip

.EXAMPLE
    # Auto-detect (recommended for both deployment methods)
    .\Install-TroubleshootWizard.ps1

.EXAMPLE
    # Force SFD mode explicitly
    .\Install-TroubleshootWizard.ps1 -Mode SFD

.EXAMPLE
    # Force ZIP mode explicitly
    .\Install-TroubleshootWizard.ps1 -Mode ZIP
#>

[CmdletBinding()]
param(
    [ValidateSet('Auto','SFD','ZIP')]
    [string] $Mode        = 'Auto',
    [string] $Destination = 'C:\ProgramData\AirWatch\Extensions\TroubleshootWizard',
    [string] $ZipName     = 'TroubleshootWizard.zip'
)

$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────
#  LOGGING
# ─────────────────────────────────────────────
$logFile = Join-Path $env:TEMP 'TroubleshootWizard_Install.log'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    $color = @{ INFO='White'; SUCCESS='Green'; WARNING='Yellow'; ERROR='Red' }[$Level]
    Write-Host $line -ForegroundColor ($color ?? 'White')
}

Write-Log "====== TroubleshootWizard Installer ======"
Write-Log "Script root : $PSScriptRoot"
Write-Log "Destination : $Destination"
Write-Log "Mode param  : $Mode"
Write-Log "Log file    : $logFile"

# ─────────────────────────────────────────────
#  AUTO-DETECT MODE
# ─────────────────────────────────────────────
$zipPath     = Join-Path $PSScriptRoot $ZipName
$probeScript = Join-Path $PSScriptRoot 'Troubleshooter-Modular.ps1'

if ($Mode -eq 'Auto') {
    if (Test-Path $zipPath) {
        $Mode = 'ZIP'
        Write-Log "Auto-detected mode: ZIP  (found $ZipName)"
    } elseif (Test-Path $probeScript) {
        $Mode = 'SFD'
        Write-Log "Auto-detected mode: SFD  (found Troubleshooter-Modular.ps1)"
    } else {
        Write-Log "Cannot determine install mode. Neither '$ZipName' nor 'Troubleshooter-Modular.ps1' found next to this script." 'ERROR'
        exit 1
    }
}

# ─────────────────────────────────────────────
#  REQUIRED PAYLOAD FILES
# ─────────────────────────────────────────────
$requiredFiles = @(
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

# ─────────────────────────────────────────────
#  PREPARE SOURCE FOLDER
# ─────────────────────────────────────────────
$sourceDir = $PSScriptRoot

if ($Mode -eq 'ZIP') {
    Write-Log "ZIP mode — extracting $ZipName..."

    if (-not (Test-Path $zipPath)) {
        Write-Log "ZIP file not found: $zipPath" 'ERROR'
        exit 1
    }

    $extractDir = Join-Path $env:TEMP 'TroubleshootWizard_Extract'
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)
        Write-Log "Extracted to: $extractDir" 'SUCCESS'
    } catch {
        Write-Log "Extraction failed: $_" 'ERROR'
        exit 1
    }

    # If the zip contains a single subfolder, step into it
    $children = Get-ChildItem $extractDir
    if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
        $sourceDir = $children[0].FullName
        Write-Log "Using subfolder as source: $sourceDir"
    } else {
        $sourceDir = $extractDir
    }
}

# ─────────────────────────────────────────────
#  VALIDATE SOURCE FILES
# ─────────────────────────────────────────────
Write-Log "Validating payload files in: $sourceDir"
$missing = @()
foreach ($file in $requiredFiles) {
    $path = Join-Path $sourceDir $file
    if (-not (Test-Path $path)) {
        $missing += $file
        Write-Log "  MISSING: $file" 'WARNING'
    } else {
        Write-Log "  OK     : $file"
    }
}

if ($missing.Count -gt 0) {
    Write-Log "$($missing.Count) required file(s) missing from source. Aborting." 'ERROR'
    exit 1
}

# ─────────────────────────────────────────────
#  CREATE DESTINATION & COPY FILES
# ─────────────────────────────────────────────
Write-Log "Creating destination folder: $Destination"
try {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
} catch {
    Write-Log "Could not create destination folder: $_" 'ERROR'
    exit 1
}

Write-Log "Copying files..."
$copied  = 0
$errored = 0
foreach ($file in $requiredFiles) {
    $src  = Join-Path $sourceDir $file
    $dest = Join-Path $Destination $file
    try {
        Copy-Item -Path $src -Destination $dest -Force
        Write-Log "  Copied: $file" 'SUCCESS'
        $copied++
    } catch {
        Write-Log "  FAILED: $file — $_" 'ERROR'
        $errored++
    }
}

# ─────────────────────────────────────────────
#  CLEANUP TEMP EXTRACT (ZIP MODE ONLY)
# ─────────────────────────────────────────────
if ($Mode -eq 'ZIP' -and (Test-Path (Join-Path $env:TEMP 'TroubleshootWizard_Extract'))) {
    Remove-Item (Join-Path $env:TEMP 'TroubleshootWizard_Extract') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Cleaned up temp extract folder."
}

# ─────────────────────────────────────────────
#  RESULT
# ─────────────────────────────────────────────
Write-Log "====== Install complete — $copied copied, $errored failed ======"

if ($errored -gt 0) {
    Write-Log "Installation completed with errors. Review log: $logFile" 'WARNING'
    exit 2
}

Write-Log "TroubleshootWizard installed successfully to: $Destination" 'SUCCESS'
exit 0
