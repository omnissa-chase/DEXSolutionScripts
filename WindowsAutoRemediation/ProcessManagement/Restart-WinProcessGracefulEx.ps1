
<#

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$FileDescription    = $env:FileDescription,
    [bool]  $Restart                  = $(if ($env:Restart)                  { [System.Convert]::ToBoolean($env:Restart) }                   else { $true })
)
$FileDescription="Chrome"
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

<# Prepare the process object and set executable/arguments
$process = New-Object -TypeName System.Diagnostics.Process
$info = Get-Item $FilePath
$FullFilepath=$info.FullName
$process.StartInfo.FileName = $info.FullName
$process.StartInfo.Arguments = $ArgumentList
   
# Only run when not in -WhatIf mode
# UseShellExecute=false allows redirection of stdio streams
#$process.StartInfo.UseShellExecute = $true
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.RedirectStandardOutput = $true
$process.StartInfo.RedirectStandardError = $true
$process.StartInfo.WorkingDirectory = $WorkingDirectory
$process.EnableRaisingEvents = $true
$process.StartInfo.RedirectStandardInput = $true
$process.StartInfo.RedirectStandardError = $true

# Register an event so we log when the process exits
$exitSub = Register-ObjectEvent -InputObject $process -MessageData (New-Object -TypeName PSCustomObject -Property @{"InstallerId"=$InstallerId}) -EventName Exited -Action {
    $InstallerId = $Event.Sender.MessageData.InstallerId
    Write-Log "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") VERBOSE`: [PID $($Event.Sender.Id)] ($InstallerId) exited with $($Event.Sender.ExitCode)"
}

# Track final outcome for registry updates in finally{}
$FINAL_EXIT_CODE=-1
$FINAL_STATUS="ERROR"

# Launch the process
$process.Start() | Out-Null#>

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
            #$gracefulSent = $proc.Close()
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
            Start-Process -FilePath $restartPath -ArgumentList "--restore-last-session" -ErrorAction Stop
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

