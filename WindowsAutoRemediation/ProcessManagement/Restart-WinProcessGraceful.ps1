<#
.SYNOPSIS
    Gracefully close (and optionally restart) a Windows process matched by
    FileDescription. Dispatches a detached watchdog so Intelligent Hub is never
    blocked, and force-kills ONLY a process confirmed to be hung.

.DESCRIPTION
    Two-part architecture. This script is a thin launcher that returns to Hub in
    ~1-2 seconds; all waiting and escalation happens in a detached watchdog owned
    by Task Scheduler.

        Launcher (Hub thread)  ->  Watchdog (Task Scheduler)  ->  Sensor (reads result)

    Per-target outcomes:
        exited                         -> ClosedGracefully
        unresponsive N checks in a row -> ForceKilled (N = UnresponsiveSampleCount)
        deadline hit while responding  -> UserActionRequired, LEFT RUNNING
        unsaved-work marker in title   -> UnsavedWorkSuspected (SkipIfUnsavedWork)

    KEY GUARANTEE
    A process that is still RESPONDING is never force-killed. That is almost always
    an app showing a "Save changes?" prompt -- exactly where forcing destroys work.
    It is left running, reported, and re-attempted up to UserActionRetryCount times.
    Force-kill is reserved for a process confirmed hung.

    EXIT CODE CAVEAT
    In Detached mode the exit code reflects successful DISPATCH, not the close
    outcome. The authoritative result is
    %ProgramData%\AirWatch\Extensions\ProcessGraceful\state\result.json, surfaced
    by the companion sensor process_graceful_lastresult.ps1. Use -Mode Inline for
    lab testing when the exit code must reflect the real outcome.

    FULL RATIONALE: see README.md in this folder -- why a scheduled task rather than
    Start-Job, why the watchdog runs in the user session, how unsaved work is
    detected and why Office ~$ files are not used, the outcome table, and the
    timing budget. Moved there to keep this script inside UEM's 32,767-char limit.

