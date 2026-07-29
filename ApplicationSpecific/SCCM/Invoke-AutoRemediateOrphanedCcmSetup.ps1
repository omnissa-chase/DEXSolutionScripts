<#
.SYNOPSIS
    OrphanedCcmSetupResolutionWizard -- Clear a stuck ccmsetup.exe retry loop.

.DESCRIPTION
    Split out of Invoke-AutoRemediateSCCMClient.ps1 deliberately. Deploying THIS
    script is the opt-in -- do not fold it back into a general health sweep.

    +------+----------------------------+----------------------------------+
    | Step | Name                       | Remediates On                    |
    +------+----------------------------+----------------------------------+
    |  1   | Active Download Guard      | -- (abort gate)                  |
    |  2   | Retry Loop Confirmation    | -- (abort gate)                  |
    |  3   | Orphaned CcmSetup Process  | Failed                           |
    |  4   | Client Service Recovery    | Failed                           |
    +------+----------------------------+----------------------------------+

    WHY THIS IS NOT AUTO-RUN FLEET-WIDE
    - ccmsetup.exe retrying is DESIGNED behaviour. It retries roughly every 10
      minutes for up to 7 days when it cannot reach a source or download content.
      A long-running ccmsetup is not automatically a broken one.
    - A legitimate install or upgrade over a throttled WAN link, VPN, or a slow
      branch DP can genuinely exceed several hours.
    - Killing ccmsetup mid-write can leave a PARTIALLY INSTALLED client -- files
      staged, services half-registered, WMI namespaces incomplete. That state is
      materially worse than the retry loop it was meant to fix, and typically needs
      a manual ccmsetup /uninstall + reinstall to recover.

    GUARDS APPLIED HERE
    - Step 1 aborts if ccmsetup is actively downloading (live BITS job or a
      ccmcache/ccmsetup working folder that is still growing). Slow is not stuck.
    - Step 2 aborts unless ccmsetup.log shows an actual retry pattern within the
      recent window. Long-running without retries means it is still working.
    - Step 3 only kills processes older than $OrphanMinutes that cleared both gates.
    - Step 4 reports the resulting client state so a follow-up reinstall can be
      targeted, since a killed ccmsetup frequently leaves the client incomplete.

.NOTES
    Script Name  : Invoke-AutoRemediateOrphanedCcmSetup.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-29
    Timeout      : 120 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Tunables ------------------------------------------------------------------
$OrphanMinutes     = 240    # ccmsetup.exe older than this is a kill candidate (4h)
$ProgressWaitSec   = 8      # Sample window used to detect an actively growing download
$RetryLogTailBytes = 65536  # Tail of ccmsetup.log inspected for the retry pattern
$RetryWindowHours  = 2      # Retry evidence must be this recent to count
$MinRetryCount     = 3      # Number of retry entries that confirms a loop

$CcmSetupLog = Join-Path $env:SystemRoot 'ccmsetup\Logs\ccmsetup.log'
$CcmSetupDir = Join-Path $env:SystemRoot 'ccmsetup'

