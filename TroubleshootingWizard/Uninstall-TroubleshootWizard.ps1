<#
.SYNOPSIS
    Removes TroubleshootWizard: scheduled task, URL protocol, event source,
    install folder and detection registry key.

.PARAMETER Path
    Install folder to remove. Default: C:\ProgramData\AirWatch\Extensions\TroubleshootWizard

.PARAMETER UrlScheme
    URL protocol scheme that was registered. Default: omniwiz

.PARAMETER KeepEventSource
    Leave the 'TroubleshootingWizard' event source registered (existing events are
    never deleted either way; this only affects how old events are rendered).

.NOTES
    Exit codes: 0 success, 1 could not remove install folder.
    Log: %TEMP%\TroubleshootWizard_Uninstall.log

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding()]
param(
    [string] $Path      = 'C:\ProgramData\AirWatch\Extensions\TroubleshootWizard',
    [string] $UrlScheme = 'omniwiz',
    [switch] $KeepEventSource
)

$RegKeyPath  = 'HKLM:\SOFTWARE\AirWatch\Extensions\TroubleshootWizard'
$EventSource = 'TroubleshootingWizard'
$TaskPath    = '\Omnissa\TroubleshootWizard\'
$TaskName    = 'TroubleshootWizard-OnEvent'

$ErrorActionPreference = 'Stop'
$logFile = Join-Path $env:TEMP 'TroubleshootWizard_Uninstall.log'
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
    Write-Output $line
}

Write-Log '====== TroubleshootWizard Uninstaller ======'
Write-Log "Target: $Path"

# Prefer the values recorded at install time.
try {
    if (Test-Path $RegKeyPath) {
        $reg = Get-ItemProperty $RegKeyPath
        if ($reg.InstallPath -and -not $PSBoundParameters.ContainsKey('Path'))     { $Path = $reg.InstallPath }
        if ($reg.UrlScheme   -and -not $PSBoundParameters.ContainsKey('UrlScheme')) { $UrlScheme = $reg.UrlScheme }
    }
} catch { }

# --- Scheduled task ---
try {
    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false
        Write-Log "Scheduled task removed: $TaskPath$TaskName"
    } else { Write-Log 'Scheduled task not found - skipping.' }
    # Remove the (now empty) task folders.
    try {
        $svc = New-Object -ComObject Schedule.Service; $svc.Connect()
        $omnissa = $svc.GetFolder('\Omnissa')
        if (@($omnissa.GetFolder('TroubleshootWizard').GetTasks(0)).Count -eq 0) { $omnissa.DeleteFolder('TroubleshootWizard', 0) }
        if (@($omnissa.GetTasks(0)).Count -eq 0 -and @($omnissa.GetFolders(0)).Count -eq 0) { $svc.GetFolder('\').DeleteFolder('Omnissa', 0) }
    } catch { }
} catch { Write-Log "Failed to remove scheduled task: $_" 'WARNING' }

# --- URL protocol ---
foreach ($hive in 'HKLM:\SOFTWARE\Classes', 'HKCU:\Software\Classes') {
    $k = "$hive\$UrlScheme"
    try {
        if (Test-Path $k) { Remove-Item $k -Recurse -Force; Write-Log "URL protocol removed: $k" }
    } catch { Write-Log "Failed to remove $k : $_" 'WARNING' }
}

# --- Event source ---
if (-not $KeepEventSource) {
    try {
        $exists = $false
        try { $exists = [System.Diagnostics.EventLog]::SourceExists($EventSource) } catch { }
        if ($exists) { [System.Diagnostics.EventLog]::DeleteEventSource($EventSource); Write-Log "Event source removed: $EventSource" }
        else         { Write-Log 'Event source not found - skipping.' }
    } catch { Write-Log "Failed to remove event source: $_" 'WARNING' }
}

# --- Install folder ---
if (Test-Path $Path) {
    try {
        Remove-Item -Path $Path -Recurse -Force
        Write-Log "Removed: $Path"
    } catch {
        Write-Log "Failed to remove folder: $_" 'ERROR'
        exit 1
    }
} else { Write-Log 'Install folder not found - skipping.' 'WARNING' }

# --- Registry ---
try {
    if (Test-Path $RegKeyPath) { Remove-Item -Path $RegKeyPath -Recurse -Force; Write-Log "Registry key removed: $RegKeyPath" }
    else { Write-Log 'Registry key not found - skipping.' }
} catch { Write-Log "Failed to remove registry key: $_" 'WARNING' }

Write-Log 'Uninstall complete.'
exit 0
