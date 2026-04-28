<#
.SYNOPSIS
    Removes TroubleshootWizard from the device.

.PARAMETER Path
    Install folder to remove. Default: C:\ProgramData\AirWatch\Extensions\TroubleshootWizard
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Path = 'C:\ProgramData\AirWatch\Extensions\TroubleshootWizard'
)

$ErrorActionPreference = 'Stop'

$logFile = Join-Path $env:TEMP 'TroubleshootWizard_Uninstall.log'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    $colorMap = @{ INFO='White'; SUCCESS='Green'; WARNING='Yellow'; ERROR='Red' }
    $color = $colorMap[$Level]
    if (-not $color) { $color = 'White' }
    Write-Host $line -ForegroundColor $color
}

Write-Log "====== TroubleshootWizard Uninstaller ======"
Write-Log "Target: $Path"

if (-not (Test-Path $Path)) {
    Write-Log "Folder not found - nothing to remove." 'WARNING'
    exit 0
}

try {
    Remove-Item -Path $Path -Recurse -Force
    Write-Log "Removed: $Path" 'SUCCESS'
} catch {
    Write-Log "Failed to remove folder: $_" 'ERROR'
    exit 1
}

# ---------------------------------------------
#  REMOVE REGISTRY KEY
# ---------------------------------------------
$RegKeyPath = 'HKLM:\SOFTWARE\AirWatch\Extensions\TroubleshootWizard'
try {
    If (Test-Path $RegKeyPath) {
        Remove-Item -Path $RegKeyPath -Recurse -Force
        Write-Log "Registry key removed: $RegKeyPath" 'SUCCESS'
    } else {
        Write-Log "Registry key not found - skipping." 'WARNING'
    }
} catch {
    Write-Log "Failed to remove registry key: $_" 'WARNING'
}

Write-Log "Uninstall complete." 'SUCCESS'
exit 0

