<#
.SYNOPSIS
    Invoke-AutoRemediateAllDriverIssues -- Automated full-sweep driver diagnostic and remediation.

.DESCRIPTION
    Scans all defined PnP device classes for driver error codes and applies an
    escalating remediation sequence controlled by -AllowedActions. Device classes
    are defined in the $DriverClasses table; adding or removing a class requires
    only a single table entry -- no step blocks need to be touched.

    Use -DriverFilter to optionally narrow which devices are evaluated within
    each class. To target a single specific device by regex, use
    Invoke-AutoRemediateDriverIssues.ps1 instead.

    +------+---------------------------+----------------------------------+
    | Step | Name                      | Remediates On                    |
    +------+---------------------------+----------------------------------+
    |  1   | Driver Store Scan         | Failed                           |
    |  2   | Audio Driver Health       | Failed                           |
    |  3   | Bluetooth Driver Health   | Failed                           |
    |  4   | Network Adapter Health    | Failed                           |
    |  5   | GPU / Display Health      | Failed                           |
    |  6   | Storage Controller Health | Failed                           |
    |  7   | Chipset / SMBus Health    | Failed                           |
    |  8   | Touchpad / HID Health     | Failed                           |
    |  9   | Webcam / Camera Health    | Failed                           |
    | 10   | USB / Dock Health         | Failed                           |
    | 11   | Uncovered Device Errors   | -- (flag only)                   |
    | 12   | Pending Driver Reboot     | -- (informational only)          |
    +------+---------------------------+----------------------------------+

    Steps 2-10 are generated from $DriverClasses at runtime. Step 11's
    exclusion pattern is auto-built from all enabled class entries.

.PARAMETER DriverFilter
    Optional. Regex pattern that further narrows which devices within each class
    are checked. When omitted, all devices in each class are evaluated.
    Example: -DriverFilter 'Realtek' limits checks to Realtek-branded devices.

.PARAMETER AllowedActions
    Controls which remediation stages are permitted. Stages always run in the
    fixed order below, stopping as soon as the device's error clears:
        Scan      -- pnputil /scan-devices         (zero interruption)
        Restart   -- pnputil /restart-device       (~1-2 s device gap)
        Rollback  -- pnputil /rollback-driver      (previous version from driver store)
        Reinstall -- remove device + scan-devices  (Windows picks best available driver)
        Uninstall -- remove device, no re-enum     (strips the driver; crash-causing drivers)
    Default: Scan, Restart, Rollback
    Reinstall and Uninstall must be explicitly added -- they are more destructive.

.NOTES
    Script Name  : Invoke-AutoRemediateAllDriverIssues.ps1
    Version      : 3.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-28
    Timeout      : 120 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
param(
    # Optional regex pattern to further narrow which devices are checked within each class.
    [string]$DriverFilter = $env:DriverFilter,

    # Which remediation stages are permitted.
    [ValidateSet('Scan', 'Restart', 'Rollback', 'Reinstall', 'Uninstall')]
    [string[]]$AllowedActions = @('Scan', 'Restart', 'Rollback')
)

# Test-DriverMatch: returns $true when no filter is set, or when the device
# name matches the filter regex.
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

