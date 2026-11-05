<#
.SYNOPSIS
    Gracefully close (and optionally restart) a Windows process matched by
    FileDescription. Dispatches a detached watchdog so Intelligent Hub is never
    blocked, and force-kills ONLY a process confirmed to be hung.

.DESCRIPTION
    Thin launcher (back to Hub in ~1-2 s) plus a detached watchdog owned by Task
    Scheduler that does the waiting and escalation.

        Launcher (Hub thread)  ->  Watchdog (Task Scheduler)  ->  Sensor (reads result)

    Outcomes: ClosedGracefully, ForceKilled (confirmed hung only), UserActionRequired
    (still responding at the deadline, LEFT RUNNING), UnsavedWorkSuspected,
    Inaccessible (elevated target the Limited watchdog cannot reach), Error.
    A process that is still RESPONDING is never force-killed.

    In Detached mode the exit code reflects DISPATCH only. The authoritative result
    is %ProgramData%\AirWatch\Extensions\ProcessGraceful\state\result.json; the next
    launcher run mirrors it into DEXRecords as LastResult* values. Use -Mode Inline
    in the lab when the exit code must reflect the real outcome.
    Every parameter also reads an environment variable of the same name. Rationale,
    outcome table and timing budget: README.md (keeps this file under UEM's 32,767
    characters).

.PARAMETER FileDescription
    Substring of the process Description (binary FileDescription), wildcards escaped.
    Required. Examples: 'Microsoft Teams', 'Zoom', 'Google Chrome'.
.PARAMETER GracefulTimeoutSec
    Seconds to wait for a graceful exit per attempt. Default 15.
