<#
.SYNOPSIS
    Invoke-AutoRemediateDriverIssues -- Automated driver diagnostic and escalating remediation.

.PARAMETER DriverFilter
    A single device name pattern (regex) that narrows which PnP devices are
    checked and remediated in Steps 2-4. Example: -DriverFilter 'Realtek'
    When omitted alongside -ForceAll the class-level filters in each step apply.

.PARAMETER AllowedActions
    Controls which remediation stages Invoke-DriverEscalation is permitted to run.
    Escalation always attempts stages in this fixed order, stopping as soon as the
    driver error clears:
        Scan      -- pnputil /scan-devices         (zero interruption)
        Restart   -- pnputil /restart-device       (~1-2 s device gap)
        Rollback  -- pnputil /rollback-driver      (previous version from driver store)
        Reinstall -- remove device + scan-devices  (Windows picks best available driver)
        Uninstall -- remove device, no re-enum     (strips the driver; use for crash-causing drivers)
    Default: Scan, Restart, Rollback
    Reinstall and Uninstall must be explicitly added -- they are more destructive.

.PARAMETER ForceAll
    Run all enabled steps against all matching devices with no additional scope
    restriction. Must be explicitly supplied to prevent accidental broad remediation.

.NOTES
    Script Name  : Invoke-AutoRemediateDriverIssues.ps1
    Version      : 2.2.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-20
    Timeout      : 120 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
param(
    # A single device name pattern (regex) applied on top of each step's own
    # class filter. Example: -DriverFilter 'Realtek'
    [string]$DriverFilter = $env:DriverFilter,

    # Which remediation stages are permitted. Stages always run in the fixed order
    # listed below; escalation stops at the first stage that clears the error.
    # Valid values: Scan | Restart | Rollback | Reinstall | Uninstall
    [ValidateSet('Scan', 'Restart', 'Rollback', 'Reinstall', 'Uninstall')]
    [string[]]$AllowedActions = @('Scan', 'Restart', 'Rollback'),

    # Run all enabled steps against all devices. Must be explicitly supplied.
    [switch]$ForceAll
)

# -- Input guard ---------------------------------------------------------------
# Require the caller to be deliberate: either scope the run with -DriverFilter
# and/or -StepNumbers, or explicitly opt in to everything with -ForceAll.
if (-not $ForceAll -and -not $DriverFilter) {
    Write-Error ('No scope specified. Supply -DriverFilter to target specific devices, ' +
                 'or use -ForceAll to run against all devices.')
    exit 1
}

# -- Shared helper: escalating driver remediation ------------------------------
# Accepts a list of PnP InstanceIDs with non-zero ConfigManagerErrorCode.
# Returns a hashtable: { Fixed = @(...); Unfixed = @(...) }

# Test-DriverMatch: returns $true when $DriverFilter is not set (run against all
# devices) or when the device name matches at least one supplied pattern.
function Test-DriverMatch {
    param([string]$Name)
    if (-not $script:DriverFilter) { return $true }
    return $Name -match $script:DriverFilter
}

