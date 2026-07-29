<#
.SYNOPSIS
    WMIRepositoryResolutionWizard -- Salvage a corrupt WMI repository. DESTRUCTIVE-ADJACENT.

.DESCRIPTION
    Split out of Invoke-AutoRemediateSCCMClient.ps1 deliberately. Deploying THIS
    script is the opt-in -- do not fold it back into a general health sweep.

    +------+----------------------------+----------------------------------+
    | Step | Name                       | Remediates On                    |
    +------+----------------------------+----------------------------------+
    |  1   | Install In Progress Guard  | -- (abort gate)                  |
    |  2   | Repository Consistency     | Failed                           |
    |  3   | Post-Salvage Verification  | -- (report only)                 |
    +------+----------------------------+----------------------------------+

    WHY THIS IS NOT AUTO-RUN FLEET-WIDE
    - 'winmgmt /salvagerepository' restarts the Winmgmt service. That cascades into
      CcmExec and every other WMI provider on the box -- monitoring agents, AV
      management, inventory, and any in-flight script using WMI.
    - '/verifyrepository' is known to report "inconsistent" spuriously on some
      Windows builds. Acting on a single unverified result is a false-positive
      machine that reboots WMI for nothing.
    - Salvage can drop custom MOF-registered classes that third-party agents
      depend on. Those agents may need re-registration afterwards.
    - Runtime is 30 seconds to several minutes. Do not deploy with a short timeout.

    Confirm the finding twice (this script re-verifies before acting) and pilot on
    a small ring before broad deployment.

    NOT PERFORMED
    - 'winmgmt /resetrepository' is intentionally absent. It rebuilds the repository
      from scratch, wiping ALL WMI classes rather than just Configuration Manager's,
      and commonly leaves third-party agents non-functional until reinstalled. If
      an environment genuinely needs it, that should be a separate, explicitly
      authorised script.

.NOTES
    Script Name  : Invoke-AutoRemediateWMIRepository.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-29
    Timeout      : ~5 seconds (launcher exits immediately; payload runs via scheduled task up to 300 seconds)

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

param([switch]$RunAsPayload)

# -- Dispatch constants (shared by launcher and payload) ----------------------
$TaskName   = 'DEX_SCCMRemediateWMI'
$BaseDir    = Join-Path $env:ProgramData 'Omnissa\DEX\SCCM'
$PayloadPs1 = Join-Path $BaseDir 'Invoke-AutoRemediateWMIRepository.ps1'
$RegPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\SCCM\WMIRepository'

# -- Launcher (UEM dispatcher) -------------------------------------------------
# When UEM delivers this script it runs WITHOUT -RunAsPayload. The launcher copies
# the script to a stable on-disk path and dispatches a one-shot scheduled task
# that runs the step engine with -RunAsPayload. The launcher exits in ~5 seconds,
# well within UEM's script timeout. The scheduled task runs the heavy work outside
# UEM's timeout window and writes results to the registry for DEX sensors to read.
if (-not $RunAsPayload) {
    try {
        if (-not (Test-Path $BaseDir)) {
            New-Item -ItemType Directory -Path $BaseDir -Force -ErrorAction Stop | Out-Null
        }

        # Copy the full script to a path that survives UEM's temp file cleanup.
        Copy-Item -Path $PSCommandPath -Destination $PayloadPs1 -Force -ErrorAction Stop

        # Stamp a 'Dispatched' record so sensors have a known value before the
        # payload finishes -- avoids a 'no data' gap in DEX dashboards.
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $RegPath -Name 'Status'           -Value 'Dispatched'         -Type String
        Set-ItemProperty -Path $RegPath -Name 'LastDispatchTime' -Value (Get-Date -Format 'o') -Type String

        # Unregister any stale previous task before re-registering.
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                         -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PayloadPs1`" -RunAsPayload"
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet `
                         -ExecutionTimeLimit '00:10:00' `
                         -DeleteExpiredTaskAfter '00:01:00' `
                         -StartWhenAvailable

        Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
            -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop

        Write-Host "Task '$TaskName' dispatched. Results will appear at: $RegPath"
        exit 0
    } catch {
        Write-Host "[ERROR] Launcher failed: $($_.Exception.Message)"
        exit 1
    }
}
# -- Payload runs below this line (scheduled task context) --------------------

# -- Tunables ------------------------------------------------------------------
$Winmgmt = Join-Path $env:SystemRoot 'System32\wbem\winmgmt.exe'