.PARAMETER FileDescription
    Substring matched (case-insensitive wildcard) against each process's
    Description field (the FileDescription from the binary's version info).
    Examples: 'Microsoft Teams', 'Zoom', 'Google Chrome'
    Accepts env var: $env:FileDescription. Required.

.PARAMETER GracefulTimeoutSec
    Seconds to wait for a graceful exit. On expiry a still-responding process is
    reported as UserActionRequired (it is NOT force-killed unless
    ForceOnlyIfUnresponsive is explicitly set to $false).
    Accepts env var: $env:GracefulTimeoutSec. Default: 15.

.PARAMETER Restart
    When true, re-launches one instance after all matching processes have closed.
    Skipped if any ended UserActionRequired, UnsavedWorkSuspected or Error -- those
    are still running. The watchdog is in the user's session, so the relaunched
    window is visible to them.
    Accepts env var: $env:Restart. Default: false.

.PARAMETER ForceOnlyIfUnresponsive
    When $true (default) force-kill is reserved for processes confirmed hung.
    Set $false to restore the legacy behaviour of force-killing at the deadline
    regardless of responsiveness -- risks data loss on apps showing a save prompt.
    Ignored (always treated as $true) when no user session exists.
    Accepts env var: $env:ForceOnlyIfUnresponsive. Default: true.

.PARAMETER UnresponsiveSampleCount
    Consecutive 1-second checks a windowed process must report Responding = false
    before it is treated as hung. Guards against a momentary UI stall (e.g. a
    large save) being misread as a hang. Streak resets on any recovery.
    Accepts env var: $env:UnresponsiveSampleCount. Default: 3.

.PARAMETER UserActionRetryCount
    Extra close attempts made after a process ends an attempt as
    UserActionRequired. 0 restores the old single-shot behaviour.
    Accepts env var: $env:UserActionRetryCount. Default: 1.

.PARAMETER UserActionRetryDelaySec
    Seconds to wait between attempts, giving the user time to answer the save
    prompt. Polled every 5 s, so an app closed during the wait is detected then
    rather than at the end. Ignored when UserActionRetryCount is 0.
    Accepts env var: $env:UserActionRetryDelaySec. Default: 300 (5 minutes).

.PARAMETER SkipIfUnsavedWork
    When $true, a process whose window title carries a modified-document marker is
    left completely alone -- no close signal, no kill -- and reported as
    UnsavedWorkSuspected. Default $false preserves existing behaviour: the hint is
    still detected and reported, it just does not block the close attempt.
    Accepts env var: $env:SkipIfUnsavedWork. Default: false.

.PARAMETER Mode
    Detached (default) -- dispatch the watchdog via Task Scheduler and return
    immediately. The only supported production mode.
    Inline -- run the watchdog synchronously in this process. Blocks the caller;
    for lab testing only.
    Accepts env var: $env:Mode.

.NOTES
    Script Name  : Restart-WinProcessGraceful.ps1
    Version      : 2.1.0
    Architecture : Any (x86/x64)
    Context      : System (watchdog runs as the logged-on user -- see README.md)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-09-02
    Timeout      : ~1-2 s (Detached). Watchdog cap covers every attempt and wait;
                   450 s at defaults. Formula in README.md.
    Reporting    : HKLM:\Software\AirWatch\Extension\DEXRecords\ProcessGraceful
                   %ProgramData%\AirWatch\Extensions\ProcessGraceful\state\result.json

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Restart-WinProcessGraceful {
param(
    [string]$FileDescription          = $(if ($env:FileDescription)          { $env:FileDescription }                                        else { '' }),
    [int]   $GracefulTimeoutSec       = $(if ($env:GracefulTimeoutSec)       { [int]$env:GracefulTimeoutSec }                                else { 15 }),
    [bool]  $Restart                  = $(if ($env:Restart)                  { [System.Convert]::ToBoolean($env:Restart) }                   else { $false }),
    [bool]  $ForceOnlyIfUnresponsive  = $(if ($env:ForceOnlyIfUnresponsive)  { [System.Convert]::ToBoolean($env:ForceOnlyIfUnresponsive) }    else { $true }),
    [int]   $UnresponsiveSampleCount  = $(if ($env:UnresponsiveSampleCount)  { [int]$env:UnresponsiveSampleCount }                           else { 3 }),
    [int]   $UserActionRetryCount     = $(if ($env:UserActionRetryCount)     { [int]$env:UserActionRetryCount }                              else { 1 }),
    [int]   $UserActionRetryDelaySec  = $(if ($env:UserActionRetryDelaySec)  { [int]$env:UserActionRetryDelaySec }                           else { 300 }),
    [bool]  $SkipIfUnsavedWork        = $(if ($env:SkipIfUnsavedWork)        { [System.Convert]::ToBoolean($env:SkipIfUnsavedWork) }         else { $false }),
    [ValidateSet('Detached','Inline')]
    [string]$Mode                     = $(if ($env:Mode)                     { $env:Mode }                                                   else { 'Detached' })
)

if ([string]::IsNullOrEmpty($FileDescription)) {
    Write-Error 'FileDescription is required. Pass it as a parameter or set $env:FileDescription.'
    exit 1
}

# -- Constants ----------------------------------------------------------------
$TaskName    = 'WS1_ProcessGracefulWatchdog'
$BaseDir     = Join-Path $env:ProgramData 'AirWatch\Extensions\ProcessGraceful'
$StateDir    = Join-Path $BaseDir 'state'
$WatchdogPs1 = Join-Path $BaseDir 'Watch-ProcessClose.ps1'
$StateFile   = Join-Path $StateDir 'state.json'
$RegPath     = 'HKLM:\Software\AirWatch\Extension\DEXRecords\ProcessGraceful'

# -- Helper: write a DEXRecords summary --------------------------------------
# Only succeeds when running elevated/SYSTEM. Failure is non-fatal: the watchdog
# writes the authoritative outcome to result.json which the companion sensor reads.
function Set-DexRecord {
    param([hashtable]$Values)
    try {
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null }
        foreach ($k in $Values.Keys) {
            $v    = $Values[$k]
            $type = if ($v -is [int]) { 'DWord' } else { 'String' }
            Set-ItemProperty -Path $RegPath -Name $k -Value $v -Type $type -ErrorAction Stop
        }
    } catch {
        Write-Output "  [Registry] Write skipped: $($_.Exception.Message)"
    }
}

# -- Resolve execution context ------------------------------------------------
# Hang detection depends on window-station access, which exists only inside an
# interactive user session. Determine up front which context the watchdog can use.
$isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem

$loggedOnUser = $null
try {
    $loggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
} catch { }

# 'User' => watchdog runs in the interactive session and CAN measure Responding.
# 'SYSTEM' => no interactive session; graceful close only, never force-kill.
#
# Inline mode is special: the watchdog runs in THIS process, so what matters is
# whether this process is in session 0, not whether a user happens to be logged
# on. Running Inline as SYSTEM cannot read Responding even with a user present.
$watchdogContext = if ($Mode -eq 'Inline') {
    if ($isSystem) { 'SYSTEM' } else { 'User' }
} elseif ($loggedOnUser) {
    'User'
} else {
    'SYSTEM'
}

# -- Discover matching processes ----------------------------------------------
# Process enumeration works fine from SYSTEM -- only window handles are unavailable.
$procs = @(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Description -like "*$FileDescription*" })

