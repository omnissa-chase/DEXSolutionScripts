<#
.SYNOPSIS
    Invoke-AutoRemediateDriverIssues -- Automated driver diagnostic and escalating remediation.

.DESCRIPTION
    Runs a hard-coded sequence of driver health checks and automatically executes
    an escalating remediation for any step that fails. All operations run silently
    from SYSTEM context -- no UAC prompts, no user dialogs.

    Remediation escalates in three stages per device, stopping as soon as the
    driver error clears:
        Stage 1 -- pnputil /scan-devices    (zero interruption; re-enumerates PnP bus)
        Stage 2 -- pnputil /restart-device  (~1-2 s device gap; no user dialog)
        Stage 3 -- pnputil /rollback-driver (previous version from driver store; requires Win 10 2004+)

    If all three stages fail the device is flagged in the summary but no reboot is
    forced -- a reboot recommendation is surfaced via exit code 2.

    +------+------------------------------------+----------------------------------+
    | Step | Name                               | Remediates On                    |
    +------+------------------------------------+----------------------------------+
    |  1   | Driver Store Scan                  | Failed                           |
    |  2   | Audio Driver Health                | Failed                           |
    |  3   | Bluetooth Driver Health            | Failed                           |
    |  4   | Network Adapter Driver Health      | Failed                           |
    |  5   | Pending Driver Reboot              | -- (informational only)          |
    +------+------------------------------------+----------------------------------+

    Each step returns @{ Status = 'Passed'|'Warning'|'Failed'; Message = '...' }
    Resolution scripts run silently; errors are captured and reported at the end.

.NOTES
    Script Name  : Invoke-AutoRemediateDriverIssues.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-17
    Timeout      : 120 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Shared helper: escalating driver remediation ------------------------------
# Accepts a list of PnP InstanceIDs with non-zero ConfigManagerErrorCode.
# Returns a hashtable: { Fixed = @(...); Unfixed = @(...) }
function Invoke-DriverEscalation {
    param([string[]]$InstanceIds)

    $fixed   = @()
    $unfixed = @()

    foreach ($id in $InstanceIds) {

        $cleared = $false

        # Stage 1: Scan for hardware changes -- zero user interruption
        pnputil /scan-devices 2>&1 | Out-Null
        Start-Sleep -Seconds 3

        $dev = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
               Where-Object { $_.DeviceID -eq $id }
        if ($dev -and $dev.ConfigManagerErrorCode -eq 0) { $fixed += $id; continue }

        # Stage 2: Restart the device -- ~1-2 s device gap, no dialog
        pnputil /restart-device "$id" 2>&1 | Out-Null
        Start-Sleep -Seconds 3

        $dev = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
               Where-Object { $_.DeviceID -eq $id }
        if ($dev -and $dev.ConfigManagerErrorCode -eq 0) { $fixed += $id; continue }

        # Stage 3: Roll back to the previously installed driver (Win 10 2004+)
        # pnputil /rollback-driver exits non-zero if no previous version exists; safe to call.
        pnputil /rollback-driver "$id" 2>&1 | Out-Null
        Start-Sleep -Seconds 5

        $dev = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
               Where-Object { $_.DeviceID -eq $id }
        if ($dev -and $dev.ConfigManagerErrorCode -eq 0) { $fixed += $id } else { $unfixed += $id }
    }

    return @{ Fixed = $fixed; Unfixed = $unfixed }
}