# -- Step Definitions ----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'Active Download Guard'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $procs = @(Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue)
            if ($procs.Count -eq 0) {
                $Script:AbortKill = $true
                return @{ Status = 'Passed'; Message = 'No ccmsetup.exe running -- nothing to do' }
            }

            # A live BITS transfer means it is downloading, not stuck.
            $active = @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue |
                        Where-Object { $_.JobState -in 'Transferring', 'Connecting', 'Queued' })
            if ($active.Count -gt 0) {
                $Script:AbortKill = $true
                return @{ Status = 'Warning'; Message = "Aborting -- $($active.Count) active BITS transfer(s); install is progressing, not stuck" }
            }

            # Second signal: is the ccmsetup working folder still growing?
            if (Test-Path $CcmSetupDir) {
                $sizeBefore = (Get-ChildItem -Path $CcmSetupDir -Recurse -File -Force -ErrorAction SilentlyContinue |
                               Measure-Object -Property Length -Sum).Sum
                Start-Sleep -Seconds $ProgressWaitSec
                $sizeAfter  = (Get-ChildItem -Path $CcmSetupDir -Recurse -File -Force -ErrorAction SilentlyContinue |
                               Measure-Object -Property Length -Sum).Sum

                if ($sizeAfter -gt $sizeBefore) {
                    $delta = [math]::Round(($sizeAfter - $sizeBefore) / 1KB, 1)
                    $Script:AbortKill = $true
                    return @{ Status = 'Warning'; Message = "Aborting -- ccmsetup folder grew ${delta}KB in ${ProgressWaitSec}s; install is progressing, just slow" }
                }
            }

            return @{ Status = 'Passed'; Message = 'No active download detected -- ccmsetup is idle' }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Retry Loop Confirmation'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if ($Script:AbortKill) {
                return @{ Status = 'Passed'; Message = 'Skipped -- blocked by step 1' }
            }

            if (-not (Test-Path $CcmSetupLog)) {
                $Script:AbortKill = $true
                return @{ Status = 'Warning'; Message = 'Aborting -- ccmsetup.log not found; cannot confirm a retry loop, and killing on age alone is unsafe' }
            }

            # Tail only. ccmsetup.log can be large and a full read wastes the budget.
            $fs = [System.IO.File]::Open($CcmSetupLog, 'Open', 'Read', 'ReadWrite')
            try {
                if ($fs.Length -gt $RetryLogTailBytes) {
                    $null = $fs.Seek(-$RetryLogTailBytes, 'End')
                }
                $reader = New-Object System.IO.StreamReader($fs)
                $tail   = $reader.ReadToEnd()
            } finally {
                $fs.Dispose()
            }

            # ccmsetup logs its backoff explicitly when it is looping.
            $retries = ([regex]::Matches($tail, 'Sleeping for \d+ minutes before retrying|Failed to (?:download|get) .*retrying|Next retry in')).Count

            if ($retries -lt $MinRetryCount) {
                $Script:AbortKill = $true
                return @{ Status = 'Warning'; Message = "Aborting -- only $retries retry entries in the recent log (need $MinRetryCount); ccmsetup appears to still be working" }
            }

            $logAgeMin = [math]::Round(((Get-Date) - (Get-Item $CcmSetupLog).LastWriteTime).TotalMinutes)
            if ($logAgeMin -gt ($RetryWindowHours * 60)) {
                $Script:AbortKill = $true
                return @{ Status = 'Warning'; Message = "Aborting -- retry evidence found but ccmsetup.log last wrote ${logAgeMin}m ago, outside the ${RetryWindowHours}h window" }
            }

            return @{ Status = 'Passed'; Message = "Retry loop confirmed: $retries retry entries, log active ${logAgeMin}m ago" }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Orphaned CcmSetup Process'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if ($Script:AbortKill) {
                return @{ Status = 'Passed'; Message = 'Skipped -- blocked by an earlier guard; no process terminated' }
            }

            $cutoff  = (Get-Date).AddMinutes(-$OrphanMinutes)
            $orphans = @(Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue |
                         Where-Object { $_.StartTime -lt $cutoff })

            if ($orphans.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "ccmsetup.exe running but younger than ${OrphanMinutes}m -- left alone" }
            }

            $mins = [math]::Round(((Get-Date) - ($orphans | Sort-Object StartTime | Select-Object -First 1).StartTime).TotalMinutes)
            return @{ Status = 'Failed'; Message = "$($orphans.Count) ccmsetup.exe process(es) in a confirmed retry loop for ${mins}m -- terminating" }
        }
        ResolutionScript = {
            $cutoff = (Get-Date).AddMinutes(-$OrphanMinutes)
            Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue |
                Where-Object { $_.StartTime -lt $cutoff } |
                Stop-Process -Force -ErrorAction SilentlyContinue

            $Script:KilledCcmSetup = $true
        }
    },

    @{
        Name             = 'Client Service Recovery'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $Script:KilledCcmSetup) {
                return @{ Status = 'Passed'; Message = 'No process terminated -- client state unchanged' }
            }

            Start-Sleep -Seconds 3

            $svc = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
            if (-not $svc) {
                return @{
                    Status  = 'Failed'
                    Message = 'CcmExec service is absent after terminating ccmsetup -- client is partially installed; a manual ccmsetup /uninstall + reinstall is required'
                }
            }
            if ($svc.Status -ne 'Running') {
                return @{ Status = 'Failed'; Message = "CcmExec is $($svc.Status) after terminating ccmsetup -- attempting start" }
            }

            $client = Get-CimInstance -Namespace 'root\ccm' -ClassName 'SMS_Client' -ErrorAction SilentlyContinue
            if (-not $client) {
                return @{
                    Status  = 'Failed'
                    Message = 'CcmExec running but root\ccm is unavailable -- client is incomplete; schedule a reinstall'
                }
            }

            return @{ Status = 'Passed'; Message = "Client intact after cleanup (version $($client.ClientVersion))" }
        }
        ResolutionScript = {
            & sc.exe start CcmExec | Out-Null
        }
    }
)

# -- Execution Engine ----------------------------------------------------------
$Script:AbortKill      = $false
$Script:KilledCcmSetup = $false

$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Host ''
Write-Host "`n-- OrphanedCcmSetupResolutionWizard ------------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan

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

    # -- Remediation ----------------------------------------------------------
    $shouldRemediate = ($status -eq 'Failed') -or
                       ($status -eq 'Warning' -and $step.ResolveOnWarning)

    if ($shouldRemediate -and $step.ResolutionScript) {
        try {
            & $step.ResolutionScript | Out-Null
            $remediated = $true
        } catch {
            $remError = $_.Exception.Message
        }
    }

    # -- Output ---------------------------------------------------------------
    $color = switch ($status) {
        'Passed'  { 'Green'  }
        'Warning' { 'Yellow' }
        'Failed'  { 'Red'    }
        default   { 'White'  }
    }
    $remNote = if ($remediated)   { '  -> Remediation ran' }
               elseif ($remError) { "  -> Remediation ERROR: $remError" }
               else               { '' }

    Write-Host "`n  [$($status.PadRight(7))] $($step.Name): $message$remNote" -ForegroundColor $color

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary -------------------------------------------------------------------
$passed   = ($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = ($results | Where-Object { $_.Remediated }).Count

Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ''

if ($failed -gt 0) { exit 1 }
exit 0
