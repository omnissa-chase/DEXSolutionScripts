<#
.SYNOPSIS
    Gracefully close (and optionally restart) a Windows process matched by
    FileDescription, escalating to a force-kill only if the process does not
    exit within the configurable timeout or stops responding.

.DESCRIPTION
    Unlike Restart-WinProcess.ps1 which immediately force-kills, this script
    attempts a clean shutdown first. The sequence for each matched process is:

      1. Send a graceful close signal.
           - GUI apps with an accessible main window: CloseMainWindow (WM_CLOSE).
           - Windowless / console apps, or when CloseMainWindow is blocked
             (e.g. running as SYSTEM targeting a user-session process):
             taskkill /PID <id> without /F, which delivers CTRL_CLOSE_EVENT
             or WM_CLOSE via the kernel and works across session boundaries.
      2. Poll for exit every 500 ms up to GracefulTimeoutSec.
             If the process stops responding (Responding = false) at any point
             during the wait, escalate immediately rather than waiting for the
             full timeout.
      3. If the process has still not exited: force-kill with Stop-Process -Force.

    All matching instances are stopped. If Restart is true and an exe path was
    captured before stopping, one new instance is launched after all have closed.

    NOTE: When running as SYSTEM (MDM remediation context), cross-session
    window message delivery (WM_CLOSE) may be blocked by UIPI for processes
    running in a user session. In that case the taskkill fallback is used, which
    has broader cross-session reach. If that also fails, the process will be
    force-killed after GracefulTimeoutSec seconds.

.PARAMETER FileDescription
    Substring matched (case-insensitive wildcard) against each process's
    Description field (the FileDescription from the binary's version info).
    Examples: 'Microsoft Teams', 'Zoom', 'Google Chrome'
    Accepts env var: $env:FileDescription. Required.

.PARAMETER GracefulTimeoutSec
    Maximum seconds to wait for a graceful exit before force-killing.
    The not-responding early-escalation path ignores this timeout.
    Accepts env var: $env:GracefulTimeoutSec. Default: 15.

.PARAMETER Restart
    When true, re-launches one instance after all matching processes have
    stopped, using the executable path captured from the first matched process.
    Note: the captured path may be inaccessible from SYSTEM context if the
    process runs from a user profile or protected directory; restart will be
    skipped with a warning in that case.
    Accepts env var: $env:Restart. Default: false.

.NOTES
    Script Name  : Restart-WinProcessGraceful.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System (see UIPI note in .DESCRIPTION)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-28
    Timeout      : GracefulTimeoutSec x matched-process-count + ~10 s overhead

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

param(
    [string]$FileDescription    = $(if ($env:FileDescription)    { $env:FileDescription }                          else { '' }),
    [int]   $GracefulTimeoutSec = $(if ($env:GracefulTimeoutSec) { [int]$env:GracefulTimeoutSec }                  else { 15 }),
    [bool]  $Restart            = $(if ($env:Restart)            { [System.Convert]::ToBoolean($env:Restart) }     else { $false })
)

if ([string]::IsNullOrEmpty($FileDescription)) {
    Write-Error 'FileDescription is required. Pass it as a parameter or set $env:FileDescription.'
    exit 1
}

# -- Discover matching processes -----------------------------------------------
$procs = @(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Description -like "*$FileDescription*" })

if ($procs.Count -eq 0) {
    Write-Host "No running process found matching description '*$FileDescription*'. Nothing to do."
    exit 0
}

Write-Host "$($procs.Count) process(es) found matching '$FileDescription':"
foreach ($p in $procs) {
    Write-Host "  PID $($p.Id.ToString().PadLeft(5))  $($p.Name.PadRight(20))  $($p.Description)"
}
Write-Host ''

$restartPath      = $null
$gracefulCount    = 0
$forceKilledCount = 0
$errorCount       = 0

foreach ($proc in $procs) {

    Write-Host "[$($proc.Name) / PID $($proc.Id)]"

    # Capture exe path before stopping -- needed for optional restart
    if (-not $restartPath) {
        try { $restartPath = $proc.Path } catch { }
    }

    # -- Step 1: Graceful close signal -----------------------------------------

    $gracefulSent = $false

    # For GUI apps: CloseMainWindow sends WM_CLOSE to the main window handle.
    # Returns $false (and $gracefulSent stays $false) when the process has no
    # accessible main window -- common when running as SYSTEM vs. a user session.
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
        try {
            $gracefulSent = $proc.CloseMainWindow()
            if ($gracefulSent) { Write-Host '  Graceful signal sent (CloseMainWindow / WM_CLOSE).' }
        } catch { }
    }

    # Fallback: taskkill without /F delivers CTRL_CLOSE_EVENT (console) or
    # WM_CLOSE (GUI) via the kernel. This has broader reach from SYSTEM context
    # and works for windowless processes that CloseMainWindow cannot target.
    if (-not $gracefulSent) {
        Write-Host '  No accessible main window -- sending graceful signal via taskkill (no /F)...'
        $null = & taskkill /PID $proc.Id 2>&1
        $gracefulSent = $true
    }

    # -- Step 2: Wait for exit, escalate if not responding --------------------

    $deadline      = [DateTime]::UtcNow.AddSeconds($GracefulTimeoutSec)
    $notResponding = $false
    $exited        = $false

    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        try {
            $proc.Refresh()
            if ($proc.HasExited) { $exited = $true; break }

            # Escalate immediately if the process has hung (stopped processing messages).
            # Only meaningful for windowed processes; headless processes always report Responding=$true.
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero -and -not $proc.Responding) {
                $notResponding = $true
                Write-Host '  Process stopped responding. Escalating to force-kill.'
                break
            }
        } catch {
            # Process object invalidated -- treat as exited
            $exited = $true
            break
        }
    }

    # Refresh one final time in case the loop ended on timeout
    if (-not $exited) {
        try { $proc.Refresh(); $exited = $proc.HasExited } catch { $exited = $true }
    }

    # -- Step 3: Evaluate and force-kill if needed ----------------------------

    if ($exited) {
        Write-Host "  [OK]  Closed gracefully."
        $gracefulCount++
    } else {
        $reason = if ($notResponding) { 'not responding' } else { "timeout (${GracefulTimeoutSec}s) exceeded" }
        Write-Host "  [!!]  Did not close gracefully ($reason) -- force-killing..."
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            # Brief wait so downstream logic (restart) doesn't race the OS cleanup
            try { $proc.WaitForExit(5000) | Out-Null } catch { }
            Write-Host "  [OK]  Force-killed."
            $forceKilledCount++
        } catch {
            Write-Host "  [ERR] Force-kill failed: $($_.Exception.Message)"
            $errorCount++
        }
    }

    Write-Host ''
}

# -- Summary -------------------------------------------------------------------
Write-Host "Summary: $gracefulCount graceful, $forceKilledCount force-killed, $errorCount error(s)."

# -- Optional restart ----------------------------------------------------------
if ($Restart) {
    if ($restartPath) {
        Write-Host "Restarting: $restartPath"
        Start-Sleep -Seconds 2
        try {
            Start-Process -FilePath $restartPath -ErrorAction Stop
            Write-Host 'Process restarted.'
        } catch {
            Write-Host "[ERR] Restart failed: $($_.Exception.Message)"
            exit 1
        }
    } else {
        Write-Host '[WARN] Restart requested but executable path could not be determined (may be inaccessible from SYSTEM context). Restart manually.'
    }
}

if ($errorCount -gt 0) { exit 1 }
exit 0
