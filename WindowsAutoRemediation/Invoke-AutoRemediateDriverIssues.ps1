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
        Rollback  -- pnputil /rollback-driver      (previous version from driver store)
        Reinstall -- remove device + scan-devices  (Windows picks best available driver)
        Uninstall -- remove device, no re-enum     (strips the driver; crash-causing drivers)
    Default: Scan, Restart, Rollback
    Reinstall and Uninstall must be explicitly added -- they are more destructive.

.NOTES
    Script Name  : Invoke-AutoRemediateDriverIssues.ps1
    Version      : 3.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-28
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
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

# -- Device discovery ----------------------------------------------------------
Write-Host "`n-- Invoke-AutoRemediateDriverIssues -----------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Filter: $DriverFilter"
Write-Host "   Actions: $($AllowedActions -join ', ')"
Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan

$matched = Get-WmiObject -Class Win32_PnPEntity -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match $DriverFilter }

if (-not $matched) {
    Write-Host "`n  [WARNING] No PnP devices found matching '$DriverFilter'" -ForegroundColor Yellow
    Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ''
    exit 0
}

Write-Host "`n  Matched $($matched.Count) device(s):"
$matched | ForEach-Object {
    $errCode = $_.ConfigManagerErrorCode
    $label   = if ($errCode -eq 0) { 'OK  ' } else { "ERR $errCode" }
    $color   = if ($errCode -eq 0) { 'Green' } else { 'Red' }
    Write-Host "    [$label] $($_.Name)" -ForegroundColor $color
}

$errored = $matched | Where-Object { $_.ConfigManagerErrorCode -ne 0 }

if (-not $errored) {
    Write-Host "`n  All matched device(s) are healthy -- no remediation needed." -ForegroundColor Green
    Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host ''
    exit 0
}

# -- Remediation ---------------------------------------------------------------
Write-Host "`n  Running escalation on $($errored.Count) errored device(s)..." -ForegroundColor Yellow
$result = Invoke-DriverEscalation -InstanceIds ($errored.DeviceID) -AllowedActions $AllowedActions

# -- Summary -------------------------------------------------------------------
Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan

if ($result.Fixed) {
    Write-Host "  Fixed   ($($result.Fixed.Count)): $($result.Fixed -join ', ')" -ForegroundColor Green
}
if ($result.Unfixed) {
    Write-Host "  Unfixed ($($result.Unfixed.Count)): $($result.Unfixed -join ', ')" -ForegroundColor Red
    Write-Host "`n  [NOTICE] The following device(s) could not be resolved without a reboot:" -ForegroundColor Yellow
    $result.Unfixed | ForEach-Object { Write-Host "           $_" -ForegroundColor Yellow }
    Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ''
    exit 2
}

Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ''
exit 0