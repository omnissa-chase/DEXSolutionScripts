<#
.SYNOPSIS
    Restart-WinProcessGraceful_BreakTest -- launches a real windowed process as the
    signed-in user, then verifies Restart-WinProcessGraceful.ps1 closes it gracefully,
    relaunches it when asked, and reports honestly when nothing matches.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Restart-WinProcessGraceful\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It starts a GUI application in the
    signed-in user's session and lets the script under test close it, then kills
    whatever is left of it. Run it only on a disposable VM or a marked test host. See
    Assert-DexTestHost in DEXTestFramework.psm1.

    WHAT IS BEING TESTED
    Restart-WinProcessGraceful.ps1 is a dispatch-only launcher: it finds every process
    whose FileDescription contains $env:FileDescription, stages a watchdog, registers
    'WS1_ProcessGracefulWatchdog' as an Interactive/Limited task for the logged-on
    user, starts it and exits 0. The watchdog sends the graceful close signal, waits
    up to GracefulTimeoutSec, optionally relaunches one instance, and writes the
    authoritative outcome to
    %ProgramData%\AirWatch\Extensions\ProcessGraceful\state\result.json. The launcher
    itself writes HKLM:\Software\AirWatch\Extension\DEXRecords\ProcessGraceful
    (Status = Dispatched | NoMatch | Error, MatchedCount, TargetDescription).

    This harness runs the production path (Mode = Detached) exactly as the SysMain
    harness runs its target: powershell.exe -File with the inputs supplied as
    environment variables, the way Workspace ONE Hub supplies them. Validation then
    waits for the watchdog's result.json and checks it against the process table.

    TARGET SELECTION
    The target is chosen at run time from an ordered candidate list and the
    FileDescription passed to the script is read from the binary's VersionInfo, never
    hard-coded:
      1. C:\Windows\System32\notepad.exe   ('Notepad'; on Windows 11 this stub hands
         off to the Store Notepad, whose process reports 'Notepad.exe' -- the script's
         wildcard match covers both)
      2. C:\Windows\System32\charmap.exe   ('Character Map'; classic Win32 window,
         no save prompt, rarely already open)
      3. Google Chrome                      (the UEM manifest's own target)
      4. C:\Windows\System32\cmd.exe        (last resort; under Windows Terminal a
         console process owns no window, so a graceful close may not land)
    A candidate is SKIPPED when any process already matches its description: the
    script closes every match, and the harness must never close something the user
    opened. Capture records those pre-existing PIDs so Restore can tell them apart
    from anything the test launched. If every candidate is in use the run aborts
    with a HarnessError rather than touching the user's windows.

    WHY THE TARGET IS LAUNCHED THROUGH A SCHEDULED TASK
    The harness runs elevated; the watchdog runs as the user with a Limited token.
    UIPI blocks WM_CLOSE from a medium-integrity process to an elevated window, the
    Limited watchdog cannot read an elevated process's FileDescription, and it cannot
    Stop-Process it either. A target started directly from here would therefore be
    invisible or unclosable to the watchdog and the run would prove nothing. The
    target is instead started by a throwaway Interactive/Limited task for the
    logged-on user -- the same technique the script itself uses -- so it runs with
    exactly the token the watchdog has. The task is removed once the process is up;
    the launched process survives that (verified on this host).

    EXPECTED OUTCOMES
      ExpectFixed        -- the watchdog must close the target gracefully (and relaunch
                            it when Restart is true)
      ExpectReportedOnly -- the launcher must report NoMatch and dispatch nothing

    ProcessRunningRestart    Target running, Restart=true. Launcher exits 0, lists the
                             target PID, reports Dispatched. result.json shows Status
                             Completed, the PID ClosedGracefully, no force-kill, no
                             UserActionRequired, Restarted=true. The original PID is
                             gone and a process with the same FileDescription and a
                             newer StartTime is running.
    ProcessRunningNoRestart  Same, with Restart=false. result.json Restarted=false and
                             no new matching process exists afterwards.
    ProcessNotRunning        Nothing matches. Launcher exits 0 with 'No running process
                             matches description', DEXRecords Status=NoMatch and
                             MatchedCount=0, no result.json written, no watchdog task
                             registered.

    The three breaks need three different sets of environment variables for the
    single remediation run, so they are mutually exclusive: BreakCount defaults to 1
    and when more than one is selected the one drawn first is kept. Replay with
    -Seed or pin one with -BreakName.

    Not covered: the hung-process branch (ForceKilled) and the responding-at-deadline
    branch (UserActionRequired, UserActionRetryCount loop). Both need a process that
    ignores WM_CLOSE on demand; a reliable, reversible fixture for that is a separate
    piece of work.

    TIMING
    GracefulTimeoutSec=15, UserActionRetryCount=0, UserActionRetryDelaySec=5 are
    pinned so a close that fails to land surfaces in ~20 s instead of the 5-minute
    default retry wait. Validation waits at most 60 s for result.json.

    EXIT CODE CAVEAT
    The script documents that exit 0 means successful DISPATCH, not a successful
    close. An Overall of FalsePass here therefore means 'dispatch reported success
    but the watchdog outcome or the process table did not match' -- exactly the gap
    the caveat warns about.

    REBOOTS
    Nothing here is flagged RequiresReboot. -IncludeRebootBreaks is accepted for
    parity with the other harnesses and has no effect.

.PARAMETER RemediationTest
    After breaking, run Restart-WinProcessGraceful.ps1 and validate the outcome.
    Without this the script breaks and reports only.

.PARAMETER Environment
    Physical (default) restores the machine when the run ends.
    Snapshot skips restore on the assumption the host reverts a checkpoint.

.PARAMETER Seed
    Replays an earlier run's random break selection exactly. Omit for a new random
    seed, which is always recorded in the result.

.PARAMETER BreakName
    Force specific breaks instead of a random selection.

.PARAMETER BreakCount
    How many components to break when selecting randomly. Default 1 (see above).

.PARAMETER IncludeRebootBreaks
    Allow breaks that require a reboot to take effect. Default off. No effect here.

.PARAMETER Restore
    Undo an in-flight run's breaks and exit. No remediation, no validation.

.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot.

.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Restart-WinProcessGraceful_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/arm64)
    Context      : Administrator (elevated), interactive session of the signed-in user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
    Reporting    : C:\Temp\FixReport\Restart-WinProcessGraceful\

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [switch]$RemediationTest,
    [ValidateSet('Snapshot', 'Physical')][string]$Environment = 'Physical',
    [int]$Seed = 0,
    [string[]]$BreakName,
    [int]$BreakCount = 1,
    [switch]$IncludeRebootBreaks,
    [switch]$Restore,
    [switch]$Resume,
    [switch]$Force,
    [string[]]$ProductionDomainDenyList = @()
)

