<#
.SYNOPSIS
    Invoke-AutoRemediateDriverIssues -- Targeted driver remediation for specific devices.

.DESCRIPTION
    Finds all PnP devices whose name matches -DriverFilter (a regex string) and that
    report a non-zero ConfigManagerErrorCode, then applies the escalating remediation
    sequence controlled by -AllowedActions. Stops as soon as each device's error clears.

    To scan and remediate all driver classes automatically, use
    Invoke-AutoRemediateAllDriverIssues.ps1 instead.

.PARAMETER DriverFilter
    Required. Regex pattern matched against Win32_PnPEntity.Name to select the
    target device(s). OR patterns work naturally:
        -DriverFilter 'Realtek'           -- any Realtek device
        -DriverFilter 'Realtek|Intel'     -- Realtek or Intel devices
        -DriverFilter 'NVIDIA.*Display'   -- NVIDIA display adapters

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
    Script Name  : Invoke-AutoRemediateDriverIssues.ps1
    Version      : 3.1.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-16
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Invoke-AutoRemediateDriverIssues {
param(
    # Regex pattern matched against PnP device names. Required.
    [string]$DriverFilter = $env:DriverFilter,

    # Which remediation stages are permitted.
    [ValidateSet('Scan', 'Restart', 'Rollback', 'Reinstall', 'Uninstall')]
    [string[]]$AllowedActions = @('Scan', 'Restart', 'Rollback')
)

# -- Input guard ---------------------------------------------------------------
if ([string]::IsNullOrEmpty($DriverFilter)) {
    Write-Error '-DriverFilter is required. Provide a regex pattern to match device names.'
    exit 1
}

# -- Escalating driver remediation helper --------------------------------------

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

# -- Device discovery ----------------------------------------------------------
Write-Output "`r`n-- Invoke-AutoRemediateDriverIssues -----------------------------"
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Filter: $DriverFilter"
Write-Output "   Actions: $($AllowedActions -join ', ')"
Write-Output '----------------------------------------------------------------'

$matched = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match $DriverFilter }

if (-not $matched) {
    Write-Output "`r`n  [WARNING] No PnP devices found matching '$DriverFilter'"
    Write-Output '----------------------------------------------------------------'
    Write-Output ''
    exit 0
}

# @() guards: a single WMI object has no .Count in Windows PowerShell 5.1.
Write-Output "`r`n  Matched $(@($matched).Count) device(s):"
$matched | ForEach-Object {
    $errCode = $_.ConfigManagerErrorCode
    $label   = if ($errCode -eq 0) { 'OK  ' } else { "ERR $errCode" }
    Write-Output "    [$label] $($_.Name)"
}

$errored = $matched | Where-Object { $_.ConfigManagerErrorCode -ne 0 }

if (-not $errored) {
    Write-Output "`r`n  All matched device(s) are healthy -- no remediation needed."
    Write-Output "`r`n----------------------------------------------------------------"
    Write-Output ''
    exit 0
}

# -- Remediation ---------------------------------------------------------------
Write-Output "`r`n  Running escalation on $(@($errored).Count) errored device(s)..."
$result = Invoke-DriverEscalation -InstanceIds ($errored.DeviceID) -AllowedActions $AllowedActions

# -- Summary -------------------------------------------------------------------
Write-Output "`r`n----------------------------------------------------------------"

if ($result.Fixed) {
    Write-Output "  Fixed   ($($result.Fixed.Count)): $($result.Fixed -join ', ')"
}
if ($result.Unfixed) {
    Write-Output "  Unfixed ($($result.Unfixed.Count)): $($result.Unfixed -join ', ')"
    Write-Output "`r`n  [NOTICE] The following device(s) could not be resolved without a reboot:"
    $result.Unfixed | ForEach-Object {
        $why = if ($result.Notes[$_]) { "  ($($result.Notes[$_]))" } else { '' }
        Write-Output "           $_$why"
    }
    Write-Output '----------------------------------------------------------------'
    Write-Output ''
    exit 2
}

Write-Output "`r`n----------------------------------------------------------------"
Write-Output ''
exit 0
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw. Inputs arrive as environment
# variables and are bound to the function's parameters below.
#
# @args forwards any command-line arguments (for example -DriverFilter and
# -AllowedActions from the break-test harness or a local console run) to the function
# as named parameters. Under UEM $args is empty, so the environment-variable defaults
# apply unchanged.

Invoke-AutoRemediateDriverIssues @args
Exit 0