Write-Output "`r`n-- Restart-WinProcessGraceful (dispatch) ------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Target: '$FileDescription'   Mode: $Mode   Context: $watchdogContext"
Write-Output '----------------------------------------------------------------'

if ($procs.Count -eq 0) {
    Write-Output "  No running process matches description '*$FileDescription*'. Nothing to do."
    Set-DexRecord @{
        LastRunTime       = (Get-Date -Format 'o')
        TargetDescription = $FileDescription
        Status            = 'NoMatch'
        WatchdogContext   = $watchdogContext
        MatchedCount      = 0
    }
    exit 0
}

Write-Output "  $($procs.Count) process(es) matched:"
foreach ($p in $procs) {
    Write-Output "    PID $($p.Id.ToString().PadLeft(5))  $($p.Name.PadRight(20))  $($p.Description)"
}

# -- Watchdog source ----------------------------------------------------------
# Single-quoted here-string: nothing below is expanded by the launcher. All
# variables resolve at watchdog runtime. Regenerated on every dispatch.
$WatchdogSource = @'
<#
    Watch-ProcessClose.ps1 -- GENERATED FILE. DO NOT EDIT.
    Emitted by Restart-WinProcessGraceful.ps1 v2.1.0 and overwritten on every dispatch.

    Runs detached under Task Scheduler so Intelligent Hub is never held waiting.
    Sends the graceful close signal, monitors each target, and force-kills ONLY a
    process confirmed hung. A process that is still responding is left running.
#>

$StateDir   = Join-Path $PSScriptRoot 'state'
$StateFile  = Join-Path $StateDir 'state.json'
$ResultFile = Join-Path $StateDir 'result.json'
$LogFile    = Join-Path $StateDir 'watchdog.log'