$ErrorActionPreference = 'Stop'

$ScriptUnderTest   = 'Restart-WinProcessGraceful'
$RemediationScript = Join-Path $PSScriptRoot '..\Restart-WinProcessGraceful.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\ProcessGraceful'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Script-under-test artefacts -----------------------------------------------
# Paths and names the launcher and its watchdog use; validation reads them, the
# fixture clears them so nothing found later can be left over from an earlier run.
$WatchdogTaskName   = 'WS1_ProcessGracefulWatchdog'
$WatchdogStateDir   = Join-Path $env:ProgramData 'AirWatch\Extensions\ProcessGraceful\state'
$WatchdogResultFile = Join-Path $WatchdogStateDir 'result.json'
$WatchdogLogFile    = Join-Path $WatchdogStateDir 'watchdog.log'

# Throwaway task used to start the target with the signed-in user's Limited token.
$LaunchTaskName = 'DEX_BreakTest_ProcessGraceful_Launch'
$LaunchWaitSec  = 30

# Inputs handed to the script as environment variables, exactly as Hub would. The
# per-break Variables (Restart) are merged over these. Pinned short so a close that
# does not land is visible in seconds, not after the 300 s default retry wait.
$TargetVariables = @{
    GracefulTimeoutSec      = '15'
    ForceOnlyIfUnresponsive = 'true'
    UnresponsiveSampleCount = '3'
    UserActionRetryCount    = '0'
    UserActionRetryDelaySec = '5'
    SkipIfUnsavedWork       = 'false'
    Mode                    = 'Detached'
}
# Every attempt plus every wait, plus slack for Task Scheduler start-up latency.
$WatchdogWaitSec = ([int]$TargetVariables.GracefulTimeoutSec * (1 + [int]$TargetVariables.UserActionRetryCount)) +
                   ([int]$TargetVariables.UserActionRetryDelaySec * [int]$TargetVariables.UserActionRetryCount) + 45

# -- Fixture ------------------------------------------------------------------
# Nothing is built; the fixture clears every trace of an earlier dispatch so a
# DEXRecords value, result.json or watchdog task seen during validation was produced
# by THIS run. result.json and the DEXRecords key written by the run are kept as
# evidence.
function Initialize-Fixture {
    if (Test-Path -LiteralPath $DexRecordsPath) {
        Remove-Item -LiteralPath $DexRecordsPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Cleared stale DEXRecords at $DexRecordsPath"
    }
    if (Test-Path -LiteralPath $WatchdogResultFile) {
        Remove-Item -LiteralPath $WatchdogResultFile -Force -ErrorAction Stop
        Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Removed stale $WatchdogResultFile"
    }
    if (Get-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue) {
        # Left behind by an earlier dispatch: the Limited watchdog cannot delete a task
        # the elevated launcher registered, so its self-cleanup silently fails.
        Stop-WatchdogTask
        Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Removed stale scheduled task '$WatchdogTaskName'"
    }
    Remove-LaunchTask
}

function Remove-Fixture {
    # result.json and the DEXRecords key are left in place for the operator. Only the
    # harness's own launch task is removed; the watchdog task is handled per break.
    Remove-LaunchTask
}

# -- Helpers ------------------------------------------------------------------

function Get-LoggedOnUser {
    try {
        return (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
    } catch {
        return $null
    }
}

function Get-MatchingProcess {
    <#
        Same predicate the script under test uses, so 'what the harness sees' and
        'what the launcher will act on' can never drift apart.
    #>
    param([Parameter(Mandatory = $true)][string]$FileDescription)
    # Plain enumeration on purpose: every caller wraps the call in @(...). A leading
    # comma here would hand that @() one element that is itself the whole array.
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Description -like "*$FileDescription*" })
}

function Get-TargetCandidate {
    <#
        Ordered list of launchable targets with their FileDescription read from the
        binary at run time. Missing binaries are dropped here; in-use ones are marked
        Skipped by the caller.
    #>
    $list = @()

    $notepad = Join-Path $env:windir 'System32\notepad.exe'
    if (Test-Path -LiteralPath $notepad) {
        $list += @{
            Name            = 'Notepad'
            Path            = $notepad
            FileDescription = [string](Get-Item -LiteralPath $notepad).VersionInfo.FileDescription
        }
    }

    # Classic Win32 GUI app, still inbox on Windows 11, owns a real window, closes on
    # WM_CLOSE without a prompt and relaunches from its own Path. Rarely already open,
    # so it is the usual fallback when the user has Notepad up.
    $charmap = Join-Path $env:windir 'System32\charmap.exe'
    if (Test-Path -LiteralPath $charmap) {
        $list += @{
            Name            = 'CharacterMap'
            Path            = $charmap
            FileDescription = [string](Get-Item -LiteralPath $charmap).VersionInfo.FileDescription
        }
    }

    $chrome = $null
    foreach ($p in @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )) {
        if ($p -and (Test-Path -LiteralPath $p)) { $chrome = $p; break }
    }
    if (-not $chrome) {
        $appPath = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)'
        if ($appPath -and (Test-Path -LiteralPath $appPath)) { $chrome = $appPath }
    }
    if ($chrome) {
        $list += @{
            Name            = 'GoogleChrome'
            Path            = $chrome
            FileDescription = [string](Get-Item -LiteralPath $chrome).VersionInfo.FileDescription
        }
    }

    $cmd = Join-Path $env:windir 'System32\cmd.exe'
    if (Test-Path -LiteralPath $cmd) {
        $list += @{
            Name            = 'CommandProcessor'
            Path            = $cmd
            FileDescription = [string](Get-Item -LiteralPath $cmd).VersionInfo.FileDescription
        }
    }

    # Drop anything whose VersionInfo carried no description: an empty wildcard
    # would match every process on the box.
    $list = @($list | Where-Object { -not [string]::IsNullOrWhiteSpace($_.FileDescription) })
    # Enumerated, not comma-wrapped: callers use @(Get-TargetCandidate).
    return $list
}

