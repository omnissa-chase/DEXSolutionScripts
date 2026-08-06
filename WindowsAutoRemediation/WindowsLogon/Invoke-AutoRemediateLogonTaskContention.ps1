#Requires -Version 5.1
<#
.SYNOPSIS
    Staggers third-party scheduled tasks that trigger At Log On, so they stop
    competing with the shell, Group Policy, and profile load for CPU and disk
    during the critical part of logon.

.DESCRIPTION
    A logon-triggered task with no delay starts the instant the user's session
    begins -- at exactly the same moment as everything Measure-LogonDuration.ps1
    measures. A handful of vendor agents (updaters, print agents, sync clients,
    telemetry) all doing this at once is a direct, measurable tax on shell-ready
    time, and it compounds: the more of them there are, the more they fight each
    other for the same disk and CPU the profile load and Explorer startup need.

    This script only ever adds or increases a trigger's Delay. It never disables,
    deletes, or otherwise changes what a task does -- staggering is non-destructive
    and fully reversible (delete the assigned Delay, or just increase MinDelaySeconds
    back down and re-run).

    Scope is deliberately narrow: only tasks outside the \Microsoft\ task-scheduler
    namespace are touched. Built-in Windows tasks are already tuned by the OS and
    are not a supported target for a generic script to rewrite. Tasks a vendor
    installed under their own path are fair game.

    +------+---------------------------------+--------------------------------------+
    | Step | Name                             | Action                                |
    +------+---------------------------------+----------------------------------------+
    |  1   | AtLogOn Task Trigger Delay      | Add/raise Delay on qualifying triggers |
    |  2   | AtLogOn Task Volume             | Report only                            |
    +------+---------------------------------+----------------------------------------+

    Step 2 has no remediation. A large number of logon-triggered tasks, even once
    each is staggered, is still a sign of image bloat worth an admin's attention --
    but deciding which of them to remove or disable needs to know what each task is
    for, which this script cannot know generically.

    Each qualifying task is assigned an increasing delay (MinDelaySeconds, then
    +StaggerSeconds per additional task, in a stable TaskPath/TaskName order) so
    they fire spread out rather than all landing on the same later moment.

    Results are written to HKLM:\Software\AirWatch\Extensions\LogonTaskContention\Remediation.

.PARAMETER MinDelaySeconds
    The minimum Delay a qualifying AtLogOn trigger must have. Any qualifying
    trigger with less than this (including no delay at all) is raised to at least
    this value. Defaults to $env:MinDelaySeconds, then to 60.

.PARAMETER StaggerSeconds
    Additional delay added per task beyond the first, so multiple qualifying tasks
    do not all land on the same post-logon moment. Defaults to $env:StaggerSeconds,
    then to 30.

.PARAMETER TaskVolumeWarnCount
    Number of qualifying AtLogOn tasks that triggers the report-only volume
    warning in step 2. Defaults to $env:TaskVolumeWarnCount, then to 8.

.EXAMPLE
    .\Invoke-AutoRemediateLogonTaskContention.ps1 -MinDelaySeconds 90 -StaggerSeconds 45

    Every qualifying task gets at least a 90 second delay, spaced 45 seconds apart.

.EXAMPLE
    $env:WhatIf = 'true'; .\Invoke-AutoRemediateLogonTaskContention.ps1

    Reports which tasks would be delayed and by how much, without changing anything.
    This is the intended first run in a new environment.

.NOTES
    Script Name  : Invoke-AutoRemediateLogonTaskContention.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : 60 seconds

    Environment variables:
      WhatIf              = true   Dry run. Absent/unparseable => live run.
      MinDelaySeconds     = 60
      StaggerSeconds      = 30
      TaskVolumeWarnCount = 8

    Explicit parameters win over environment variables.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # ValidateRange applies to explicit arguments only, so a bad environment variable
    # degrades to the default instead of failing the run.
    [ValidateRange(0, 3600)]
    [int]$MinDelaySeconds = $(
        $v = 0
        if ([int]::TryParse("$env:MinDelaySeconds".Trim(), [ref]$v) -and $v -ge 0) { $v } else { 60 }
    ),

    [ValidateRange(0, 600)]
    [int]$StaggerSeconds = $(
        $v = 0
        if ([int]::TryParse("$env:StaggerSeconds".Trim(), [ref]$v) -and $v -ge 0) { $v } else { 30 }
    ),

    [ValidateRange(1, 100)]
    [int]$TaskVolumeWarnCount = $(
        $v = 0
        if ([int]::TryParse("$env:TaskVolumeWarnCount".Trim(), [ref]$v) -and $v -gt 0) { $v } else { 8 }
    )
)

$SCRIPT_VERSION = "1.0.0"
$RegPath        = "HKLM:\Software\AirWatch\Extensions\LogonTaskContention\Remediation"
$LogPath        = "$env:SystemRoot\Temp\UEM_AutoRemediateLogonTaskContention.log"