.PARAMETER Restart
    true/false/1/0/yes/no. Relaunch one instance (windowed match's path first) once
    every match closed; skipped while anything is still running. Default false.
.PARAMETER ForceOnlyIfUnresponsive
    Default true: force-kill only a confirmed hang. false forces at the deadline
    (data-loss risk). Always true when no user session exists.
.PARAMETER UnresponsiveSampleCount
    Consecutive 1 s checks with Responding=false before a hang is declared. Default 3.
.PARAMETER UserActionRetryCount
    Extra attempts after UserActionRequired. Default 1; 0 is single-shot.
.PARAMETER UserActionRetryDelaySec
    Seconds between attempts, polled every 5 s. Default 300.
.PARAMETER SkipIfUnsavedWork
    true: a title with a modified-document marker is never signalled. Default false.
.PARAMETER Mode
    Detached (default) or Inline (synchronous, lab only).

.NOTES
    Script Name  : Restart-WinProcessGraceful.ps1
    Version      : 2.2.0
    Architecture : Any (x86/x64)
    Context      : System (watchdog runs as the logged-on user -- see README.md)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05
    Timeout      : ~1-2 s (Detached). Watchdog cap covers every attempt and wait;
                   450 s at defaults. Formula in README.md.
    Reporting    : HKLM:\Software\AirWatch\Extension\DEXRecords\ProcessGraceful
                   %ProgramData%\AirWatch\Extensions\ProcessGraceful\state\result.json

    2.2.0: a failed Stop-Process is Error, not ClosedGracefully (the PID is checked).
    Launcher-matched PIDs out of the Limited watchdog's reach are reported
    Inaccessible. The task has an end boundary and DeleteExpiredTaskAfter, so Task
    Scheduler removes it when the watchdog cannot, and the log says which happened.
    The launcher mirrors the previous result.json into DEXRecords LastResult* values.
    Relaunch prefers a windowed match. Booleans accept 1/0/yes/no; wildcards in
    FileDescription are escaped.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function ConvertTo-Bool {
    param([string]$Value, [bool]$Default)
    switch -Regex ($Value.Trim()) {
        '^(1|true|yes|on)$'  { return $true }
        '^(0|false|no|off)$' { return $false }
        default              { return $Default }
    }
}

function Restart-WinProcessGraceful {
param(
    [string]$FileDescription          = $(if ($env:FileDescription)          { $env:FileDescription }                                 else { '' }),
    [int]   $GracefulTimeoutSec       = $(if ($env:GracefulTimeoutSec)       { [int]$env:GracefulTimeoutSec }                         else { 15 }),
    [bool]  $Restart                  = (ConvertTo-Bool $env:Restart $false),
    [bool]  $ForceOnlyIfUnresponsive  = (ConvertTo-Bool $env:ForceOnlyIfUnresponsive $true),
    [int]   $UnresponsiveSampleCount  = $(if ($env:UnresponsiveSampleCount)  { [int]$env:UnresponsiveSampleCount }                    else { 3 }),
    [int]   $UserActionRetryCount     = $(if ($env:UserActionRetryCount)     { [int]$env:UserActionRetryCount }                       else { 1 }),
    [int]   $UserActionRetryDelaySec  = $(if ($env:UserActionRetryDelaySec)  { [int]$env:UserActionRetryDelaySec }                    else { 300 }),
    [bool]  $SkipIfUnsavedWork        = (ConvertTo-Bool $env:SkipIfUnsavedWork $false),
    [ValidateSet('Detached','Inline')]
    [string]$Mode                     = $(if ($env:Mode)                     { $env:Mode }                                            else { 'Detached' })
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
$ResultFile  = Join-Path $StateDir 'result.json'
$RegPath     = 'HKLM:\Software\AirWatch\Extension\DEXRecords\ProcessGraceful'

# -- Helper: write a DEXRecords summary --------------------------------------
# Only succeeds elevated/SYSTEM. Non-fatal: result.json is the authoritative outcome.
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

# -- Mirror the previous result.json into HKLM (the user-token watchdog cannot) --
try {
    if (Test-Path $ResultFile) {
        $prev = Get-Content -Path $ResultFile -Raw -ErrorAction Stop | ConvertFrom-Json
        $seen = (Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue).LastResultCompletedAt
        if ($prev.CompletedAt -and [string]$prev.CompletedAt -ne [string]$seen) {
            $m = @{}
            foreach ($k in 'Status','TargetDescription','CompletedAt','MatchedCount','ClosedGracefullyCount','ForceKilledCount','UserActionRequiredCount','UnsavedWorkSuspectedCount','InaccessibleCount','ErrorCount','Restarted') {
                $m["LastResult$k"] = [string]$prev.$k
            }
            Set-DexRecord $m
            Write-Output "  Previous watchdog result ($($prev.CompletedAt), $($prev.Status)) mirrored to DEXRecords."
        }
    }
} catch { }

# -- Resolve execution context (hang detection needs an interactive session) ---
$isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem

$loggedOnUser = $null
try {
    $loggedOnUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
} catch { }

# 'User' can measure Responding; 'SYSTEM' sends the close signal and never forces.
# Inline runs in THIS process, so its own session decides.
$watchdogContext = if ($Mode -eq 'Inline') {
    if ($isSystem) { 'SYSTEM' } else { 'User' }
} elseif ($loggedOnUser) {
    'User'
} else {
    'SYSTEM'
}

# -- Discover matching processes (wildcards in the description match literally) --
$pattern = "*$([WildcardPattern]::Escape($FileDescription))*"
$procs = @(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Description -like $pattern })

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

# -- Watchdog source (single-quoted: everything resolves at watchdog runtime) ----
$WatchdogSource = @'
<#
    Watch-ProcessClose.ps1 -- GENERATED by Restart-WinProcessGraceful.ps1 v2.2.0 on
    every dispatch. DO NOT EDIT. Runs detached under Task Scheduler: sends the close
    signal, monitors each target, force-kills ONLY a process confirmed hung.
#>

$StateDir   = Join-Path $PSScriptRoot 'state'
$StateFile  = Join-Path $StateDir 'state.json'
$ResultFile = Join-Path $StateDir 'result.json'
$LogFile    = Join-Path $StateDir 'watchdog.log'

function Write-Log {
    param([string]$Message)
    try { "$(Get-Date -Format 'o')  $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
}

# True when no process with that PID exists any more.
function Test-Gone {
    param([int]$Id)
    try { return ($null -eq (Get-Process -Id $Id -ErrorAction SilentlyContinue)) } catch { return $true }
}

# Reason string when the window title shows a modified-document marker, else ''.
# A hit is a hint, not proof; a miss proves nothing. Title only -- see README.md.
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
    $pattern = "*$([WildcardPattern]::Escape([string]$state.FileDescription))*"
    $procs = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Description -like $pattern })

    foreach ($p in $procs) {
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

    # A launcher-matched PID still alive but not matched here is out of this token's
    # reach (elevated process, Limited watchdog). Report it rather than lose it.
    foreach ($id in @($state.MatchedPids)) {
        if ($procs.Id -contains $id) { continue }
        $alive = $null
        try { $alive = Get-Process -Id $id -ErrorAction SilentlyContinue } catch { }
        if (-not $alive) { continue }
        $tracked += [PSCustomObject]@{
            Proc = $alive; Id = $id; Name = $alive.Name; HasWindow = $false; Outcome = 'Inaccessible'
            Detail = 'Still running but not visible to this watchdog (elevated process, Limited token). Not signalled; needs an elevated close.'
            Streak = 0; Attempts = 0; UnsavedHint = ''
        }
        Write-Log "PID $id [$($alive.Name)] INACCESSIBLE from this token -- left running."
    }

    if ($tracked.Count -eq 0) {
        Write-Log 'No matching processes at watchdog start -- already closed.'
        $status = 'NoMatch'
    }

    # Relaunch path: a windowed match first, not a helper sharing the description.
    foreach ($t in @($tracked | Where-Object { $_.Outcome -eq 'Pending' } | Sort-Object { -not $_.HasWindow })) {
        try { if ($t.Proc.Path) { $restartPath = $t.Proc.Path; break } } catch { }
    }

    # -- Pre-flight unsaved-work hint ------------------------------------------
    # Recorded on every run; only blocks the close when SkipIfUnsavedWork is set.
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

    # -- Attempt loop (Responding is meaningful only for windowed processes in an
    # interactive session; only the UserActionRequired path loops, see README.md) --
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
                    # Either the process is gone, or Stop-Process was refused: only the
                    # first is a graceful close.
                    if (Test-Gone $t.Id) {
                        $t.Outcome = 'ClosedGracefully'
                        $t.Detail  = 'Process handle invalidated -- exited.'
                    } else {
                        $t.Outcome = 'Error'
                        $t.Detail  = "Still running; $($_.Exception.Message) (an elevated target cannot be stopped by the Limited watchdog)."
                        Write-Log "PID $($t.Id) ERROR, still running: $($_.Exception.Message)"
                    }
                }
            }
        }

        # -- Resolve anything still running at the deadline ---------------------
        foreach ($t in @($tracked | Where-Object { $_.Outcome -eq 'Pending' })) {
            # Force at timeout only when opted in AND measurable; SYSTEM never forces.
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

        # -- Wait (polled, so a user who closes the app is never re-signalled) ----
        if ($attempt -lt $maxAttempts) {
            $waiting = @($tracked | Where-Object { $_.Outcome -eq 'UserActionRequired' })
            if ($waiting.Count -eq 0) { break }

            Write-Log "Waiting ${retryDelay}s before attempt $($attempt + 1); $($waiting.Count) process(es) awaiting user action."
            $until = (Get-Date).AddSeconds($retryDelay)
            while ((Get-Date) -lt $until) {
                Start-Sleep -Seconds 5
                foreach ($t in @($waiting | Where-Object { $_.Outcome -eq 'UserActionRequired' })) {
                    $exited = $false
                    try { $t.Proc.Refresh(); $exited = $t.Proc.HasExited } catch { $exited = Test-Gone $t.Id }
                    if ($exited) {
                        $t.Outcome = 'ClosedGracefully'
                        $t.Detail  = "User closed it during the retry wait (after attempt $($t.Attempts))."
                        Write-Log "PID $($t.Id) closed by the user during the retry wait."
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

    # -- Optional restart (user session, so visible; anything still running blocks it)
    $blocked = @($tracked | Where-Object { $_.Outcome -in 'UserActionRequired','Error','UnsavedWorkSuspected','Inaccessible' }).Count
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
            InaccessibleCount       = @($tracked | Where-Object { $_.Outcome -eq 'Inaccessible' }).Count
            ErrorCount              = @($tracked | Where-Object { $_.Outcome -eq 'Error' }).Count
            Restarted               = $restarted
            Processes               = @($tracked | ForEach-Object {
                [PSCustomObject]@{ Id = $_.Id; Name = $_.Name; Outcome = $_.Outcome; Detail = $_.Detail; Attempts = $_.Attempts; UnsavedHint = $_.UnsavedHint }
            })
        }
        $summary | ConvertTo-Json -Depth 4 | Set-Content -Path $ResultFile -Encoding UTF8 -ErrorAction Stop
        Write-Log "Result written: matched=$($summary.MatchedCount) graceful=$($summary.ClosedGracefullyCount) forced=$($summary.ForceKilledCount) userpending=$($summary.UserActionRequiredCount) inaccessible=$($summary.InaccessibleCount) error=$($summary.ErrorCount)"
    } catch {
        Write-Log "Result write FAILED: $($_.Exception.Message)"
    }

    # Best-effort HKLM mirror; the next launcher run mirrors result.json if this fails.
    try {
        $reg = 'HKLM:\Software\AirWatch\Extension\DEXRecords\ProcessGraceful'
        if (-not (Test-Path $reg)) { New-Item -Path $reg -Force -ErrorAction Stop | Out-Null }
        foreach ($k in 'Status','CompletedAt','MatchedCount','ClosedGracefullyCount','ForceKilledCount','UserActionRequiredCount','UnsavedWorkSuspectedCount','InaccessibleCount','ErrorCount','Restarted') {
            $v = $summary.$k
            Set-ItemProperty -Path $reg -Name $k -Value $(if ($v -is [int]) { $v } else { [string]$v }) -ErrorAction Stop
        }
        foreach ($t in $tracked) {
            Set-ItemProperty -Path $reg -Name "PID$($t.Id)_Result" -Value "$($t.Name) :: $($t.Outcome) :: $($t.Detail)" -Type String -ErrorAction SilentlyContinue
        }
        Write-Log 'HKLM mirror written.'
    } catch { Write-Log 'HKLM mirror skipped (not permitted for this token); result.json is authoritative.' }

    # -- Self-cleanup (a Limited token cannot delete SYSTEM's task; say so) -------
    try { Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue } catch { }
    try {
        if ($state -and $state.TaskName -and (Get-ScheduledTask -TaskName $state.TaskName -ErrorAction SilentlyContinue)) {
            Unregister-ScheduledTask -TaskName $state.TaskName -Confirm:$false -ErrorAction SilentlyContinue
            if (Get-ScheduledTask -TaskName $state.TaskName -ErrorAction SilentlyContinue) {
                Write-Log "Scheduled task '$($state.TaskName)' could not be unregistered from this token; Task Scheduler deletes it after its end boundary ($($state.TaskExpires))."
            } else {
                Write-Log "Scheduled task '$($state.TaskName)' unregistered."
            }
        }
    } catch { }
    Write-Log 'Watchdog end.'
}

exit 0
'@

# -- Stage watchdog and state (budget covers every attempt and wait, README.md) --
$watchdogBudgetSec = ($GracefulTimeoutSec * (1 + $UserActionRetryCount)) +
                     ($UserActionRetryDelaySec * $UserActionRetryCount) + 120
$taskExpires = (Get-Date).AddSeconds($watchdogBudgetSec + 60)

try {
    foreach ($dir in @($BaseDir, $StateDir)) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    }

    # Only $StateDir opens up; the watchdog code stays under SYSTEM/Admins ACLs.
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
        TaskExpires             = $taskExpires.ToString('s')
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

    # One-shot trigger with an end boundary: Task Scheduler deletes the task a minute
    # after the budget even when the Limited watchdog cannot unregister it.
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
    $trigger.EndBoundary = $taskExpires.ToString('s')

    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Seconds $watchdogBudgetSec) `
        -DeleteExpiredTaskAfter (New-TimeSpan -Minutes 1) -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
        -Trigger $trigger -Settings $settings -Force -ErrorAction Stop | Out-Null

    Write-Output "  Watchdog dispatched as scheduled task '$TaskName' ($watchdogContext context), starts within 5 s, task expires $($taskExpires.ToString('HH:mm:ss'))."
    Write-Output "  Outcome will be written to: $ResultFile"
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
exit 0
}

# -- entry point (param block is inside the function: the UEM engine does not
# recognise one at script scope; inputs arrive as environment variables) --------
Restart-WinProcessGraceful