function Get-TargetBaseline {
    <#
        Capture for the running-process breaks. Records every candidate, which ones
        are already in use (and by which PIDs) and therefore protected, and leaves
        the Launched* fields for Apply to fill in. Output is assigned by the caller,
        so nothing may be written to the output stream here -- Write-Host only.
    #>
    $candidates = @()
    foreach ($c in @(Get-TargetCandidate)) {
        $existing = @(Get-MatchingProcess -FileDescription $c.FileDescription | ForEach-Object { $_.Id })
        $skipped  = ($existing.Count -gt 0)
        if ($skipped) {
            Write-Host "           - candidate '$($c.Name)' ('$($c.FileDescription)') skipped: already running as PID $($existing -join ', ') -- not ours to close" -ForegroundColor DarkYellow
        } else {
            Write-Host "           - candidate '$($c.Name)' ('$($c.FileDescription)') eligible: $($c.Path)" -ForegroundColor Gray
        }
        $candidates += @{
            Name            = $c.Name
            Path            = $c.Path
            FileDescription = $c.FileDescription
            PreExistingPids = @($existing)
            Skipped         = $skipped
        }
    }

    if (@($candidates | Where-Object { -not $_.Skipped }).Count -eq 0) {
        throw 'Every candidate target already has an instance running that this test did not start. Close them (or add a candidate) and re-run.'
    }

    return @{
        CapturedAt        = (Get-Date).ToString('o')
        Candidates        = $candidates
        CandidateName     = $null
        ExePath           = $null
        FileDescription   = $null
        PreExistingPids   = @()
        LaunchedPid       = $null
        LaunchedName      = $null
        LaunchedPath      = $null
        LaunchedStartTime = $null
    }
}

function Get-NoMatchBaseline {
    <#
        Capture for the not-running break: the first candidate with no live match,
        so the launcher is asked about a real application that happens to be closed.
        If every candidate is open, a synthetic description that cannot match keeps
        the break meaningful without touching the user's windows.
    #>
    $chosen = $null
    foreach ($c in @(Get-TargetCandidate)) {
        if (@(Get-MatchingProcess -FileDescription $c.FileDescription).Count -eq 0) { $chosen = $c; break }
        Write-Host "           - candidate '$($c.Name)' ('$($c.FileDescription)') is running; looking for a closed one" -ForegroundColor Gray
    }

    $desc = if ($chosen) { $chosen.FileDescription } else { "DEXBreakTest-NoSuchProcess-$([guid]::NewGuid().ToString('N').Substring(0, 8))" }
    Write-Host "           - FileDescription for the no-match case: '$desc'" -ForegroundColor Gray

    return @{
        CapturedAt      = (Get-Date).ToString('o')
        CandidateName   = $(if ($chosen) { $chosen.Name } else { 'Synthetic' })
        ExePath         = $(if ($chosen) { $chosen.Path } else { $null })
        FileDescription = $desc
        PreExistingPids = @()
    }
}

