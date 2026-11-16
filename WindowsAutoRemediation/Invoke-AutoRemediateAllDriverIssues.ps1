<#
.SYNOPSIS
    Invoke-AutoRemediateAllDriverIssues -- Automated full-sweep driver diagnostic and remediation.

.DESCRIPTION
    Scans all defined PnP device classes for driver error codes and applies an
    escalating remediation sequence controlled by -AllowedActions. Device classes
    are defined in the $DriverClasses table; adding or removing a class requires
    only a single table entry -- no step blocks need to be touched. Every errored
    device that fits none of the named classes is still remediated, grouped by its
    PnP class (step 11), except the classes listed in $NeverRemediateClasses, which
    are flagged only.

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
    | 11   | Other Device Errors       | Failed (any other PnP class)     |
    | 12   | Pending Driver Reboot     | -- (informational only)          |
    +------+---------------------------+----------------------------------+

    Steps 2-10 are generated from $DriverClasses at runtime. Step 11's
    exclusion pattern is auto-built from all enabled class entries, so it
    covers exactly the devices the table does not.

.PARAMETER DriverFilter
    Optional. Regex pattern that further narrows which devices within each class
    are checked. When omitted, all devices in each class are evaluated.
    Example: -DriverFilter 'Realtek' limits checks to Realtek-branded devices.

.PARAMETER AllowedActions
    Controls which remediation stages are permitted. Stages always run in the
    fixed order below, stopping as soon as the device's error clears:
        Scan      -- pnputil /scan-devices         (zero interruption)
        Restart   -- pnputil /restart-device       (~1-2 s device gap)
        Rollback  -- DiRollbackDriver (newdev.dll)  (Device Manager's "Roll Back Driver":
                     previous package from the driver store; pnputil has no such verb)
        Reinstall -- remove device + scan-devices  (Windows picks best available driver)
        Uninstall -- remove device, no re-enum     (strips the driver; crash-causing drivers)
    Default: Scan, Restart, Rollback
    Reinstall and Uninstall must be explicitly added -- they are more destructive.

.NOTES
    Script Name  : Invoke-AutoRemediateAllDriverIssues.ps1
    Version      : 3.1.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-16
    Timeout      : 120 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Invoke-AutoRemediateAllDriverIssues {
param(
    # Optional regex pattern to further narrow which devices are checked within each class.
    [string]$DriverFilter = $env:DriverFilter,

    # Which remediation stages are permitted.
    [ValidateSet('Scan', 'Restart', 'Rollback', 'Reinstall', 'Uninstall')]
    [string[]]$AllowedActions = @('Scan', 'Restart', 'Rollback')
)

# Test-DriverMatch: returns $true when no filter is set, or when the device
# name matches the filter regex. $DriverFilter resolves via dynamic scoping to
# the enclosing function's parameter (there is no script-scope copy of it).
function Test-DriverMatch {
    param([string]$Name)
    if (-not $DriverFilter) { return $true }
    return $Name -match $DriverFilter
}

# Invoke-DriverRollback: Device Manager's "Roll Back Driver" for one device instance,
# through DiRollbackDriver in newdev.dll (pnputil has no rollback verb; the old
# /rollback-driver call printed the usage text and changed nothing). Returns 0 when
# the previous driver package was reinstalled, 259 (ERROR_NO_MORE_ITEMS) when there
# is no previous package, any other Win32 error code otherwise, -1 when the API could
# not be reached. The type is compiled once per session; a DexDriverRollback type that
# already exists (the unit-test kit registers a fake) is used as is.
function Invoke-DriverRollback {
    param([string]$InstanceId)
    try {
        if (-not ('DexDriverRollback' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DexDriverRollback {
    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr classGuid, IntPtr hwndParent);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiOpenDeviceInfo(IntPtr set, string instanceId, IntPtr hwndParent, int flags, ref SP_DEVINFO_DATA data);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("newdev.dll", SetLastError = true)]
    static extern bool DiRollbackDriver(IntPtr set, ref SP_DEVINFO_DATA data, IntPtr hwndParent, int flags, out bool needReboot);
    public static bool NeedReboot;
    public static int Rollback(string instanceId) {
        IntPtr set = SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
        if (set == IntPtr.Zero || set == new IntPtr(-1)) return Marshal.GetLastWin32Error();
        try {
            SP_DEVINFO_DATA d = new SP_DEVINFO_DATA();
            d.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            if (!SetupDiOpenDeviceInfo(set, instanceId, IntPtr.Zero, 0, ref d)) return Marshal.GetLastWin32Error();
            bool reboot;
            if (!DiRollbackDriver(set, ref d, IntPtr.Zero, 1, out reboot)) return Marshal.GetLastWin32Error();   // 1 = ROLLBACK_FLAG_NO_UI
            NeedReboot = reboot;
            return 0;
        } finally { SetupDiDestroyDeviceInfoList(set); }
    }
}
'@ -ErrorAction Stop
        }
        return [int][DexDriverRollback]::Rollback($InstanceId)
    } catch {
        return -1
    }
}