function Write-Log {
    param([string]$Message)
    try { "$(Get-Date -Format 'o')  $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
}

# Reason string when the window title shows a modified-document marker, else ''.
# A hit is a hint, not proof; a miss proves nothing. Title only, no filesystem
# probing -- see README.md.
function Get-UnsavedHint {
    param($Proc)
    try {
        $title = [string]$Proc.MainWindowTitle
        if ([string]::IsNullOrWhiteSpace($title)) { return '' }
        $t = $title.Trim()
        if ($t.StartsWith('*')) {
            return "modified-document marker in window title: '$t'"
        }
        if ($t -match '(?i)\bunsaved\b') {
            return "window title reports unsaved content: '$t'"
        }
    } catch { }
    return ''
}

$state = $null
try {
    $state = Get-Content -Path $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json
} catch {
    Write-Log "FATAL: cannot read state file. $($_.Exception.Message)"
    exit 1
}

$tracked     = @()
$restartPath = $null
$restarted   = $false
$status      = 'Completed'

try {
    Write-Log "Start. Target='$($state.FileDescription)' Context=$($state.WatchdogContext) Timeout=$($state.GracefulTimeoutSec)s ForceOnlyIfUnresponsive=$($state.ForceOnlyIfUnresponsive)"

    # Re-discover: PIDs may have shifted between dispatch and execution.
    $procs = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Description -like "*$($state.FileDescription)*" })

    if ($procs.Count -eq 0) {
        Write-Log 'No matching processes at watchdog start -- already closed.'
        $status = 'NoMatch'
    }

    foreach ($p in $procs) {
        if (-not $restartPath) { try { $restartPath = $p.Path } catch { } }
        $hasWindow = $false
        try { $hasWindow = ($p.MainWindowHandle -ne [IntPtr]::Zero) } catch { }
        $tracked += [PSCustomObject]@{
            Proc        = $p
            Id          = $p.Id
            Name        = $p.Name
            HasWindow   = $hasWindow
            Outcome     = 'Pending'
            Detail      = ''
            Streak      = 0
            Attempts    = 0
            UnsavedHint = ''
        }
    }

    # -- Pre-flight unsaved-work hint ------------------------------------------
    # Recorded for visibility on every run. Only blocks the close when the admin
    # opted in via SkipIfUnsavedWork.
    foreach ($t in $tracked) {
        if (-not $t.HasWindow) { continue }
        $t.UnsavedHint = Get-UnsavedHint -Proc $t.Proc
        if (-not $t.UnsavedHint) { continue }
        Write-Log "PID $($t.Id) [$($t.Name)] unsaved-work hint: $($t.UnsavedHint)"
        if ([bool]$state.SkipIfUnsavedWork) {
            $t.Outcome = 'UnsavedWorkSuspected'
            $t.Detail  = "Left untouched, no close signal sent -- $($t.UnsavedHint)"
            Write-Log "PID $($t.Id) SKIPPED (SkipIfUnsavedWork enabled)."
        }
    }

    # -- Attempt loop ----------------------------------------------------------
    # Responding is only meaningful inside an interactive session AND for a process
    # that owns a window. Headless processes always report Responding = $true.
    # Only the UserActionRequired path loops -- see README.md.
    $canMeasure  = ($state.WatchdogContext -eq 'User')
    $samples     = [int]$state.UnresponsiveSampleCount
    $maxAttempts = 1 + [int]$state.UserActionRetryCount
    $retryDelay  = [int]$state.UserActionRetryDelaySec

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {

        if (@($tracked | Where-Object { $_.Outcome -eq 'Pending' }).Count -eq 0) { break }

        # -- Graceful close signal ---------------------------------------------
        foreach ($t in @($tracked | Where-Object { $_.Outcome -eq 'Pending' })) {
            $t.Attempts = $attempt
            $sent = $false
            if ($t.HasWindow) {
                # Works here because the watchdog shares the target's session/desktop.
                try {
                    $sent = $t.Proc.CloseMainWindow()
                    if ($sent) { Write-Log "PID $($t.Id) [$($t.Name)] graceful signal sent (CloseMainWindow), attempt $attempt/$maxAttempts." }
                } catch { }
            }
            if (-not $sent) {
                # taskkill without /F delivers WM_CLOSE / CTRL_CLOSE_EVENT via the kernel
                # and reaches windowless processes CloseMainWindow cannot target.
                try { $null = & taskkill.exe /PID $t.Id 2>&1 } catch { }
                Write-Log "PID $($t.Id) [$($t.Name)] graceful signal sent (taskkill, no /F), attempt $attempt/$maxAttempts. HasWindow=$($t.HasWindow)"
            }
        }

        # -- Monitor -----------------------------------------------------------
        $deadline = (Get-Date).AddSeconds([int]$state.GracefulTimeoutSec)

        while ((Get-Date) -lt $deadline -and @($tracked | Where-Object { $_.Outcome -eq 'Pending' }).Count -gt 0) {
            Start-Sleep -Seconds 1
            foreach ($t in @($tracked | Where-Object { $_.Outcome -eq 'Pending' })) {
                try {
                    $t.Proc.Refresh()
                    if ($t.Proc.HasExited) {
                        $t.Outcome = 'ClosedGracefully'
                        $t.Detail  = "Exited cleanly after graceful signal (attempt $($t.Attempts))."
                        Write-Log "PID $($t.Id) closed gracefully."
                        continue
                    }
                    if ($canMeasure -and $t.HasWindow) {
                        if (-not $t.Proc.Responding) {
                            $t.Streak++
                            Write-Log "PID $($t.Id) not responding ($($t.Streak)/$samples)."
                            if ($t.Streak -ge $samples) {
                                Stop-Process -Id $t.Id -Force -ErrorAction Stop
                                try { $t.Proc.WaitForExit(5000) | Out-Null } catch { }
                                $t.Outcome = 'ForceKilled'
                                $t.Detail  = "Confirmed hung: unresponsive for $($t.Streak) consecutive 1s checks."
                                Write-Log "PID $($t.Id) FORCE-KILLED (confirmed hung)."
                            }
                        } else {
                            # Reset on recovery so a momentary UI stall never escalates.
                            $t.Streak = 0
                        }
                    }
                } catch {
                    $t.Outcome = 'ClosedGracefully'
                    $t.Detail  = 'Process handle invalidated -- treated as exited.'
                }
            }
        }

        # -- Resolve anything still running at the deadline ---------------------
        foreach ($t in @($tracked | Where-Object { $_.Outcome -eq 'Pending' })) {
            # Force at timeout only when explicitly opted in AND we could actually
            # measure responsiveness. In SYSTEM context we never force: an unmeasurable
            # process must not be assumed hung.
            $forceAtTimeout = (-not [bool]$state.ForceOnlyIfUnresponsive) -and $canMeasure
            if ($forceAtTimeout) {
                try {
                    Stop-Process -Id $t.Id -Force -ErrorAction Stop
                    try { $t.Proc.WaitForExit(5000) | Out-Null } catch { }
                    $t.Outcome = 'ForceKilled'
                    $t.Detail  = 'Deadline reached; ForceOnlyIfUnresponsive was disabled.'
                    Write-Log "PID $($t.Id) force-killed at deadline (ForceOnlyIfUnresponsive disabled)."
                } catch {
                    $t.Outcome = 'Error'
                    $t.Detail  = "Force-kill failed: $($_.Exception.Message)"
                    Write-Log "PID $($t.Id) force-kill FAILED: $($_.Exception.Message)"
                }
            } else {
                $t.Outcome = 'UserActionRequired'
                $t.Detail  = "Still responding at deadline (attempt $attempt/$maxAttempts) -- left running. Likely awaiting user input (e.g. an unsaved-work prompt)."
                if ($t.UnsavedHint) { $t.Detail += " Hint: $($t.UnsavedHint)" }
                Write-Log "PID $($t.Id) still responding at deadline -- LEFT RUNNING (attempt $attempt/$maxAttempts)."
            }
        }

        # -- Wait, then re-queue for another attempt ----------------------------
        # Polled, not slept: a user who closes the app during the wait is picked
        # up here and never re-signalled.
        if ($attempt -lt $maxAttempts) {
            $waiting = @($tracked | Where-Object { $_.Outcome -eq 'UserActionRequired' })
            if ($waiting.Count -eq 0) { break }

            Write-Log "Waiting ${retryDelay}s before attempt $($attempt + 1); $($waiting.Count) process(es) awaiting user action."
            $until = (Get-Date).AddSeconds($retryDelay)
            while ((Get-Date) -lt $until) {
                Start-Sleep -Seconds 5
                foreach ($t in @($waiting | Where-Object { $_.Outcome -eq 'UserActionRequired' })) {
                    try {
                        $t.Proc.Refresh()
                        if ($t.Proc.HasExited) {
                            $t.Outcome = 'ClosedGracefully'
                            $t.Detail  = "User closed it during the retry wait (after attempt $($t.Attempts))."
                            Write-Log "PID $($t.Id) closed by the user during the retry wait."
                        }
                    } catch {
                        $t.Outcome = 'ClosedGracefully'
                        $t.Detail  = 'Process handle invalidated during retry wait -- treated as exited.'
                    }
                }
                if (@($waiting | Where-Object { $_.Outcome -eq 'UserActionRequired' }).Count -eq 0) { break }
            }

            foreach ($t in @($waiting | Where-Object { $_.Outcome -eq 'UserActionRequired' })) {
                $t.Outcome = 'Pending'
                $t.Streak  = 0
            }
        }
    }

    # -- Optional restart -------------------------------------------------------
    # Runs in the user's session here, so the window is actually visible to them.
    # UnsavedWorkSuspected blocks too: still running, so a restart would double it.
    $blocked = @($tracked | Where-Object { $_.Outcome -eq 'UserActionRequired' -or $_.Outcome -eq 'Error' -or $_.Outcome -eq 'UnsavedWorkSuspected' }).Count
    if ([bool]$state.Restart -and $blocked -eq 0 -and $restartPath) {
        try {
            Start-Sleep -Seconds 2
            Start-Process -FilePath $restartPath -ErrorAction Stop
            $restarted = $true
            Write-Log "Restarted: $restartPath"
        } catch {
            Write-Log "Restart FAILED: $($_.Exception.Message)"
        }
    } elseif ([bool]$state.Restart) {
        Write-Log "Restart skipped (blocked=$blocked, path='$restartPath')."
    }
}
catch {
    $status = 'Error'
    Write-Log "FATAL: $($_.Exception.Message)"
}
finally {
    # -- Write authoritative outcome for the companion sensor ------------------
    try {
        $summary = [PSCustomObject]@{
            Status                  = $status
            TargetDescription       = $state.FileDescription
            WatchdogContext         = $state.WatchdogContext
            CompletedAt             = (Get-Date -Format 'o')
            MatchedCount            = @($tracked).Count
            ClosedGracefullyCount   = @($tracked | Where-Object { $_.Outcome -eq 'ClosedGracefully' }).Count
            ForceKilledCount        = @($tracked | Where-Object { $_.Outcome -eq 'ForceKilled' }).Count
            UserActionRequiredCount = @($tracked | Where-Object { $_.Outcome -eq 'UserActionRequired' }).Count
            UnsavedWorkSuspectedCount = @($tracked | Where-Object { $_.Outcome -eq 'UnsavedWorkSuspected' }).Count
            ErrorCount              = @($tracked | Where-Object { $_.Outcome -eq 'Error' }).Count
            Restarted               = $restarted
            Processes               = @($tracked | ForEach-Object {
                [PSCustomObject]@{ Id = $_.Id; Name = $_.Name; Outcome = $_.Outcome; Detail = $_.Detail; Attempts = $_.Attempts; UnsavedHint = $_.UnsavedHint }
            })
        }
        $summary | ConvertTo-Json -Depth 4 | Set-Content -Path $ResultFile -Encoding UTF8 -ErrorAction Stop
        Write-Log "Result written: matched=$($summary.MatchedCount) graceful=$($summary.ClosedGracefullyCount) forced=$($summary.ForceKilledCount) userpending=$($summary.UserActionRequiredCount)"
    } catch {
        Write-Log "Result write FAILED: $($_.Exception.Message)"
    }

    # Best-effort HKLM mirror. Succeeds in SYSTEM context; expected to fail for a
    # standard user -- result.json above remains the source of truth either way.
    try {
        $reg = 'HKLM:\Software\AirWatch\Extension\DEXRecords\ProcessGraceful'
        if (-not (Test-Path $reg)) { New-Item -Path $reg -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $reg -Name 'Status'                  -Value $status                          -Type String -ErrorAction Stop
        Set-ItemProperty -Path $reg -Name 'CompletedAt'             -Value (Get-Date -Format 'o')           -Type String -ErrorAction Stop
        Set-ItemProperty -Path $reg -Name 'MatchedCount'            -Value @($tracked).Count                -Type DWord  -ErrorAction Stop
        Set-ItemProperty -Path $reg -Name 'ClosedGracefullyCount'   -Value @($tracked | Where-Object { $_.Outcome -eq 'ClosedGracefully' }).Count   -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path $reg -Name 'ForceKilledCount'        -Value @($tracked | Where-Object { $_.Outcome -eq 'ForceKilled' }).Count        -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path $reg -Name 'UserActionRequiredCount' -Value @($tracked | Where-Object { $_.Outcome -eq 'UserActionRequired' }).Count -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path $reg -Name 'UnsavedWorkSuspectedCount' -Value @($tracked | Where-Object { $_.Outcome -eq 'UnsavedWorkSuspected' }).Count -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path $reg -Name 'ErrorCount'              -Value @($tracked | Where-Object { $_.Outcome -eq 'Error' }).Count              -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path $reg -Name 'Restarted'               -Value ([int]$restarted)                -Type DWord  -ErrorAction Stop
        foreach ($t in $tracked) {
            Set-ItemProperty -Path $reg -Name "PID$($t.Id)_Result" -Value "$($t.Name) :: $($t.Outcome) :: $($t.Detail)" -Type String -ErrorAction SilentlyContinue
        }
    } catch { }

    # -- Self-cleanup ----------------------------------------------------------
    try { Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue } catch { }
    try {
        if ($state -and $state.TaskName) {
            if (Get-ScheduledTask -TaskName $state.TaskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $state.TaskName -Confirm:$false -ErrorAction SilentlyContinue
                Write-Log "Scheduled task '$($state.TaskName)' unregistered."
            }
        }
    } catch { }
    Write-Log 'Watchdog end.'
}

exit 0
'@

# -- Stage watchdog and state -------------------------------------------------
try {
    foreach ($dir in @($BaseDir, $StateDir)) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    }

    # Watchdog stays in $BaseDir under default ACLs (SYSTEM/Admins only). Only
    # $StateDir opens up, so a standard user can never modify the code that runs.
    if ($watchdogContext -eq 'User' -and $loggedOnUser) {
        try {
            $acl  = Get-Acl -Path $StateDir -ErrorAction Stop
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $loggedOnUser, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.SetAccessRule($rule)
            Set-Acl -Path $StateDir -AclObject $acl -ErrorAction Stop
        } catch {
            Write-Output "  [ACL] Could not grant '$loggedOnUser' write access to state folder: $($_.Exception.Message)"
        }
    }

    Set-Content -Path $WatchdogPs1 -Value $WatchdogSource -Encoding UTF8 -Force -ErrorAction Stop

    [PSCustomObject]@{
        FileDescription         = $FileDescription
        GracefulTimeoutSec      = $GracefulTimeoutSec
        Restart                 = $Restart
        ForceOnlyIfUnresponsive = $ForceOnlyIfUnresponsive
        UnresponsiveSampleCount = $UnresponsiveSampleCount
        UserActionRetryCount    = $UserActionRetryCount
        UserActionRetryDelaySec = $UserActionRetryDelaySec
        SkipIfUnsavedWork       = $SkipIfUnsavedWork
        WatchdogContext         = $watchdogContext
        TaskName                = $(if ($Mode -eq 'Detached') { $TaskName } else { '' })
        DispatchedAt            = (Get-Date -Format 'o')
        MatchedPids             = @($procs | ForEach-Object { $_.Id })
    } | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding UTF8 -Force -ErrorAction Stop
}
catch {
    Write-Output "  [ERR] Failed to stage watchdog: $($_.Exception.Message)"
    Set-DexRecord @{
        LastRunTime       = (Get-Date -Format 'o')
        TargetDescription = $FileDescription
        Status            = 'Error'
        WatchdogContext   = $watchdogContext
    }
    exit 1
}

