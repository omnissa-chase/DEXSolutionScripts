<#
.SYNOPSIS
    Start-SystemRun -- runs a PowerShell script as SYSTEM through a one-shot scheduled task and
    returns its output, so a lab test that needs the SYSTEM context can be driven from an
    elevated console without PsExec.

.DESCRIPTION
    Registers a scheduled task that runs as NT AUTHORITY\SYSTEM with highest privileges, starts
    it, waits for it to finish, prints the captured output and removes the task. The script's
    stdout, stderr and the exit code are captured through a cmd wrapper to a log file under
    C:\Temp\FixReport\SystemRun\.

    Use it for scripts whose documented context is System and that cannot be published to UEM
    for a test (for example Measure-LogonDurationMultiSession.ps1, which is over the UEM size
    limit). It is not needed for the *_BreakTest.ps1 harness, which runs elevated as the
    signed-in administrator.

.PARAMETER ScriptPath
    The .ps1 to run. Resolved to a full path.

.PARAMETER Arguments
    Extra arguments appended to the powershell.exe command line, for example
    '-DeployMode RunNow'. Quote values that contain spaces yourself.

.PARAMETER TimeoutMinutes
    How long to wait for the task to finish. Default 15.

.EXAMPLE
    .\Start-SystemRun.ps1 -ScriptPath ..\GenericTroubleshooting\WindowsStartup\Measure-LogonDurationMultiSession.ps1 -Arguments '-DeployMode RunNow'

.NOTES
    Script Name  : Start-SystemRun.ps1
    Version      : 1.0.0
    Context      : Administrator (elevated); the target runs as SYSTEM
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string]$Arguments = '',
    [int]$TimeoutMinutes = 15
)

$ErrorActionPreference = 'Stop'

$full = (Resolve-Path -LiteralPath $ScriptPath).Path
if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Script not found: $ScriptPath" }

$logDir   = 'C:\Temp\FixReport\SystemRun'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($full)
$log      = Join-Path $logDir "$baseName-$stamp.log"
$rcFile   = Join-Path $logDir "$baseName-$stamp.rc"
$taskName = "DEX_SystemRun_$stamp"

# cmd wrapper so stdout and stderr land in the log and the exit code survives the task.
$inner   = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$full`" $Arguments > `"$log`" 2>&1 & echo %ERRORLEVEL% > `"$rcFile`""
$action  = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c $inner"
$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes $TimeoutMinutes) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
try {
    Write-Output "Running as SYSTEM: $full $Arguments"
    Write-Output "Log: $log"
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 2
        $state = (Get-ScheduledTask -TaskName $taskName).State
    } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)

    if ($state -eq 'Running') {
        Write-Warning "Still running after $TimeoutMinutes min; stopping the task."
        Stop-ScheduledTask -TaskName $taskName
    }
} finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

Write-Output ('-' * 72)
if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log } else { Write-Warning 'No log was written.' }
Write-Output ('-' * 72)
$rc = if (Test-Path -LiteralPath $rcFile) { [int](Get-Content -LiteralPath $rcFile | Select-Object -First 1).Trim() } else { -1 }
Write-Output "Exit code: $rc"
exit $rc