function Invoke-DriverEscalation {
    param(
        [string[]]$InstanceIds,
        [string[]]$AllowedActions
    )

    $fixed   = @()
    $unfixed = @()
    $notes   = @{}

    foreach ($id in $InstanceIds) {

        # Stage: Scan -- re-enumerate the PnP bus; Windows may auto-reinstall a cached
        # driver. Zero user interruption; safest possible action.
        if ('Scan' -in $AllowedActions) {
            pnputil /scan-devices 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            $dev = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
                   Where-Object { $_.DeviceID -eq $id }
            if ($dev -and $dev.ConfigManagerErrorCode -eq 0) { $fixed += $id; continue }
        }

        # Stage: Restart -- disable then re-enable the device, forcing the driver to
        # fully reload. Causes a ~1-2 s device gap; no user dialog.
        if ('Restart' -in $AllowedActions) {
            pnputil /restart-device "$id" 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            $dev = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
                   Where-Object { $_.DeviceID -eq $id }
            if ($dev -and $dev.ConfigManagerErrorCode -eq 0) { $fixed += $id; continue }
        }

        # Stage: Rollback -- reinstall the previously installed driver package from the
        # driver store (DiRollbackDriver, the same call Device Manager makes). Does
        # nothing when no previous package exists; the reason is carried to the summary.
        if ('Rollback' -in $AllowedActions) {
            $rc = Invoke-DriverRollback -InstanceId $id
            if ($rc -eq 0) {
                Start-Sleep -Seconds 5
                $dev = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
                       Where-Object { $_.DeviceID -eq $id }
                if ($dev -and $dev.ConfigManagerErrorCode -eq 0) { $fixed += $id; continue }
                $notes[$id] = 'rolled back, error persists'
            } elseif ($rc -eq 259) { $notes[$id] = 'no previous driver to roll back to' }
            elseif ($rc -eq -1)    { $notes[$id] = 'driver rollback API unavailable' }
            else                   { $notes[$id] = "rollback failed, Win32 error $rc" }
        }

        # Stage: Reinstall -- remove the device from the PnP tree then trigger Windows
        # to re-enumerate and install the best matching driver from the local store.
        # The instance ID is location-based and typically survives the remove + scan cycle.
        if ('Reinstall' -in $AllowedActions) {
            pnputil /remove-device "$id" 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            pnputil /scan-devices 2>&1 | Out-Null
            Start-Sleep -Seconds 5
            $dev = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
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

    return @{ Fixed = $fixed; Unfixed = $unfixed; Notes = $notes }
}

# Get-OtherErroredDevices: every present device with a PnP error whose name matches
# none of the $DriverClasses patterns, with its PnP class (Unknown when Windows has
# none for it, the "Other devices" branch of Device Manager).
function Get-OtherErroredDevices {
    Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.Name -notmatch $coveredPattern -and $_.Present -ne $false } |
        Where-Object { Test-DriverMatch $_.Name } |
        ForEach-Object {
            [pscustomobject]@{
                Name                   = $_.Name
                DeviceID               = $_.DeviceID
                ConfigManagerErrorCode = $_.ConfigManagerErrorCode
                PnpClass               = $(if ($_.PNPClass) { [string]$_.PNPClass } else { 'Unknown' })
            }
        }
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
        $count = @($out | Select-String 'Published Name').Count
        return @{ Status = 'Passed'; Message = "$count OEM driver package(s) in driver store" }
    }
    ResolutionScript = {
        # Trigger a full hardware re-enumeration -- safest possible driver operation
        pnputil /scan-devices 2>&1 | Out-Null
    }
})

