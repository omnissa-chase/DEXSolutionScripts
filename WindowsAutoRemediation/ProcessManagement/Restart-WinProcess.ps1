<#
.SYNOPSIS
    Force-stops every process whose file description contains the given text, and
    optionally relaunches it from its original executable path.

.DESCRIPTION
    Blunt restart with no graceful phase. Use Restart-WinProcessGraceful.ps1 when the
    target may have unsaved user work. Matching is a case-insensitive substring match
    on the process Description (the FileDescription field of the executable).

.NOTES
    Script Name  : Restart-WinProcess.ps1
    Data Type    : String
    Version      : 1.1.1
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-10-30
    Timeout      : 30 seconds

    Inputs (UEM script variables / environment):
        FileDescription  Required. Substring of the process Description to match.
        StartService     Optional. true/false. Relaunch each stopped process from its
                         original path after a 5 second pause. Default false.
                         Under UEM this script runs as SYSTEM, so the relaunch lands in
                         session 0 where no user can see it (confirmed with Chrome on
                         2026-10-30). Use it for background processes only; for user
                         applications use Restart-WinProcessGraceful.ps1, whose watchdog
                         runs in the user's session.

    Exit codes: 0 all matched processes stopped (or none were running); 1 missing input
    or at least one process could not be stopped.

    1.1.0: the previous version referenced an undefined $ProcessName variable, so every
    match ended in exit 1 without stopping anything. Processes are now stopped by Id,
    relaunch uses the recorded executable path, and StartService is parsed as a boolean
    string instead of a raw [bool] cast (which treated 'false' as $true).

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Restart-WinProcess {
param(
    [Parameter(Mandatory=$true)]
    [string]$FileDescription,
    [bool]$StartService = $false
)

$procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Description -like "*$FileDescription*" })

if ($procs.Count -eq 0) {
    Write-Output "No running process matches description '*$FileDescription*'. Nothing to do."
    Exit 0
}

$failures  = 0
$toRestart = @()
foreach ($proc in $procs) {
    $name = $proc.ProcessName
    $path = $null
    try { $path = $proc.Path } catch { }

    Write-Output "Stopping process '$name' (PID: $($proc.Id))..."
    Try {
        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        if ($path -and ($toRestart -notcontains $path)) { $toRestart += $path }
    } Catch {
        $failures++
        Write-Output "Failed to stop process '$name' (PID: $($proc.Id)). Exception: $($_.Exception.Message)"
    }
}

if ($StartService -and $toRestart.Count -gt 0) {
    Start-Sleep -Seconds 5
    foreach ($path in $toRestart) {
        Write-Output "Starting process '$path'..."
        Try {
            Start-Process -FilePath $path -ErrorAction Stop
        } Catch {
            $failures++
            Write-Output "Failed to start '$path'. Exception: $($_.Exception.Message)"
        }
    }
}

if ($failures -gt 0) { Exit 1 }
Exit 0
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw. Inputs arrive as environment
# variables and are bound to the function's parameters below.

if ([string]::IsNullOrEmpty($env:FileDescription)) {
    Write-Output "Error: FileDescription is not specified."
    Exit 1
}

$startService = $false
if (-not [string]::IsNullOrEmpty($env:StartService)) {
    try { $startService = [System.Convert]::ToBoolean($env:StartService) }
    catch { $startService = ($env:StartService -match '^(1|y|yes)$') }
}

Restart-WinProcess -FileDescription $env:FileDescription -StartService $startService
Exit 0
