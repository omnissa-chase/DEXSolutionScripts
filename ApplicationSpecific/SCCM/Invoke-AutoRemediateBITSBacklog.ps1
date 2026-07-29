<#
.SYNOPSIS
    BITSBacklogResolutionWizard -- Clear stalled Configuration Manager BITS jobs.

.DESCRIPTION
    Split out of Invoke-AutoRemediateSCCMClient.ps1 deliberately. Deploying THIS
    script is the opt-in -- do not fold it back into a general health sweep.

    +------+----------------------------+----------------------------------+
    | Step | Name                       | Remediates On                    |
    +------+----------------------------+----------------------------------+
    |  1   | BITS Service State         | Failed                           |
    |  2   | Stalled CCM Jobs           | Failed                           |
    |  3   | Non-CCM Job Survey         | -- (report only)                 |
    +------+----------------------------+----------------------------------+

    WHY THIS IS NOT AUTO-RUN FLEET-WIDE
    - BITS is a SHARED subsystem. Windows Update, Delivery Optimization, Intune,
      Edge/Chrome updaters and various third-party agents all queue jobs there.
      Cancelling by job state alone would silently kill other products' downloads.
    - 'TransientError' is a NORMAL self-healing state on any device that sleeps,
      roams between networks, or sits behind a flaky VPN. BITS retries it on its
      own. Treating it as stuck causes needless re-downloads.

    SCOPING RULES APPLIED HERE
    - Only jobs whose DisplayName matches $CcmJobPattern are ever removed. CM names
      its content transfers 'CCMDTS Job' / 'CCMDTS*'.
    - Only 'Error' (hard failure) and long-Suspended jobs are removed.
      'TransientError' is explicitly excluded.
    - A job must also be older than $MinJobAgeHours, so a job that just entered
      Error state and may still retry is left alone.
    - Removing a CM job is safe: CcmExec re-requests the content on its next
      evaluation cycle. Nothing is permanently lost, but it does re-pull from the
      distribution point -- consider DP/WAN load before broad deployment.

.NOTES
    Script Name  : Invoke-AutoRemediateBITSBacklog.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-29
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Tunables ------------------------------------------------------------------
$CcmJobPattern     = 'CCMDTS*'   # Configuration Manager content transfer jobs only
$MinJobAgeHours    = 4           # Job must be at least this old before it is touched
$SuspendedAgeHours = 24          # Suspended jobs older than this are considered abandoned

# -- Step Definitions ----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'BITS Service State'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $svc = Get-Service -Name 'BITS' -ErrorAction SilentlyContinue
            if (-not $svc) {
                return @{ Status = 'Failed'; Message = 'BITS service not present' }
            }

            $wmiSvc    = Get-CimInstance -ClassName Win32_Service -Filter "Name='BITS'" -ErrorAction SilentlyContinue
            $startMode = if ($wmiSvc) { $wmiSvc.StartMode } else { 'Unknown' }

            if ($startMode -eq 'Disabled') {
                return @{ Status = 'Failed'; Message = 'BITS is Disabled -- no CM content can download' }
            }
            # Stopped is normal: BITS is trigger-started and idles down when the queue is empty.
            return @{ Status = 'Passed'; Message = "BITS is $($svc.Status) (StartMode: $startMode)" }
        }
        ResolutionScript = {
            # Manual is the Windows default for BITS -- it is demand-started, not Automatic.
            & sc.exe config BITS start= demand | Out-Null
            & sc.exe start BITS | Out-Null
        }
    },

    @{
        Name             = 'Stalled CCM Jobs'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue |
                      Where-Object { $_.DisplayName -like $CcmJobPattern })

            if ($jobs.Count -eq 0) {
                return @{ Status = 'Passed'; Message = 'No Configuration Manager BITS jobs queued' }
            }

            $errorCutoff     = (Get-Date).AddHours(-$MinJobAgeHours)
            $suspendedCutoff = (Get-Date).AddHours(-$SuspendedAgeHours)

            # 'TransientError' is deliberately NOT matched -- BITS retries it itself.
            $stalled = @($jobs | Where-Object {
                ($_.JobState -eq 'Error'     -and $_.CreationTime -lt $errorCutoff) -or
                ($_.JobState -eq 'Suspended' -and $_.CreationTime -lt $suspendedCutoff)
            })

            if ($stalled.Count -gt 0) {
                $states = ($stalled | Group-Object JobState |
                           ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
                return @{ Status = 'Failed'; Message = "$($stalled.Count) stalled CCM job(s) of $($jobs.Count) total ($states)" }
            }

            $transient = @($jobs | Where-Object { $_.JobState -eq 'TransientError' }).Count
            if ($transient -gt 0) {
                return @{ Status = 'Passed'; Message = "$($jobs.Count) CCM job(s); $transient in TransientError (normal, BITS will retry) -- no action" }
            }
            return @{ Status = 'Passed'; Message = "$($jobs.Count) CCM job(s) queued, none stalled" }
        }
        ResolutionScript = {
            # CcmExec re-requests the content on its next evaluation cycle.
            $errorCutoff     = (Get-Date).AddHours(-$MinJobAgeHours)
            $suspendedCutoff = (Get-Date).AddHours(-$SuspendedAgeHours)

            Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.DisplayName -like $CcmJobPattern -and (
                        ($_.JobState -eq 'Error'     -and $_.CreationTime -lt $errorCutoff) -or
                        ($_.JobState -eq 'Suspended' -and $_.CreationTime -lt $suspendedCutoff)
                    )
                } |
                Remove-BitsTransfer -ErrorAction SilentlyContinue
        }
    },

    @{
        Name             = 'Non-CCM Job Survey'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false   # Report only -- these belong to other products, never touched
        DetectionScript  = {
            $other = @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue |
                       Where-Object { $_.DisplayName -notlike $CcmJobPattern })

            if ($other.Count -eq 0) {
                return @{ Status = 'Passed'; Message = 'No non-CCM BITS jobs present' }
            }

            $stalledOther = @($other | Where-Object { $_.JobState -in 'Error', 'Suspended' })
            if ($stalledOther.Count -gt 0) {
                $names = ($stalledOther | Select-Object -First 3 -ExpandProperty DisplayName) -join '; '
                return @{
                    Status  = 'Warning'
                    Message = "$($stalledOther.Count) stalled non-CCM BITS job(s) of $($other.Count) -- NOT touched (owned by other products): $names"
                }
            }
            return @{ Status = 'Passed'; Message = "$($other.Count) non-CCM BITS job(s) present and healthy -- not touched" }
        }
        ResolutionScript = $null
    }
)

# -- Execution Engine ----------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Host ''
Write-Host "`n-- BITSBacklogResolutionWizard -----------------------------------" -ForegroundColor Cyan
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
