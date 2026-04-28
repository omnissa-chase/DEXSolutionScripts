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
    $color = @{ INFO='White'; SUCCESS='Green'; WARNING='Yellow'; ERROR='Red' }[$Level]
    Write-Host $line -ForegroundColor ($color ?? 'White')
}

Write-Log "====== TroubleshootWizard Uninstaller ======"
Write-Log "Target: $Path"

if (-not (Test-Path $Path)) {
    Write-Log "Folder not found — nothing to remove." 'WARNING'
    exit 0
}

try {
    Remove-Item -Path $Path -Recurse -Force
    Write-Log "Removed: $Path" 'SUCCESS'
} catch {
    Write-Log "Failed to remove folder: $_" 'ERROR'
    exit 1
}

Write-Log "Uninstall complete." 'SUCCESS'
exit 0