function Remove-LaunchTask {
    $t = Get-ScheduledTask -TaskName $LaunchTaskName -ErrorAction SilentlyContinue
    if ($t) {
        Unregister-ScheduledTask -TaskName $LaunchTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Stop-WatchdogTask {
    <#
        Stops (if running) and removes the script's watchdog task. Used to clear a
        stale one before the run and to return the machine to baseline after it.
    #>
    $t = Get-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue
    if (-not $t) { return }
    if ($t.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue
    }
    Unregister-ScheduledTask -TaskName $WatchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Start-TargetAsUser {
    <#
        Starts $Path with the signed-in user's Limited token via a one-shot
        Interactive task, then waits for a NEW process matching $FileDescription that
        owns a window. The Store Notepad stub matches too but exits at once, so a
        windowless match is only accepted when nothing better has appeared by the
        deadline. Returns the Process object; output-clean apart from that.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$FileDescription,
        [int[]]$ExcludePids = @()
    )

    $before  = @(Get-MatchingProcess -FileDescription $FileDescription | ForEach-Object { $_.Id })
    $exclude = @($ExcludePids) + $before

    Remove-LaunchTask

    $user = Get-LoggedOnUser
    if ($user) {
        $action    = New-ScheduledTaskAction -Execute $Path
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $LaunchTaskName -Action $action -Principal $principal `
            -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $LaunchTaskName -ErrorAction Stop
        Write-Host "           - started '$Path' as '$user' (Interactive, Limited) via task '$LaunchTaskName'" -ForegroundColor Gray
    } else {
        Write-Host "           - no interactive user reported by Win32_ComputerSystem; starting '$Path' directly (elevated -- the Limited watchdog may not be able to close it)" -ForegroundColor DarkYellow
        Start-Process -FilePath $Path -ErrorAction Stop | Out-Null
    }

    $chosen   = $null
    $deadline = (Get-Date).AddSeconds($LaunchWaitSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $fresh    = @(Get-MatchingProcess -FileDescription $FileDescription | Where-Object { $exclude -notcontains $_.Id })
        $windowed = @($fresh | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
        if ($windowed.Count -gt 0) { $chosen = $windowed[0]; break }
    }

    if (-not $chosen) {
        $fresh = @(Get-MatchingProcess -FileDescription $FileDescription | Where-Object { $exclude -notcontains $_.Id -and -not $_.HasExited })
        if ($fresh.Count -gt 0) {
            $chosen = $fresh[0]
            Write-Host "           - PID $($chosen.Id) is running but owns no window after ${LaunchWaitSec}s; the watchdog will have to use taskkill (no /F), which a windowless process may ignore" -ForegroundColor DarkYellow
        }
    }

    # The launched process does not depend on the task (verified: it survives
    # Unregister), so the task goes now rather than lingering until Restore.
    Remove-LaunchTask

    if (-not $chosen) {
        throw "'$Path' did not produce a running process matching '*$FileDescription*' within ${LaunchWaitSec}s."
    }

    # Give the window a moment to finish initialising before anyone signals it.
    Start-Sleep -Seconds 2
    return $chosen
}

function Stop-TestLaunchedProcess {
    <#
        Kills every process matching the chosen FileDescription EXCEPT the PIDs that
        were already running when Capture ran. That covers what Apply launched and
        what the watchdog relaunched, and nothing else.
    #>
    param($Original)

    if (-not $Original.FileDescription) { return }
    $protect = @($Original.PreExistingPids)
    $victims = @(Get-MatchingProcess -FileDescription $Original.FileDescription | Where-Object { $protect -notcontains $_.Id })
    foreach ($v in $victims) {
        try {
            Stop-Process -Id $v.Id -Force -ErrorAction Stop
            Write-DexStep -Status 'Info' -Name 'Restore' -Message "stopped test-launched PID $($v.Id) ($($v.Name))"
        } catch {
            # Already gone (raced the watchdog) is fine; still alive is a real failure.
            if (Get-Process -Id $v.Id -ErrorAction SilentlyContinue) { throw $_ }
        }
    }
    foreach ($v in $victims) {
        try { $v.WaitForExit(5000) | Out-Null } catch { }
    }
}

function Get-DexRecordValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { return $null }
    (Get-ItemProperty -LiteralPath $DexRecordsPath -Name $Name -ErrorAction SilentlyContinue).$Name
}

function Get-RemediationRecord {
    # The remediation phase stores ExitCode/Output on the run state; Validate reads
    # them from here rather than re-running anything.
    return $script:state.Remediation
}

function Wait-WatchdogResult {
    <#
        Polls for the watchdog's result.json (removed by the fixture before the run,
        so any file present was written by this dispatch). Returns the parsed object
        or $null on timeout.
    #>
    param([int]$TimeoutSec)

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $WatchdogResultFile) {
            try {
                $r = Get-Content -LiteralPath $WatchdogResultFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($r -and $r.CompletedAt) { return $r }
            } catch { }
        }
        Start-Sleep -Seconds 1
    }
    return $null
}

function Write-WatchdogLogTail {
    param([int]$Lines = 20)
    if (Test-Path -LiteralPath $WatchdogLogFile) {
        Write-Host "           - last $Lines line(s) of ${WatchdogLogFile}:" -ForegroundColor Gray
        Get-Content -LiteralPath $WatchdogLogFile -Tail $Lines -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host "               $_" -ForegroundColor DarkGray }
    } else {
        Write-Host "           - no watchdog log at $WatchdogLogFile" -ForegroundColor Gray
    }
}

function Test-GracefulOutcome {
    <#
        Validate for the running-process breaks. Checks, in order: the launcher's
        exit code and console output, its DEXRecords, the watchdog's result.json
        (waited for), and finally the process table -- the original PID must be gone
        and a newer instance must (Restart) or must not (no Restart) exist.
        Returns a single [bool]; diagnostics go to the host, never the pipeline.
    #>
    param(
        [Parameter(Mandatory = $true)]$Original,
        [Parameter(Mandatory = $true)][bool]$ExpectRestart
    )

    $ok   = $true
    $desc = [string]$Original.FileDescription
    $pid0 = [int]$Original.LaunchedPid

    $rem = Get-RemediationRecord
    if ($null -eq $rem) { Write-Host '           - no remediation record on the run state' -ForegroundColor Red; return $false }

    if ([int]$rem.ExitCode -ne 0) {
        Write-Host "           - launcher exit code $($rem.ExitCode); documented dispatch exit code is 0" -ForegroundColor Red; $ok = $false
    }
    $out = [string]$rem.Output
    if ($out -notmatch "PID\s+$pid0\s") {
        Write-Host "           - launcher output does not list the target PID $pid0" -ForegroundColor Red; $ok = $false
    }
    if ($out -notmatch "Watchdog dispatched as scheduled task '$([regex]::Escape($WatchdogTaskName))'") {
        Write-Host "           - launcher output does not report the watchdog dispatch" -ForegroundColor Red; $ok = $false
    }

    # Launcher writes Status=Dispatched, MatchedCount, TargetDescription. The watchdog
    # later mirrors Status=Completed to the same key on a best-effort basis (it only
    # succeeds when the user's token can write HKLM), so either value is documented.
    $regStatus = [string](Get-DexRecordValue -Name 'Status')
    $regDesc   = [string](Get-DexRecordValue -Name 'TargetDescription')
    $regCount  = Get-DexRecordValue -Name 'MatchedCount'
    if ($regStatus -notin @('Dispatched', 'Completed')) {
        Write-Host "           - DEXRecords Status is '$regStatus'; expected 'Dispatched' (or 'Completed' once the watchdog mirrors it)" -ForegroundColor Red; $ok = $false
    }
    if ($regDesc -ne $desc) {
        Write-Host "           - DEXRecords TargetDescription is '$regDesc'; expected '$desc'" -ForegroundColor Red; $ok = $false
    }
    if ($null -eq $regCount -or [int]$regCount -lt 1) {
        Write-Host "           - DEXRecords MatchedCount is '$regCount'; expected >= 1" -ForegroundColor Red; $ok = $false
    }
    Write-Host "           - DEXRecords: Status=$regStatus MatchedCount=$regCount TargetDescription='$regDesc'" -ForegroundColor Gray

    Write-Host "           - waiting up to ${WatchdogWaitSec}s for $WatchdogResultFile" -ForegroundColor Gray
    $result = Wait-WatchdogResult -TimeoutSec $WatchdogWaitSec
    if ($null -eq $result) {
        Write-Host "           - watchdog never wrote result.json within ${WatchdogWaitSec}s" -ForegroundColor Red
        Write-WatchdogLogTail
        return $false
    }

    Write-Host ("           - result.json: Status={0} Context={1} Matched={2} Graceful={3} Forced={4} UserAction={5} Unsaved={6} Error={7} Restarted={8}" -f `
        $result.Status, $result.WatchdogContext, $result.MatchedCount, $result.ClosedGracefullyCount, $result.ForceKilledCount,
        $result.UserActionRequiredCount, $result.UnsavedWorkSuspectedCount, $result.ErrorCount, $result.Restarted) -ForegroundColor Gray

    if ($result.Status -ne 'Completed') {
        Write-Host "           - result.json Status is '$($result.Status)'; expected 'Completed'" -ForegroundColor Red; $ok = $false
    }
    if ($result.TargetDescription -ne $desc) {
        Write-Host "           - result.json TargetDescription is '$($result.TargetDescription)'; expected '$desc'" -ForegroundColor Red; $ok = $false
    }
    if ([int]$result.MatchedCount -lt 1) {
        Write-Host "           - result.json MatchedCount is $($result.MatchedCount); expected >= 1" -ForegroundColor Red; $ok = $false
    }
    $entry = @($result.Processes | Where-Object { [int]$_.Id -eq $pid0 })
    if ($entry.Count -ne 1) {
        Write-Host "           - result.json has no entry for the target PID $pid0" -ForegroundColor Red; $ok = $false
    } elseif ($entry[0].Outcome -ne 'ClosedGracefully') {
        Write-Host "           - PID $pid0 outcome is '$($entry[0].Outcome)' ($($entry[0].Detail)); expected 'ClosedGracefully'" -ForegroundColor Red; $ok = $false
    }
    if ([int]$result.ForceKilledCount -ne 0) {
        Write-Host "           - ForceKilledCount is $($result.ForceKilledCount); a responding process must never be force-killed" -ForegroundColor Red; $ok = $false
    }
    if ([int]$result.UserActionRequiredCount -ne 0) {
        Write-Host "           - UserActionRequiredCount is $($result.UserActionRequiredCount); the graceful close did not land" -ForegroundColor Red; $ok = $false
    }
    if ([int]$result.ErrorCount -ne 0) {
        Write-Host "           - ErrorCount is $($result.ErrorCount)" -ForegroundColor Red; $ok = $false
    }
    if ([bool]$result.Restarted -ne $ExpectRestart) {
        Write-Host "           - result.json Restarted=$($result.Restarted); expected $ExpectRestart" -ForegroundColor Red; $ok = $false
    }

    # Process table: the original instance must be gone (StartTime guards PID reuse).
    $orig = Get-Process -Id $pid0 -ErrorAction SilentlyContinue
    if ($orig) {
        $sameStart = $false
        try { $sameStart = ($orig.StartTime.ToString('o') -eq [string]$Original.LaunchedStartTime) } catch { }
        if ($sameStart) {
            Write-Host "           - original PID $pid0 is still running" -ForegroundColor Red; $ok = $false
        }
    } else {
        Write-Host "           - original PID $pid0 is gone" -ForegroundColor Gray
    }

    $launchedAt = [datetime]::Parse([string]$Original.LaunchedStartTime)
    $protect    = @($Original.PreExistingPids)
    $newerFilter = {
        $protect -notcontains $_.Id -and $_.Id -ne $pid0 -and $_.StartTime -gt $launchedAt
    }

    if ($ExpectRestart) {
        $newer    = @()
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            $newer = @(Get-MatchingProcess -FileDescription $desc | Where-Object $newerFilter)
            if ($newer.Count -gt 0) { break }
            Start-Sleep -Seconds 1
        }
        if ($newer.Count -gt 0) {
            Write-Host "           - relaunched: PID $($newer[0].Id) ($($newer[0].Name)) started $($newer[0].StartTime.ToString('HH:mm:ss.fff')), after the original's $($launchedAt.ToString('HH:mm:ss.fff'))" -ForegroundColor Gray
        } else {
            Write-Host "           - no process matching '*$desc*' with a StartTime newer than the original exists; Restart did not happen" -ForegroundColor Red; $ok = $false
        }
    } else {
        $newer    = @()
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline) {
            $newer = @(Get-MatchingProcess -FileDescription $desc | Where-Object { $protect -notcontains $_.Id })
            if ($newer.Count -eq 0) { break }
            Start-Sleep -Seconds 1
        }
        if ($newer.Count -gt 0) {
            Write-Host "           - $($newer.Count) process(es) matching '*$desc*' still running (PID $($newer.Id -join ', ')); expected none with Restart=false" -ForegroundColor Red; $ok = $false
        } else {
            Write-Host "           - nothing matching '*$desc*' was relaunched" -ForegroundColor Gray
        }
    }

    if (-not $ok) { Write-WatchdogLogTail }
    return $ok
}