# -- Step Definitions ----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'Install In Progress Guard'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # Restarting WMI underneath a running client install or task sequence is
            # a reliable way to produce a half-installed client. Abort instead.
            $blockers = @()
            if (Get-Process -Name 'ccmsetup'   -ErrorAction SilentlyContinue) { $blockers += 'ccmsetup.exe' }
            if (Get-Process -Name 'TSManager'  -ErrorAction SilentlyContinue) { $blockers += 'TSManager.exe (task sequence)' }
            if (Get-Process -Name 'TrustedInstaller' -ErrorAction SilentlyContinue) { $blockers += 'TrustedInstaller.exe (servicing)' }

            if ($blockers.Count -gt 0) {
                $Script:AbortSalvage = $true
                return @{ Status = 'Warning'; Message = "Aborting -- install/servicing in progress: $($blockers -join ', ')" }
            }
            return @{ Status = 'Passed'; Message = 'No client install, task sequence, or servicing operation in progress' }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Repository Consistency'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if ($Script:AbortSalvage) {
                return @{ Status = 'Warning'; Message = 'Skipped -- blocked by step 1' }
            }

            # Double-verify. /verifyrepository false-positives on some builds, and a
            # single bad result is not worth restarting WMI over.
            $firstOut  = & $Winmgmt /verifyrepository 2>&1
            $firstCode = $LASTEXITCODE
            if ($firstCode -eq 0) {
                return @{ Status = 'Passed'; Message = 'WMI repository is consistent' }
            }

            Start-Sleep -Seconds 2
            $secondOut  = & $Winmgmt /verifyrepository 2>&1
            $secondCode = $LASTEXITCODE
            if ($secondCode -eq 0) {
                return @{ Status = 'Warning'; Message = "First check reported inconsistent ($($firstOut -join ' ')) but re-check passed -- treating as false positive, no action taken" }
            }

            return @{ Status = 'Failed'; Message = "WMI repository inconsistent on two consecutive checks: $($secondOut -join ' ')" }
        }
        ResolutionScript = {
            # Salvage merges a good copy back over the inconsistent repository.
            # This restarts Winmgmt -- expect dependent providers to blip.
            & $Winmgmt /salvagerepository | Out-Null

            # Give WMI and its dependents time to come back before step 3 verifies.
            Start-Sleep -Seconds 10

            # CcmExec is a WMI dependent and does not always recover on its own.
            $ccm = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
            if ($ccm -and $ccm.Status -ne 'Running') {
                & sc.exe start CcmExec | Out-Null
            }
        }
    },

    @{
        Name             = 'Post-Salvage Verification'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false   # Report only -- if salvage did not work, escalate to a rebuild decision
        DetectionScript  = {
            if ($Script:AbortSalvage) {
                return @{ Status = 'Warning'; Message = 'Skipped -- blocked by step 1' }
            }

            $out = & $Winmgmt /verifyrepository 2>&1
            if ($LASTEXITCODE -ne 0) {
                return @{ Status = 'Failed'; Message = "Repository still inconsistent after salvage ($($out -join ' ')) -- escalate; /resetrepository or reimage is a manual decision, not automated here" }
            }

            # Confirm the CM namespace actually survived -- salvage can drop MOF classes.
            $client = Get-CimInstance -Namespace 'root\ccm' -ClassName 'SMS_Client' -ErrorAction SilentlyContinue
            if (-not $client) {
                return @{ Status = 'Failed'; Message = 'Repository consistent but root\ccm namespace is unavailable -- CM client classes may need re-registration' }
            }

            return @{ Status = 'Passed'; Message = "Repository consistent and root\ccm responding (client $($client.ClientVersion))" }
        }
        ResolutionScript = $null
    }
)

# -- Execution Engine ----------------------------------------------------------
$Script:AbortSalvage = $false

$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Host ''
Write-Host "`n-- WMIRepositoryResolutionWizard ---------------------------------" -ForegroundColor Cyan
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

# -- Persist results for DEX sensors ------------------------------------------
try {
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $RegPath -Name 'Status'          -Value $(if ($failed -gt 0) { 'Failed' } elseif ($warnings -gt 0) { 'Warning' } else { 'Passed' }) -Type String
    Set-ItemProperty -Path $RegPath -Name 'LastRunTime'     -Value (Get-Date -Format 'o') -Type String
    Set-ItemProperty -Path $RegPath -Name 'Passed'          -Value $passed   -Type DWord
    Set-ItemProperty -Path $RegPath -Name 'Warnings'        -Value $warnings -Type DWord
    Set-ItemProperty -Path $RegPath -Name 'Failed'          -Value $failed   -Type DWord
    Set-ItemProperty -Path $RegPath -Name 'RemediationsRun' -Value $remCount -Type DWord
} catch { }

# -- Self-cleanup: unregister the scheduled task ------------------------------
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

if ($failed -gt 0) { exit 1 }
exit 0