# -- Inline mode: run synchronously (lab/testing only) ------------------------
if ($Mode -eq 'Inline') {
    Write-Output '  Running watchdog inline (blocking). Not for production use.'
    & $WatchdogPs1
    $code = $LASTEXITCODE
    Write-Output "  Watchdog finished inline with exit code $code."
    exit $code
}

# -- Detached mode: hand off to Task Scheduler and return immediately ---------
# Task Scheduler owns the watchdog, so it survives Hub reaping this script's tree.
try {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$WatchdogPs1`""

    $principal = if ($watchdogContext -eq 'User') {
        # Interactive => shares the target's desktop, so MainWindowHandle and
        # Responding are readable. Limited, not Highest -- see README.md.
        New-ScheduledTaskPrincipal -UserId $loggedOnUser -LogonType Interactive -RunLevel Limited
    } else {
        New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    }

    # Hard cap so a wedged watchdog can never linger. MUST cover every attempt plus
    # every wait between them, or the watchdog is killed mid-retry -- see README.md.
    $watchdogBudgetSec = ($GracefulTimeoutSec * (1 + $UserActionRetryCount)) +
                         ($UserActionRetryDelaySec * $UserActionRetryCount) + 120
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Seconds $watchdogBudgetSec) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    # Registered with no trigger, then started on demand: it runs immediately
    # under the Task Scheduler service rather than waiting on a clock trigger.
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
        -Settings $settings -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop

    Write-Output "  Watchdog dispatched as scheduled task '$TaskName' ($watchdogContext context)."
    Write-Output "  Outcome will be written to: $(Join-Path $StateDir 'result.json')"
}
catch {
    Write-Output "  [ERR] Failed to dispatch watchdog: $($_.Exception.Message)"
    Set-DexRecord @{
        LastRunTime       = (Get-Date -Format 'o')
        TargetDescription = $FileDescription
        Status            = 'Error'
        WatchdogContext   = $watchdogContext
        MatchedCount      = $procs.Count
    }
    exit 1
}

Set-DexRecord @{
    LastRunTime       = (Get-Date -Format 'o')
    TargetDescription = $FileDescription
    Status            = 'Dispatched'
    WatchdogContext   = $watchdogContext
    MatchedCount      = $procs.Count
}

Write-Output "----------------------------------------------------------------`r`n"

# Exit code reflects successful dispatch, NOT the final close outcome.
# Read result.json (or the companion sensor) for the actual result.
exit 0
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw. Inputs arrive as environment
# variables and are bound to the function's parameters below.

Restart-WinProcessGraceful
Exit 0