function Test-NoMatchOutcome {
    <#
        Validate for the not-running break. The launcher must say so, record
        Status=NoMatch / MatchedCount=0, exit 0, and dispatch nothing: no watchdog
        task, no result.json. Returns a single [bool].
    #>
    param([Parameter(Mandatory = $true)]$Original)

    $ok   = $true
    $desc = [string]$Original.FileDescription

    $rem = Get-RemediationRecord
    if ($null -eq $rem) { Write-Host '           - no remediation record on the run state' -ForegroundColor Red; return $false }

    if ([int]$rem.ExitCode -ne 0) {
        Write-Host "           - launcher exit code $($rem.ExitCode); documented no-match exit code is 0" -ForegroundColor Red; $ok = $false
    }
    $out = [string]$rem.Output
    $expectedLine = "No running process matches description '*$desc*'"
    if ($out -notmatch [regex]::Escape($expectedLine)) {
        Write-Host "           - launcher output lacks `"$expectedLine`"" -ForegroundColor Red; $ok = $false
    }
    if ($out -match 'Watchdog dispatched as scheduled task') {
        Write-Host '           - launcher dispatched a watchdog with nothing to close' -ForegroundColor Red; $ok = $false
    }

    $regStatus = [string](Get-DexRecordValue -Name 'Status')
    $regDesc   = [string](Get-DexRecordValue -Name 'TargetDescription')
    $regCount  = Get-DexRecordValue -Name 'MatchedCount'
    Write-Host "           - DEXRecords: Status=$regStatus MatchedCount=$regCount TargetDescription='$regDesc'" -ForegroundColor Gray
    if ($regStatus -ne 'NoMatch') {
        Write-Host "           - DEXRecords Status is '$regStatus'; expected 'NoMatch'" -ForegroundColor Red; $ok = $false
    }
    if ($regDesc -ne $desc) {
        Write-Host "           - DEXRecords TargetDescription is '$regDesc'; expected '$desc'" -ForegroundColor Red; $ok = $false
    }
    if ($null -eq $regCount -or [int]$regCount -ne 0) {
        Write-Host "           - DEXRecords MatchedCount is '$regCount'; expected 0" -ForegroundColor Red; $ok = $false
    }

    if (Test-Path -LiteralPath $WatchdogResultFile) {
        Write-Host "           - $WatchdogResultFile exists; a no-match run must not reach the watchdog" -ForegroundColor Red; $ok = $false
    }
    if (Get-ScheduledTask -TaskName $WatchdogTaskName -ErrorAction SilentlyContinue) {
        Write-Host "           - scheduled task '$WatchdogTaskName' exists; a no-match run must not register it" -ForegroundColor Red; $ok = $false
    }

    return $ok
}

function Set-TargetEnvironment {
    # The script reads its inputs from the environment; the child powershell.exe
    # inherits this process's block, which is exactly how Hub delivers them.
    param([Parameter(Mandatory = $true)][hashtable]$Variables)
    foreach ($k in $Variables.Keys) {
        Set-Item -Path "Env:\$k" -Value ([string]$Variables[$k])
    }
}

function Clear-TargetEnvironment {
    param([Parameter(Mandatory = $true)][hashtable]$Variables)
    foreach ($k in $Variables.Keys) {
        Remove-Item -Path "Env:\$k" -ErrorAction SilentlyContinue
    }
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Apply receives the captured hashtable and fills
# in what it launched (the PID is only known after the fact, and Restore/Validate
# need it to survive in state.json). Verify proves the break landed. Validate
# decides whether remediation did its job. Variables are merged over
# $TargetVariables for the remediation run.
$BreakCatalog = @(

    @{
        Name            = 'ProcessRunningRestart'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Variables       = @{ Restart = 'true' }
        Methods         = @(
            @{
                # Script branch: N process(es) matched -> watchdog dispatched -> ClosedGracefully -> Restarted.
                Name  = 'LaunchAsUser'
                Apply = {
                    param([hashtable]$Original)
                    $launched = $null
                    foreach ($c in @($Original.Candidates | Where-Object { -not $_.Skipped })) {
                        try {
                            $launched = Start-TargetAsUser -Path $c.Path -FileDescription $c.FileDescription -ExcludePids @($c.PreExistingPids)
                        } catch {
                            Write-DexStep -Status 'Warning' -Name 'Launch' -Message "$($c.Name): $($_.Exception.Message)"
                            continue
                        }
                        $Original.CandidateName     = $c.Name
                        $Original.ExePath           = $c.Path
                        $Original.FileDescription   = $c.FileDescription
                        $Original.PreExistingPids   = @($c.PreExistingPids)
                        $Original.LaunchedPid       = $launched.Id
                        $Original.LaunchedName      = $launched.Name
                        $Original.LaunchedPath      = [string]$launched.Path
                        $Original.LaunchedStartTime = $launched.StartTime.ToString('o')
                        break
                    }
                    if (-not $launched) { throw 'No candidate target could be started as the signed-in user.' }
                    Write-DexStep -Status 'Info' -Name 'Launch' -Message "PID $($launched.Id) ($($launched.Name)) '$($launched.Description)' window=$($launched.MainWindowHandle -ne [IntPtr]::Zero)"
                }
            }
        )
        Capture  = { Get-TargetBaseline }
        Verify   = {
            param($Original)
            if (-not $Original.LaunchedPid) { Write-Host '           - nothing was launched' -ForegroundColor Red; return $false }
            $p = Get-Process -Id ([int]$Original.LaunchedPid) -ErrorAction SilentlyContinue
            if (-not $p) { Write-Host "           - launched PID $($Original.LaunchedPid) is not running" -ForegroundColor Red; return $false }
            $all     = @(Get-MatchingProcess -FileDescription $Original.FileDescription)
            $foreign = @($all | Where-Object { @($Original.PreExistingPids) -contains $_.Id })
            Write-Host "           - PID $($p.Id) '$($p.Description)' running; $($all.Count) process(es) match '*$($Original.FileDescription)*', $($foreign.Count) pre-existing" -ForegroundColor Gray
            ($p.Description -like "*$($Original.FileDescription)*") -and ($all.Count -ge 1) -and ($foreign.Count -eq 0)
        }
        Validate = {
            param($Original)
            Test-GracefulOutcome -Original $Original -ExpectRestart $true
        }
        Restore  = {
            param($Original)
            Stop-WatchdogTask
            Stop-TestLaunchedProcess -Original $Original
            Remove-LaunchTask
        }
    },

    @{
        Name            = 'ProcessRunningNoRestart'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Variables       = @{ Restart = 'false' }
        Methods         = @(
            @{
                # Script branch: N process(es) matched -> watchdog dispatched -> ClosedGracefully, no relaunch.
                Name  = 'LaunchAsUser'
                Apply = {
                    param([hashtable]$Original)
                    $launched = $null
                    foreach ($c in @($Original.Candidates | Where-Object { -not $_.Skipped })) {
                        try {
                            $launched = Start-TargetAsUser -Path $c.Path -FileDescription $c.FileDescription -ExcludePids @($c.PreExistingPids)
                        } catch {
                            Write-DexStep -Status 'Warning' -Name 'Launch' -Message "$($c.Name): $($_.Exception.Message)"
                            continue
                        }
                        $Original.CandidateName     = $c.Name
                        $Original.ExePath           = $c.Path
                        $Original.FileDescription   = $c.FileDescription
                        $Original.PreExistingPids   = @($c.PreExistingPids)
                        $Original.LaunchedPid       = $launched.Id
                        $Original.LaunchedName      = $launched.Name
                        $Original.LaunchedPath      = [string]$launched.Path
                        $Original.LaunchedStartTime = $launched.StartTime.ToString('o')
                        break
                    }
                    if (-not $launched) { throw 'No candidate target could be started as the signed-in user.' }
                    Write-DexStep -Status 'Info' -Name 'Launch' -Message "PID $($launched.Id) ($($launched.Name)) '$($launched.Description)' window=$($launched.MainWindowHandle -ne [IntPtr]::Zero)"
                }
            }
        )
        Capture  = { Get-TargetBaseline }
        Verify   = {
            param($Original)
            if (-not $Original.LaunchedPid) { Write-Host '           - nothing was launched' -ForegroundColor Red; return $false }
            $p = Get-Process -Id ([int]$Original.LaunchedPid) -ErrorAction SilentlyContinue
            if (-not $p) { Write-Host "           - launched PID $($Original.LaunchedPid) is not running" -ForegroundColor Red; return $false }
            $all     = @(Get-MatchingProcess -FileDescription $Original.FileDescription)
            $foreign = @($all | Where-Object { @($Original.PreExistingPids) -contains $_.Id })
            Write-Host "           - PID $($p.Id) '$($p.Description)' running; $($all.Count) process(es) match '*$($Original.FileDescription)*', $($foreign.Count) pre-existing" -ForegroundColor Gray
            ($p.Description -like "*$($Original.FileDescription)*") -and ($all.Count -ge 1) -and ($foreign.Count -eq 0)
        }
        Validate = {
            param($Original)
            Test-GracefulOutcome -Original $Original -ExpectRestart $false
        }
        Restore  = {
            param($Original)
            Stop-WatchdogTask
            Stop-TestLaunchedProcess -Original $Original
            Remove-LaunchTask
        }
    },

    @{
        Name            = 'ProcessNotRunning'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Variables       = @{ Restart = 'true' }
        Methods         = @(
            @{
                # Script branch: "No running process matches description '*X*'. Nothing to do." -> Status NoMatch, exit 0.
                # The 'break' is the absence of the target; nothing is started and nothing is touched.
                Name  = 'NothingToLaunch'
                Apply = {
                    param([hashtable]$Original)
                    Write-DexStep -Status 'Info' -Name 'Launch' -Message "nothing started; '*$($Original.FileDescription)*' has no live match"
                }
            }
        )
        Capture  = { Get-NoMatchBaseline }
        Verify   = {
            param($Original)
            $all = @(Get-MatchingProcess -FileDescription $Original.FileDescription)
            Write-Host "           - $($all.Count) process(es) match '*$($Original.FileDescription)*'" -ForegroundColor Gray
            $all.Count -eq 0
        }
        Validate = {
            param($Original)
            Test-NoMatchOutcome -Original $Original
        }
        Restore  = {
            param($Original)
            # Nothing was launched, so no process is touched. Only the harness's and
            # the script's scheduled tasks are cleared, should either exist.
            Stop-WatchdogTask
            Remove-LaunchTask
        }
    }
)

function Get-BreakDefinition {
    param([Parameter(Mandatory = $true)][string]$Name)
    $BreakCatalog | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Request-TestReboot {
    param([Parameter(Mandatory = $true)][hashtable]$State)

    Save-DexTestState -State $State
    Register-DexTestResume -State $State -BreakTestPath $SelfPath
    Write-DexStep -Status 'Info' -Name 'Reboot' -Message 'Rebooting to apply pending state; run resumes automatically.'
    & shutdown.exe /r /t 15 /f | Out-Null
}

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList

Write-DexBanner -Title "Restart-WinProcessGraceful_BreakTest" -Detail "Environment: $Environment"

# -- Restore-only mode ---------------------------------------------------------
if ($Restore) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    foreach ($b in $state.Breaks) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
            Write-DexStep -Status 'Passed' -Name "Restore $($b.Name)"
        } catch {
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }
    Remove-Fixture
    Unregister-DexTestResume -State $state
    $state.Phase   = 'Restored'
    $state.Overall = 'Restored'
    Write-DexTestResult -State $state | Out-Null
    Clear-DexTestState -State $state
    exit 0
}

# -- Acquire context -----------------------------------------------------------
if ($Resume) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    if (Test-DexRebootOccurred -State $state) {
        $state.RebootCount = [int]$state.RebootCount + 1
        Write-DexStep -Status 'Info' -Name 'Resume' -Message "Reboot #$($state.RebootCount) confirmed; resuming at phase '$($state.Phase)'."
    } else {
        Write-DexStep -Status 'Warning' -Name 'Resume' -Message 'No reboot detected since the run started.'
    }
    # RemediationTest cannot survive as a switch across the reboot, so it is
    # recovered from the state that was persisted before the machine went down.
    $RemediationTest = [bool]$state.RemediationTest
} else {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Seed $Seed -Environment $Environment
    $state.RemediationTest = [bool]$RemediationTest
    Write-DexStep -Status 'Info' -Name 'Context' -Message "TestId $($state.TestId)  Seed $($state.Seed)"
}

$exitCode = 0

try {
    # -- Phase: apply breaks ---------------------------------------------------
    if ($state.Phase -eq 'Init') {

        Initialize-Fixture

        $candidates = if ($BreakName) {
            @($BreakCatalog | Where-Object { $BreakName -contains $_.Name })
        } else {
            @($BreakCatalog | Where-Object { $IncludeRebootBreaks -or -not $_.RequiresReboot })
        }

        if ($candidates.Count -eq 0) { throw 'No break definitions matched the requested selection.' }

        $selected = if ($BreakName) {
            $candidates
        } else {
            Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount
        }

        # One remediation run, one set of environment variables: every break here needs
        # its own Restart value or its own process state, so they cannot share a run.
        # Keep whichever the seeded shuffle drew first; force one with -BreakName.
        if (@($selected).Count -gt 1) {
            $keep     = @($selected)[0].Name
            $selected = @($selected | Where-Object { $_.Name -eq $keep })
            Write-DexStep -Status 'Info' -Name 'Selection' -Message "breaks are mutually exclusive (one remediation run); kept '$keep'"
        }

        $applied = @()
        foreach ($def in $selected) {
            $method = (Get-DexRandomSubset -InputObject $def.Methods -Random $state.Random -Count 1)[0]

            Write-DexStep -Status 'Info' -Name "Capture $($def.Name)" -Message 'selecting a target the user is not using'
            $original = & $def.Capture
            # Apply gets the captured hashtable so it can record what it launched.
            & $method.Apply $original

            if ($def.RequiresReboot) { $state.RequiresReboot = $true }

            $applied += @{
                Name            = $def.Name
                Method          = $method.Name
                ExpectedOutcome = $def.ExpectedOutcome
                RequiresReboot  = [bool]$def.RequiresReboot
                Applied         = $true
                BreakVerified   = $false
                OriginalState   = $original
            }
            Write-DexStep -Status 'Info' -Name "Break $($def.Name)" -Message "method '$($method.Name)' applied (target '$($original.FileDescription)')"
            # Commit at once so Restore can undo this break even if a later Capture/Apply throws.
            $state.Breaks = $applied
            Save-DexTestState -State $state
        }

        $state.Breaks = $applied
        $state.Phase  = 'Broken'
        Save-DexTestState -State $state

        if ($state.RequiresReboot) {
            Request-TestReboot -State $state
            exit 0
        }
    }

    # -- Phase: verify the break -----------------------------------------------
    if ($state.Phase -eq 'Broken') {

        $allVerified = $true
        foreach ($b in $state.Breaks) {
            $def = Get-BreakDefinition -Name $b.Name
            $ok  = [bool](& $def.Verify ([PSCustomObject]$b.OriginalState))
            $b.BreakVerified = $ok
            if ($ok) {
                Write-DexStep -Status 'Passed' -Name "Verify $($b.Name)" -Message 'precondition is genuinely in place'
            } else {
                $allVerified = $false
                Write-DexStep -Status 'Failed' -Name "Verify $($b.Name)" -Message 'break did not land; remediation would be a false green'
            }
        }

        if (-not $allVerified) {
            $state.Phase   = 'BreakFailed'
            $state.Overall = 'BreakFailed'
            Save-DexTestState -State $state
            throw 'One or more breaks could not be verified; refusing to run remediation.'
        }

        $state.Phase = 'BreakVerified'
        Save-DexTestState -State $state
    }

    # -- Phase: remediate ------------------------------------------------------
    if ($state.Phase -eq 'BreakVerified') {

        if (-not $RemediationTest) {
            $state.Overall = 'BreakOnly'
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message 'skipped (-RemediationTest not supplied)'
        } else {
            # Build the script's inputs from the (single) selected break and hand them
            # over as environment variables, the way Hub does.
            $lead      = @($state.Breaks)[0]
            $leadDef   = Get-BreakDefinition -Name $lead.Name
            $variables = @{}
            foreach ($k in $TargetVariables.Keys)   { $variables[$k] = $TargetVariables[$k] }
            foreach ($k in $leadDef.Variables.Keys) { $variables[$k] = $leadDef.Variables[$k] }
            $variables['FileDescription'] = [string]([PSCustomObject]$lead.OriginalState).FileDescription

            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "invoking $([System.IO.Path]::GetFileName($RemediationScript))"
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message ("env: " + (($variables.Keys | Sort-Object | ForEach-Object { "$_=$($variables[$_])" }) -join ' '))

            Set-TargetEnvironment -Variables $variables
            try {
                $sw     = [System.Diagnostics.Stopwatch]::StartNew()
                $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1
                $rc     = $LASTEXITCODE
                $sw.Stop()
            } finally {
                Clear-TargetEnvironment -Variables $variables
            }

            $state.Remediation = @{
                ExitCode    = $rc
                DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                Output      = ($output | Out-String).Trim()
                Variables   = $variables
            }
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "exit $rc after $($state.Remediation.DurationSec)s"
            $state.Phase = 'Remediated'
            Save-DexTestState -State $state

            if ($state.RequiresReboot) {
                Request-TestReboot -State $state
                exit 0
            }
        }
    }

    # -- Phase: validate -------------------------------------------------------
    if ($state.Phase -eq 'Remediated') {

        $validation = @()
        foreach ($b in $state.Breaks) {
            $def    = Get-BreakDefinition -Name $b.Name
            $passed = [bool](& $def.Validate ([PSCustomObject]$b.OriginalState))

            $expected = if ($b.ExpectedOutcome -eq 'ExpectFixed') {
                'target closed gracefully by the watchdog, relaunch state as configured'
            } else {
                'no match reported, nothing dispatched, nothing touched'
            }

            $validation += @{
                Name     = $b.Name
                Expected = $expected
                Actual   = if ($passed) { 'as expected' } else { 'NOT as expected' }
                Result   = if ($passed) { 'Pass' } else { 'Fail' }
            }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) `
                          -Name "Validate $($b.Name)" -Message $expected
        }

        $state.Validation = $validation
        $state.Phase      = 'Validated'

        $failedCount = @($validation | Where-Object { $_.Result -eq 'Fail' }).Count
        $state.Overall = if ($failedCount -eq 0) {
            'Passed'
        } elseif ($state.Remediation -and [int]$state.Remediation.ExitCode -eq 0) {
            # Dispatch claimed success while the watchdog outcome or process table says otherwise.
            'FalsePass'
        } else {
            'Failed'
        }

        Save-DexTestState -State $state
    }

} catch {
    Write-DexStep -Status 'Failed' -Name 'Harness' -Message $_.Exception.Message
    $state.HarnessError = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    if ($state.Overall -eq 'Incomplete') { $state.Overall = 'Failed' }
    $exitCode = 1
}

# -- Restore -------------------------------------------------------------------
# Snapshot environments revert on the host, so restoring here would only add risk.
if ($Environment -eq 'Physical') {
    $restoreFailed = $false
    # Restore newest-first. A later break's Capture can record state an earlier break had
    # already changed; undoing in reverse order lets the oldest capture, the true baseline, win.
    $toRestore = @($state.Breaks); [array]::Reverse($toRestore)
    foreach ($b in $toRestore) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
        } catch {
            $restoreFailed = $true
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }
    try { Remove-Fixture } catch { $restoreFailed = $true }

    if ($restoreFailed) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'machine left modified -- manual cleanup required'
    } else {
        $state.Phase = 'Restored'
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'test-launched processes stopped; machine returned to baseline'
    }
}

Unregister-DexTestResume -State $state

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) `
              -Name 'Overall' -Message $state.Overall

Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state

exit $exitCode