# -- Step Definitions ----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'Driver Store Scan'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # Verify pnputil is reachable and the driver store is enumerable.
            # A failure here means subsequent driver operations will also fail.
            $out = pnputil /enum-drivers 2>&1
            if ($LASTEXITCODE -ne 0) {
                return @{ Status = 'Failed'; Message = "pnputil /enum-drivers failed (exit $LASTEXITCODE)" }
            }
            $count = ($out | Select-String 'Published Name').Count
            return @{ Status = 'Passed'; Message = "$count OEM driver package(s) in driver store" }
        }
        ResolutionScript = {
            # Trigger a full hardware re-enumeration -- safest possible driver operation
            pnputil /scan-devices 2>&1 | Out-Null
        }
    },

    @{
        Name             = 'Audio Driver Health'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $audioDevices = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -match 'audio|sound|speaker|headset|realtek|conexant|IDT|Synaptics.*audio|Intel.*Smart Sound'
                }
            if (-not $audioDevices) {
                return @{ Status = 'Warning'; Message = 'No audio PnP devices found in hardware enumeration' }
            }
            $errored = $audioDevices | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
            if ($errored) {
                $names = ($errored | ForEach-Object { "$($_.Name) [code $($_.ConfigManagerErrorCode)]" }) -join '; '
                return @{ Status = 'Failed'; Message = "Driver error on: $names" }
            }
            $names = ($audioDevices.Name) -join ', '
            return @{ Status = 'Passed'; Message = "Healthy audio driver(s): $names" }
        }
        ResolutionScript = {
            $errored = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -match 'audio|sound|speaker|headset|realtek|conexant|IDT|Synaptics.*audio|Intel.*Smart Sound' -and
                    $_.ConfigManagerErrorCode -ne 0
                }
            if ($errored) {
                $result = Invoke-DriverEscalation -InstanceIds ($errored.DeviceID)
                $script:AudioDriverUnfixed = $result.Unfixed
            }
        }
    },

    @{
        Name             = 'Bluetooth Driver Health'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $btDevices = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'Bluetooth' }
            if (-not $btDevices) {
                return @{ Status = 'Warning'; Message = 'No Bluetooth PnP devices found -- adapter may not be present' }
            }
            $errored = $btDevices | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
            if ($errored) {
                $names = ($errored | ForEach-Object { "$($_.Name) [code $($_.ConfigManagerErrorCode)]" }) -join '; '
                return @{ Status = 'Failed'; Message = "Driver error on: $names" }
            }
            $names = ($btDevices.Name) -join ', '
            return @{ Status = 'Passed'; Message = "Healthy Bluetooth driver(s): $names" }
        }
        ResolutionScript = {
            $errored = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'Bluetooth' -and $_.ConfigManagerErrorCode -ne 0 }
            if ($errored) {
                $result = Invoke-DriverEscalation -InstanceIds ($errored.DeviceID)
                $script:BluetoothDriverUnfixed = $result.Unfixed
            }
        }
    },

    @{
        Name             = 'Network Adapter Driver Health'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # Scope to physical/virtual NIC PnP entries; skip software-only tunnel adapters
            $netDevices = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -match 'ethernet|wi-?fi|wireless|network adapter|realtek.*gbe|intel.*ethernet|intel.*wi-?fi|broadcom.*netxtreme' -and
                    $_.Name -notmatch 'tunnel|loopback|virtual|miniport|wan miniport'
                }
            if (-not $netDevices) {
                return @{ Status = 'Warning'; Message = 'No physical network adapter PnP devices found' }
            }
            $errored = $netDevices | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
            if ($errored) {
                $names = ($errored | ForEach-Object { "$($_.Name) [code $($_.ConfigManagerErrorCode)]" }) -join '; '
                return @{ Status = 'Failed'; Message = "Driver error on: $names" }
            }
            $names = ($netDevices.Name) -join ', '
            return @{ Status = 'Passed'; Message = "Healthy network driver(s): $names" }
        }
        ResolutionScript = {
            $errored = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -match 'ethernet|wi-?fi|wireless|network adapter|realtek.*gbe|intel.*ethernet|intel.*wi-?fi|broadcom.*netxtreme' -and
                    $_.Name -notmatch 'tunnel|loopback|virtual|miniport|wan miniport' -and
                    $_.ConfigManagerErrorCode -ne 0
                }
            if ($errored) {
                $result = Invoke-DriverEscalation -InstanceIds ($errored.DeviceID)
                $script:NetworkDriverUnfixed = $result.Unfixed
            }
        }
    },

    @{
        Name             = 'Pending Driver Reboot'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false   # Cannot auto-reboot without interrupting the user -- informational only
        DetectionScript  = {
            # PendingFileRenameOperations and the CBS/Session Manager reboot keys are the
            # standard signals that a driver or component install is waiting on a reboot.
            $cbsKey    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
            $smKey     = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
            $pfro      = (Get-ItemProperty -Path $smKey -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
            $cbsPend   = Test-Path $cbsKey

            if ($cbsPend -or $pfro) {
                return @{ Status = 'Warning'; Message = 'A pending reboot was detected -- driver changes may require a restart to complete' }
            }
            return @{ Status = 'Passed'; Message = 'No pending reboot detected' }
        }
        ResolutionScript = $null   # Intentionally no auto-remediation -- reboot requires user scheduling
    }
)

# -- Execution Engine ----------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

Write-Host "`n-- Invoke-AutoRemediateDriverIssues -----------------------------" -ForegroundColor Cyan
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

# -- Summary ------------------------------------------------------------------
$passed   = ($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = ($results | Where-Object { $_.Remediated }).Count

Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"

# Report any devices that survived all three escalation stages
$allUnfixed = @(
    $script:AudioDriverUnfixed
    $script:BluetoothDriverUnfixed
    $script:NetworkDriverUnfixed
) | Where-Object { $_ }

if ($allUnfixed) {
    Write-Host "`n  [NOTICE] The following device(s) could not be resolved without a reboot:" -ForegroundColor Yellow
    $allUnfixed | ForEach-Object { Write-Host "           $_" -ForegroundColor Yellow }
    Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ''
    exit 2   # Distinct exit code: partial remediation, reboot recommended
}

Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ''

if ($failed -gt 0) { exit 1 }
exit 0