# -- WhatIf bridge -------------------------------------------------------------
# UEM cannot set $WhatIfPreference directly. Bridge it from an environment
# variable. Absent, empty, or unparseable => $false (live run).
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

# -- Run header ----------------------------------------------------------------
$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Host "[$RunEventId] Executing Invoke-AutoRemediateLogonTaskContention, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
$HEAD = "`r`n[$RunEventId]"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    # -WhatIf:$false so a dry run is still recorded; the log is evidence, not state.
    "[$timestamp] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}

Write-Log "Settings: MinDelaySeconds=$MinDelaySeconds StaggerSeconds=$StaggerSeconds TaskVolumeWarnCount=$TaskVolumeWarnCount"

# -- Pre-flight ------------------------------------------------------------------
if (-not (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    Write-Host "$HEAD The ScheduledTasks module is not available on this device. Nothing to do." -ForegroundColor Yellow
    Write-Log 'ScheduledTasks module unavailable. Exiting without changes.'
    exit 0
}

# -- ISO 8601 duration helpers ----------------------------------------------------
# Trigger.Delay is stored/read as an ISO 8601 duration string (e.g. 'PT1M30S').
function ConvertFrom-Iso8601Duration {
    param([string]$Duration)
    if ([string]::IsNullOrWhiteSpace($Duration)) { return 0 }
    if ($Duration -match '^PT(?:(?<h>\d+)H)?(?:(?<m>\d+)M)?(?:(?<s>\d+)S)?$') {
        $h = if ($Matches.h) { [int]$Matches.h } else { 0 }
        $m = if ($Matches.m) { [int]$Matches.m } else { 0 }
        $s = if ($Matches.s) { [int]$Matches.s } else { 0 }
        return ($h * 3600) + ($m * 60) + $s
    }
    return 0
}

function ConvertTo-Iso8601Duration {
    param([int]$TotalSeconds)
    if ($TotalSeconds -le 0) { return 'PT0S' }
    $h   = [math]::Floor($TotalSeconds / 3600)
    $rem = $TotalSeconds % 3600
    $m   = [math]::Floor($rem / 60)
    $s   = $rem % 60
    $out = 'PT'
    if ($h -gt 0) { $out += "${h}H" }
    if ($m -gt 0) { $out += "${m}M" }
    if ($s -gt 0 -or ($h -eq 0 -and $m -eq 0)) { $out += "${s}S" }
    return $out
}

# -- Discovery ---------------------------------------------------------------------
# Enabled tasks, outside the OS-owned \Microsoft\ namespace, with at least one
# AtLogOn trigger. Sorted for a stable, repeatable stagger assignment.
$AllTasks = @(
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object {
            $_.State -ne 'Disabled' -and
            $_.TaskPath -notlike '\Microsoft\*' -and
            ($_.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })
        } |
        Sort-Object TaskPath, TaskName
)

if ($AllTasks.Count -eq 0) {
    Write-Host "$HEAD No enabled AtLogOn-triggered tasks outside the Microsoft namespace were found. Nothing to do." -ForegroundColor Yellow
    Write-Log 'No qualifying logon-triggered tasks found. Exiting without changes.'
    exit 0
}

Write-Log "Qualifying tasks: $(($AllTasks | ForEach-Object { "$($_.TaskPath)$($_.TaskName)" }) -join ', ')"

$needFix = @(
    $AllTasks | Where-Object {
        $logonTriggers = @($_.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })
        $currentMin    = ($logonTriggers | ForEach-Object { ConvertFrom-Iso8601Duration $_.Delay } | Measure-Object -Minimum).Minimum
        if ($null -eq $currentMin) { $currentMin = 0 }
        $currentMin -lt $MinDelaySeconds
    }
)

$TasksNeedingDelay = @()
for ($i = 0; $i -lt $needFix.Count; $i++) {
    $TasksNeedingDelay += [PSCustomObject]@{
        Task          = $needFix[$i]
        TargetSeconds = $MinDelaySeconds + ($i * $StaggerSeconds)
    }
}

$script:TaskFixFailures = @()