# Steps 2-N: Per-class driver health (generated from $DriverClasses) ----------
# Each class definition is stored on the step (Class) and handed to the
# scriptblocks as a parameter by the execution engine. Do NOT use
# GetNewClosure() here: a closure runs inside a new dynamic module whose scope
# cannot see functions defined in this function (Test-DriverMatch,
# Invoke-DriverEscalation) when the script is run as a file, e.g. by the
# Workspace ONE script engine.
$classOrder = 2
foreach ($class in $DriverClasses | Where-Object { $_.Enabled }) {
    $Steps.Add(@{
        Name             = "$($class.Name) Driver Health"
        Order            = $classOrder
        Enabled          = $true
        ResolveOnWarning = $false
        Class            = $class
        DetectionScript  = {
            param([hashtable]$c)
            $all = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match $c.Pattern }
            if ($c.ExcludePattern) { $all = $all | Where-Object { $_.Name -notmatch $c.ExcludePattern } }
            $devices = $all | Where-Object { Test-DriverMatch $_.Name }
            if (-not $devices) {
                if ($all -and $DriverFilter) {
                    return @{ Status = 'Passed'; Message = "No $($c.Name) devices match filter '$DriverFilter' -- step skipped" }
                }
                return @{ Status = $c.AbsentStatus; Message = $c.AbsentMessage }
            }
            $errored = $devices | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
            if ($errored) {
                $names = ($errored | ForEach-Object { "$($_.Name) [code $($_.ConfigManagerErrorCode)]" }) -join '; '
                return @{ Status = 'Failed'; Message = "Driver error on: $names" }
            }
            return @{ Status = 'Passed'; Message = "Healthy $($c.Name) driver(s): $(($devices.Name) -join ', ')" }
        }
        ResolutionScript = if ($class.Remediate) {
            {
                param([hashtable]$c)
                $errored = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
                           Where-Object { $_.Name -match $c.Pattern -and $_.ConfigManagerErrorCode -ne 0 }
                if ($c.ExcludePattern) { $errored = $errored | Where-Object { $_.Name -notmatch $c.ExcludePattern } }
                $errored = $errored | Where-Object { Test-DriverMatch $_.Name }
                if ($errored) {
                    $r = Invoke-DriverEscalation -InstanceIds ($errored.DeviceID) -AllowedActions $AllowedActions
                    if ($r.Unfixed) { $UnfixedDevices.AddRange([string[]]$r.Unfixed) }
                    foreach ($k in $r.Notes.Keys) { $UnfixedNotes[$k] = $r.Notes[$k] }
                }
            }
        } else { $null }
    })
    $classOrder++
}