function Invoke-DriverEscalation {
    param(
        [string[]]$InstanceIds,
        [string[]]$AllowedActions
    )

    $fixed   = @()
    $unfixed = @()

    foreach ($id in $InstanceIds) {

        # Stage: Scan -- re-enumerate the PnP bus; Windows may auto-reinstall a cached
        # driver. Zero user interruption; safest possible action.
        if ('Scan' -in $AllowedActions) {
            pnputil /scan-devices 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            $dev = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                   Where-Object { $_.DeviceID -eq $id }
            if ($dev -and $dev.ConfigManagerErrorCode -eq 0) { $fixed += $id; continue }
        }

        # Stage: Restart -- disable then re-enable the device, forcing the driver to
        # fully reload. Causes a ~1-2 s device gap; no user dialog.
        if ('Restart' -in $AllowedActions) {
            pnputil /restart-device "$id" 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            $dev = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                   Where-Object { $_.DeviceID -eq $id }
            if ($dev -and $dev.ConfigManagerErrorCode -eq 0) { $fixed += $id; continue }
        }

        # Stage: Rollback -- revert to the previously installed driver version stored
        # in the local driver store. Requires Windows 10 2004+. Exits non-zero if no
        # previous version exists; safe to call regardless.
        if ('Rollback' -in $AllowedActions) {
            pnputil /rollback-driver "$id" 2>&1 | Out-Null
            Start-Sleep -Seconds 5
            $dev = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                   Where-Object { $_.DeviceID -eq $id }
            if ($dev -and $dev.ConfigManagerErrorCode -eq 0) { $fixed += $id; continue }
        }

        # Stage: Reinstall -- remove the device from the PnP tree then trigger Windows
        # to re-enumerate and install the best matching driver from the local store.
        # The instance ID is location-based and typically survives the remove + scan cycle.
        if ('Reinstall' -in $AllowedActions) {
            pnputil /remove-device "$id" 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            pnputil /scan-devices 2>&1 | Out-Null
            Start-Sleep -Seconds 5
            $dev = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                   Where-Object { $_.DeviceID -eq $id }
            if ($dev -and $dev.ConfigManagerErrorCode -eq 0) { $fixed += $id; continue }
        }

        # Stage: Uninstall -- remove the device from the PnP tree and leave it removed.
        # No re-enumeration is triggered. Use when a driver is causing hard failures and
        # must be stripped before a manual reinstall or reboot. Treated as resolved for
        # exit-code purposes since the problematic state has been intentionally cleared.
        if ('Uninstall' -in $AllowedActions) {
            pnputil /remove-device "$id" 2>&1 | Out-Null
            $fixed += $id; continue
        }

        $unfixed += $id
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
            $allAudio    = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -match 'audio|sound|speaker|headset|realtek|conexant|IDT|Synaptics.*audio|Intel.*Smart Sound'
                }
            $audioDevices = $allAudio | Where-Object { Test-DriverMatch $_.Name }
            if (-not $audioDevices) {
                if ($allAudio -and $script:DriverFilter) {
                    return @{ Status = 'Passed'; Message = "No audio devices match filter '$($script:DriverFilter)' -- step skipped" }
                }
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
                } | Where-Object { Test-DriverMatch $_.Name }
            if ($errored) {
                $result = Invoke-DriverEscalation -InstanceIds ($errored.DeviceID) -AllowedActions $script:AllowedActions
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
            $allBt    = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'Bluetooth' }
            $btDevices = $allBt | Where-Object { Test-DriverMatch $_.Name }
            if (-not $btDevices) {
                if ($allBt -and $script:DriverFilter) {
                    return @{ Status = 'Passed'; Message = "No Bluetooth devices match filter '$($script:DriverFilter)' -- step skipped" }
                }
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
                Where-Object { $_.Name -match 'Bluetooth' -and $_.ConfigManagerErrorCode -ne 0 } |
                Where-Object { Test-DriverMatch $_.Name }
            if ($errored) {
                $result = Invoke-DriverEscalation -InstanceIds ($errored.DeviceID) -AllowedActions $script:AllowedActions
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
            $allNet    = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -match 'ethernet|wi-?fi|wireless|network adapter|realtek.*gbe|intel.*ethernet|intel.*wi-?fi|broadcom.*netxtreme' -and
                    $_.Name -notmatch 'tunnel|loopback|virtual|miniport|wan miniport'
                }
            $netDevices = $allNet | Where-Object { Test-DriverMatch $_.Name }
            if (-not $netDevices) {
                if ($allNet -and $script:DriverFilter) {
                    return @{ Status = 'Passed'; Message = "No network adapter devices match filter '$($script:DriverFilter)' -- step skipped" }
                }
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
                } | Where-Object { Test-DriverMatch $_.Name }
            if ($errored) {
                $result = Invoke-DriverEscalation -InstanceIds ($errored.DeviceID) -AllowedActions $script:AllowedActions
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
    },

    @{
        Name             = 'Uncovered Device Errors'
        Order            = 6
        Enabled          = $true
        ResolveOnWarning = $false   # Device class unknown -- cannot safely escalate without knowing the driver type
        DetectionScript  = {
            # Any PnP device with a non-zero error code that falls outside the classes
            # handled by Steps 2-4. This catches GPUs, USB controllers, chipsets, storage
            # controllers, touchpads, Thunderbolt, etc. without attempting blind remediation.
            $coveredPattern = 'audio|sound|speaker|headset|realtek|conexant|IDT|Synaptics.*audio|Intel.*Smart Sound' +
                              '|Bluetooth' +
                              '|ethernet|wi-?fi|wireless|network adapter|realtek.*gbe|intel.*ethernet|intel.*wi-?fi|broadcom.*netxtreme'

            $uncovered = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.Name -notmatch $coveredPattern } |
                Where-Object { Test-DriverMatch $_.Name }

            if ($uncovered) {
                $names = ($uncovered | ForEach-Object { "$($_.Name) [code $($_.ConfigManagerErrorCode)]" }) -join '; '
                return @{ Status = 'Warning'; Message = "Errored device(s) outside covered classes: $names" }
            }
            return @{ Status = 'Passed'; Message = 'No uncovered device driver errors detected' }
        }
        ResolutionScript = $null   # Flag only -- escalation requires knowing the device class
    }
)

# -- Execution Engine ----------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

$scopeLine   = if ($ForceAll)    { 'Scope: ALL (-ForceAll)' }
             else                { "Driver filter: $DriverFilter" }
$actionsLine = "Actions: $($AllowedActions -join ', ')"

Write-Host "`n-- Invoke-AutoRemediateDriverIssues -----------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   $scopeLine"
Write-Host "   $actionsLine"
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