# -- Driver Class Definitions --------------------------------------------------
# Each entry defines one PnP device class to check and optionally remediate.
# To add coverage for a new class, add an entry here -- no step blocks needed.
#   Pattern        : regex matched against Win32_PnPEntity.Name
#   ExcludePattern : optional regex to filter out unwanted matches; $null to skip
#   Enabled        : $false skips this class entirely
#   Remediate      : $true calls Invoke-DriverEscalation; $false flags as Warning only
#   AbsentStatus   : result status when no devices of this class are enumerated
#   AbsentMessage  : result message when no devices are found
$DriverClasses = @(
    @{
        Name           = 'Audio'
        Pattern        = 'audio|sound|speaker|headset|realtek|conexant|IDT|Synaptics.*audio|Intel.*Smart Sound'
        ExcludePattern = $null
        Enabled        = $true
        Remediate      = $true
        AbsentStatus   = 'Warning'
        AbsentMessage  = 'No audio PnP devices found in hardware enumeration'
    }
    @{
        Name           = 'Bluetooth'
        Pattern        = 'Bluetooth'
        ExcludePattern = $null
        Enabled        = $true
        Remediate      = $true
        AbsentStatus   = 'Warning'
        AbsentMessage  = 'No Bluetooth PnP devices found -- adapter may not be present'
    }
    @{
        Name           = 'Network Adapter'
        Pattern        = 'ethernet|wi-?fi|wireless|network adapter|realtek.*gbe|intel.*ethernet|intel.*wi-?fi|broadcom.*netxtreme'
        ExcludePattern = 'tunnel|loopback|virtual|miniport|wan miniport'
        Enabled        = $true
        Remediate      = $true
        AbsentStatus   = 'Warning'
        AbsentMessage  = 'No physical network adapter PnP devices found'
    }
    @{
        Name           = 'GPU / Display'
        Pattern        = 'display adapter|video controller|nvidia|amd.*radeon|intel.*uhd|intel.*iris|geforce|quadro|firepro'
        ExcludePattern = 'microsoft basic display'
        Enabled        = $true
        Remediate      = $true
        AbsentStatus   = 'Passed'
        AbsentMessage  = 'No discrete GPU PnP devices found'
    }
    @{
        Name           = 'Storage Controller'
        Pattern        = 'ahci|nvme|sata.*controller|storage controller|raid controller|intel.*rst|amd.*raid|standard sata ahci'
        ExcludePattern = $null
        Enabled        = $true
        Remediate      = $true
        AbsentStatus   = 'Passed'
        AbsentMessage  = 'No storage controller PnP devices found'
    }
    @{
        Name           = 'Chipset / SMBus'
        Pattern        = 'smbus|system management bus|intel.*management engine|intel.*serial io|amd.*psp|amd.*gpio|chipset'
        ExcludePattern = $null
        Enabled        = $true
        Remediate      = $true
        AbsentStatus   = 'Passed'
        AbsentMessage  = 'No chipset / SMBus PnP devices found'
    }
    @{
        Name           = 'Touchpad / HID'
        Pattern        = 'touchpad|synaptics|alps|elan.*pointing|precision touchpad|hid-compliant.*pen'
        ExcludePattern = $null
        Enabled        = $true
        Remediate      = $true
        AbsentStatus   = 'Passed'
        AbsentMessage  = 'No touchpad / precision HID PnP devices found'
    }
    @{
        Name           = 'Webcam / Camera'
        Pattern        = 'camera|webcam|imaging device|usb.*camera|integrated camera|ir camera'
        ExcludePattern = $null
        Enabled        = $true
        Remediate      = $true
        AbsentStatus   = 'Passed'
        AbsentMessage  = 'No camera / webcam PnP devices found'
    }
    @{
        Name           = 'USB / Dock'
        Pattern        = 'usb.*host controller|xhci|thunderbolt|displaylink|usb.*dock|universal serial bus.*host'
        ExcludePattern = 'usb.*composite|usb.*hub'
        Enabled        = $true
        Remediate      = $true
        AbsentStatus   = 'Warning'
        AbsentMessage  = 'No USB host controller PnP devices found'
    }
)

# -- Step Definitions ----------------------------------------------------------
# Step 1 and the final two steps are static. Steps 2-N are generated from
# $DriverClasses above. To add a new device class, add an entry to the table.
$Steps = [System.Collections.Generic.List[hashtable]]::new()

# Step 1: Driver Store Scan (static) ------------------------------------------
$Steps.Add(@{
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
})