# Step N+1: Other Device Errors (every remaining PnP class) --------------------
# The exclusion pattern is auto-built from all enabled $DriverClasses entries, so
# this step covers exactly what the class table does not. Errored devices here get
# the same escalation as the named classes, grouped by their PnP class, so a fault
# is never left alone just because the device fits no category. Classes matching
# $NeverRemediateClasses are flagged only: restarting or rolling back the system,
# processor, volume, firmware or security (TPM) devices is not a safe unattended
# action, and a software component carries no driver worth touching.
$coveredPattern = ($DriverClasses | Where-Object { $_.Enabled } | ForEach-Object { $_.Pattern }) -join '|'
$NeverRemediateClasses = '^(System|Processor|Computer|Volume|VolumeSnapshot|SecurityDevices|Firmware|SoftwareComponent|SoftwareDevice|DiskDrive)$'
$Steps.Add(@{
    Name             = 'Other Device Errors'
    Order            = $classOrder
    Enabled          = $true
    ResolveOnWarning = $false
    DetectionScript  = {
        $other = @(Get-OtherErroredDevices)
        if (-not $other) { return @{ Status = 'Passed'; Message = 'No driver errors outside the named classes' } }
        # Code 28 is "no driver installed": nothing to scan, restart or roll back, so it is
        # reported, not escalated (a VMware guest typically shows two such ghost devices).
        $noDrv = @($other | Where-Object { $_.ConfigManagerErrorCode -eq 28 })
        $rest  = @($other | Where-Object { $_.ConfigManagerErrorCode -ne 28 })
        $act   = @($rest | Where-Object { $_.PnpClass -notmatch $NeverRemediateClasses })
        $flag  = @($rest | Where-Object { $_.PnpClass -match $NeverRemediateClasses })
        $desc  = { param($d) "$($d.Name) [$($d.PnpClass), code $($d.ConfigManagerErrorCode)]" }
        $parts = @()
        if ($act)   { $parts += "Driver error on: $(($act | ForEach-Object { & $desc $_ }) -join '; ')" }
        if ($flag)  { $parts += "Flagged only (class never remediated unattended): $(($flag | ForEach-Object { & $desc $_ }) -join '; ')" }
        if ($noDrv) { $parts += "No driver installed (needs a driver package, not a remediation): $(($noDrv | ForEach-Object { & $desc $_ }) -join '; ')" }
        return @{ Status = $(if ($act) { 'Failed' } else { 'Warning' }); Message = ($parts -join '. ') }
    }
    ResolutionScript = {
        $act = @(Get-OtherErroredDevices | Where-Object { $_.ConfigManagerErrorCode -ne 28 -and $_.PnpClass -notmatch $NeverRemediateClasses })
        if ($act) {
            $r = Invoke-DriverEscalation -InstanceIds ($act.DeviceID) -AllowedActions $AllowedActions
            if ($r.Unfixed) { $UnfixedDevices.AddRange([string[]]$r.Unfixed) }
            foreach ($k in $r.Notes.Keys) { $UnfixedNotes[$k] = $r.Notes[$k] }
        }
    }
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

$UnfixedDevices = [System.Collections.Generic.List[string]]::new()
$UnfixedNotes   = @{}   # instance id -> why the Rollback stage could not help (printed under the NOTICE)
$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

$scopeLine   = if ($DriverFilter) { "Within-class filter: $DriverFilter" } else { 'All devices' }
$actionsLine = "Actions: $($AllowedActions -join ', ')"

Write-Output "`r`n-- Invoke-AutoRemediateAllDriverIssues --------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   $scopeLine"
Write-Output "   $actionsLine"
Write-Output '----------------------------------------------------------------'

foreach ($step in $activeSteps) {

    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''

    # -- Detection ------------------------------------------------------------
    try {
        $result  = & $step.DetectionScript $step.Class
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
            & $step.ResolutionScript $step.Class | Out-Null
            $remediated = $true
        } catch {
            $remError = $_.Exception.Message
        }
    }

    # -- Output ---------------------------------------------------------------
    $remNote = if ($remediated)   { '  -> Remediation ran' }
               elseif ($remError) { "  -> Remediation ERROR: $remError" }
               else               { '' }

    Write-Output "`r`n  [$($status.PadRight(7))] $($step.Name): $message$remNote"

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
# @() guards: in Windows PowerShell 5.1 a single PSCustomObject has no .Count, so a
# lone Failed step would otherwise yield $null here and the script would exit 0.
$passed   = @($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = @($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = @($results | Where-Object { $_.Remediated }).Count

Write-Output "`r`n----------------------------------------------------------------"
Write-Output "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"

$allUnfixed = $UnfixedDevices | Where-Object { $_ }

if ($allUnfixed) {
    Write-Output "`r`n  [NOTICE] The following device(s) could not be resolved without a reboot:"
    $allUnfixed | ForEach-Object {
        $why = if ($UnfixedNotes[$_]) { "  ($($UnfixedNotes[$_]))" } else { '' }
        Write-Output "           $_$why"
    }
    Write-Output '----------------------------------------------------------------'
    Write-Output ''
    exit 2   # Distinct exit code: partial remediation, reboot recommended
}

Write-Output "`r`n----------------------------------------------------------------"
Write-Output ''

if ($failed -gt 0) { exit 1 }
exit 0
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw. Inputs arrive as environment
# variables and are bound to the function's parameters below.
#
# @args forwards any command-line arguments (for example -AllowedActions from the
# break-test harness or a local console run) to the function as named parameters.
# Under UEM $args is empty, so the environment-variable defaults apply unchanged.

Invoke-AutoRemediateAllDriverIssues @args
Exit 0