# -- Step Definitions -----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'AtLogOn Task Trigger Delay'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if ($TasksNeedingDelay.Count -gt 0) {
                $detail = ($TasksNeedingDelay | ForEach-Object {
                    "$($_.Task.TaskPath)$($_.Task.TaskName) -> +$($_.TargetSeconds)s"
                }) -join ', '
                return @{ Status = 'Failed'; Message = "$($TasksNeedingDelay.Count) of $($AllTasks.Count) task(s) need a delay: $detail" }
            }
            return @{ Status = 'Passed'; Message = "All $($AllTasks.Count) qualifying task(s) already have at least a $MinDelaySeconds second delay" }
        }
        ResolutionScript = {
            foreach ($entry in $TasksNeedingDelay) {
                $task      = $entry.Task
                $targetIso = ConvertTo-Iso8601Duration $entry.TargetSeconds
                try {
                    foreach ($trigger in $task.Triggers) {
                        if ($trigger.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger') {
                            $current = ConvertFrom-Iso8601Duration $trigger.Delay
                            if ($current -lt $MinDelaySeconds) { $trigger.Delay = $targetIso }
                        }
                    }
                    Set-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
                } catch {
                    $script:TaskFixFailures += "$($task.TaskPath)$($task.TaskName): $($_.Exception.Message)"
                }
            }
            if ($script:TaskFixFailures.Count -gt 0) {
                throw "$($script:TaskFixFailures.Count) of $($TasksNeedingDelay.Count) task(s) failed: $($script:TaskFixFailures -join '; ')"
            }
        }
    },

    @{
        # Report only. Even fully staggered, a large count of vendor logon tasks is
        # an image-bloat signal an admin should see -- deciding which to remove
        # needs to know what each task is for, which this script cannot know.
        Name             = 'AtLogOn Task Volume'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if ($AllTasks.Count -ge $TaskVolumeWarnCount) {
                $names = ($AllTasks | ForEach-Object { "$($_.TaskPath)$($_.TaskName)" }) -join ', '
                return @{ Status = 'Warning'; Message = "$($AllTasks.Count) tasks trigger AtLogOn (warn threshold $TaskVolumeWarnCount): $names. Review for consolidation/removal; not auto-remediated." }
            }
            return @{ Status = 'Passed'; Message = "$($AllTasks.Count) tasks trigger AtLogOn, below the $TaskVolumeWarnCount warn threshold" }
        }
        ResolutionScript = $null
    }
)

# -- Execution Engine ------------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

Write-Host "`n-- Invoke-AutoRemediateLogonTaskContention --------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Host '--------------------------------------------------------------------' -ForegroundColor Cyan

foreach ($step in $activeSteps) {

    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''

    # -- Detection ------------------------------------------------------------
    try {
        $result  = & $step.DetectionScript
        $status  = $result.Status
        $message = $result.Message
    } catch {
        $status  = 'Failed'
        $message = "Detection exception: $($_.Exception.Message)"
    }

    # -- Remediation ------------------------------------------------------------
    $shouldRemediate = ($status -eq 'Failed') -or
                       ($status -eq 'Warning' -and $step.ResolveOnWarning)

    if ($shouldRemediate -and $step.ResolutionScript) {
        if ($PSCmdlet.ShouldProcess($step.Name, 'Set AtLogOn trigger delay')) {
            try {
                & $step.ResolutionScript | Out-Null
                $remediated = $true
            } catch {
                $remError = $_.Exception.Message
            }
        }
    }

    # -- Output -------------------------------------------------------------------
    $color = switch ($status) {
        'Passed'  { 'Green'  }
        'Warning' { 'Yellow' }
        'Failed'  { 'Red'    }
        default   { 'White'  }
    }
    $remNote = if ($remediated)   { '  -> Delay(s) applied' }
               elseif ($remError) { "  -> Remediation ERROR: $remError" }
               else               { '' }

    Write-Host "`n  [$($status.PadRight(7))] $($step.Name): $message$remNote" -ForegroundColor $color
    Write-Log "$($step.Name): $status - $message$remNote"

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary -----------------------------------------------------------------
$passed   = ($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = ($results | Where-Object { $_.Remediated }).Count
$remErrs  = ($results | Where-Object { $_.RemError }).Count

Write-Host "`n--------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations applied: $remCount"
Write-Host "--------------------------------------------------------------------`n" -ForegroundColor Cyan
Write-Log "Summary: Passed=$passed Warnings=$warnings Failed=$failed RemediationsApplied=$remCount RemediationErrors=$remErrs TasksDelayed=$($TasksNeedingDelay.Count - $script:TaskFixFailures.Count)"

# -- Registry Reporting --------------------------------------------------------
# Skipped entirely on a WhatIf run -- a dry run must not claim a remediation state
# that was never actually applied.
if (-not $WhatIfPreference) {
    try {
        if (-not (Test-Path $RegPath)) {
            New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $RegPath -Name 'LastRun'          -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Type String
        Set-ItemProperty -Path $RegPath -Name 'ScriptVersion'    -Value $SCRIPT_VERSION -Type String
        Set-ItemProperty -Path $RegPath -Name 'Passed'           -Value $passed   -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'Warnings'         -Value $warnings -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'Failed'           -Value $failed   -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'RemediationsRun'  -Value $remCount -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'RemediationErrors' -Value $remErrs -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'QualifyingTaskCount' -Value $AllTasks.Count -Type DWord
        Set-ItemProperty -Path $RegPath -Name 'TasksDelayed'     -Value ($TasksNeedingDelay.Count - $script:TaskFixFailures.Count) -Type DWord
        Write-Log "Results cached to $RegPath"
    } catch {
        Write-Log "Registry cache write failed: $($_.Exception.Message)" 'WARN'
    }
} else {
    Write-Log 'WhatIf run -- registry cache left untouched.'
}

exit $(if ($remErrs -gt 0) { 1 } else { 0 })