# Steps 2-N: Per-class driver health (generated from $DriverClasses) ----------
# GetNewClosure() binds $c at scriptblock creation time so each loop iteration
# captures its own class definition rather than sharing a single reference.
$classOrder = 2
foreach ($class in $DriverClasses | Where-Object { $_.Enabled }) {
    $c = $class
    $Steps.Add(@{
        Name             = "$($c.Name) Driver Health"
        Order            = $classOrder
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $all = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match $c.Pattern }
            if ($c.ExcludePattern) { $all = $all | Where-Object { $_.Name -notmatch $c.ExcludePattern } }
            $devices = $all | Where-Object { Test-DriverMatch $_.Name }
            if (-not $devices) {
                if ($all -and $script:DriverFilter) {
                    return @{ Status = 'Passed'; Message = "No $($c.Name) devices match filter '$($script:DriverFilter)' -- step skipped" }
                }
                return @{ Status = $c.AbsentStatus; Message = $c.AbsentMessage }
            }
            $errored = $devices | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
            if ($errored) {
                $names = ($errored | ForEach-Object { "$($_.Name) [code $($_.ConfigManagerErrorCode)]" }) -join '; '
                return @{ Status = 'Failed'; Message = "Driver error on: $names" }
            }
            return @{ Status = 'Passed'; Message = "Healthy $($c.Name) driver(s): $(($devices.Name) -join ', ')" }
        }.GetNewClosure()
        ResolutionScript = if ($c.Remediate) {
            {
                $errored = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
                           Where-Object { $_.Name -match $c.Pattern -and $_.ConfigManagerErrorCode -ne 0 }
                if ($c.ExcludePattern) { $errored = $errored | Where-Object { $_.Name -notmatch $c.ExcludePattern } }
                $errored = $errored | Where-Object { Test-DriverMatch $_.Name }
                if ($errored) {
                    $r = Invoke-DriverEscalation -InstanceIds ($errored.DeviceID) -AllowedActions $script:AllowedActions
                    if ($r.Unfixed) { $script:UnfixedDevices += $r.Unfixed }
                }
            }.GetNewClosure()
        } else { $null }
    })
    $classOrder++
}

# Step N+1: Uncovered Device Errors (dynamic catch-all) -----------------------
# Exclusion pattern is auto-built from all enabled $DriverClasses entries so it
# always covers exactly what the class table does not.
$coveredPattern = ($DriverClasses | Where-Object { $_.Enabled } | ForEach-Object { $_.Pattern }) -join '|'
$Steps.Add(@{
    Name             = 'Uncovered Device Errors'
    Order            = $classOrder
    Enabled          = $true
    ResolveOnWarning = $false
    DetectionScript  = {
        $uncovered = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.Name -notmatch $coveredPattern } |
            Where-Object { Test-DriverMatch $_.Name }
        if ($uncovered) {
            $names = ($uncovered | ForEach-Object { "$($_.Name) [code $($_.ConfigManagerErrorCode)]" }) -join '; '
            return @{ Status = 'Warning'; Message = "Errored device(s) outside covered classes: $names" }
        }
        return @{ Status = 'Passed'; Message = 'No uncovered device driver errors detected' }
    }.GetNewClosure()
    ResolutionScript = $null   # Flag only -- class is unknown so escalation is not safe
})
$classOrder++

# Step N+2: Pending Driver Reboot (static) ------------------------------------
$Steps.Add(@{
    Name             = 'Pending Driver Reboot'
    Order            = $classOrder
    Enabled          = $true
    ResolveOnWarning = $false   # Cannot auto-reboot without interrupting the user -- informational only
    DetectionScript  = {
        # PendingFileRenameOperations and the CBS/Session Manager reboot keys are the
        # standard signals that a driver or component install is waiting on a reboot.
        $cbsKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $smKey   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        $pfro    = (Get-ItemProperty -Path $smKey -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
        $cbsPend = Test-Path $cbsKey
        if ($cbsPend -or $pfro) {
            return @{ Status = 'Warning'; Message = 'A pending reboot was detected -- driver changes may require a restart to complete' }
        }
        return @{ Status = 'Passed'; Message = 'No pending reboot detected' }
    }
    ResolutionScript = $null   # Intentionally no auto-remediation -- reboot requires user scheduling
})


# -- Execution Engine ----------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$script:UnfixedDevices = @()
$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

$scopeLine   = if ($DriverFilter) { "Within-class filter: $DriverFilter" } else { 'All devices' }
$actionsLine = "Actions: $($AllowedActions -join ', ')"

Write-Host "`n-- Invoke-AutoRemediateAllDriverIssues --------------------------" -ForegroundColor Cyan
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

$allUnfixed = $script:UnfixedDevices | Where-Object { $_ }

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
