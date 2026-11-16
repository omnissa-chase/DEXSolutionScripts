<#
.SYNOPSIS
    Clear-ShadowCopies -- deletes old restore points (shadow copies) on the system drive,
    keeps the newest, and can cap the space they are allowed to use. Takes no input.

.DESCRIPTION
    System Restore and Previous Versions keep shadow copies of the system drive, and by
    default they may grow to a share of the disk that a small drive cannot spare. This
    script is that branch of the disk cleanup playbook. Pair it with the
    disk_shadowcopy_mb sensor and run it when that value is over the threshold the
    admin chooses.

    What it does:
      * Deletes the restore points on the system drive except the newest KeepNewest.
        Only persistent, client-accessible shadow copies are touched: that is what
        System Restore and Previous Versions create. A snapshot a backup product is
        using right now is a different kind and is left alone.
      * When MaxStoragePercent is set, lowers the limit on shadow storage to that share
        of the drive, so the space does not fill again. Off by default: changing the
        limit is a policy decision.

    Deleting a restore point removes the option to restore the system to that date.
    The newest one is kept so a restore stays possible.

.NOTES
    Script Name  : Clear-ShadowCopies.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Timeout      : 120 seconds
    Reporting    : HKLM:\Software\AirWatch\Extensions\DiskState (ShadowCopyMb, LastShadowCopy* values)

    No input. Settings are the constants in the SETTINGS block. Optional environment
    variable WhatIf (true = report only).

    Exit codes: 0 = done (including "nothing to delete" and "below the minimum");
    1 = not elevated.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# ==============================================================================
# SETTINGS -- edit here; there are no script variables to pass.
# ==============================================================================
$KeepNewest        = 1   # restore points to keep on the system drive (0 = delete all)
$MinTotalMb        = 0   # do nothing unless shadow copies use at least this (0 = always run; the playbook condition on disk_shadowcopy_mb is the usual gate)
$MaxStoragePercent = 0   # 0 = leave the storage limit alone; 1-50 = cap shadow storage at this share of the drive
# ==============================================================================

$SCRIPT_VERSION = '1.0.0'
$CachePath      = 'HKLM:\Software\AirWatch\Extensions\DiskState'
$whatIf = "$env:WhatIf" -match '^(?i)(true|1|yes)$'
$sys = [string]$env:SystemDrive

function ConvertTo-Mb { param([long]$Bytes) return [int][math]::Round($Bytes / 1MB) }

function Get-UsedBytes {
    # Space used by shadow copies, all volumes (what the collector reports). -1 when it cannot be read.
    try {
        $s = [long]0
        foreach ($x in @(Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction Stop)) { $s += [long]$x.UsedSpace }
        return $s
    } catch { return [long]-1 }
}

Write-Output "-- Clear-ShadowCopies $SCRIPT_VERSION$(if ($whatIf) { ' [WhatIf]' }) ------------------------------"

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output '  Not elevated: run as SYSTEM or an administrator.'
    exit 1
}

# -- 1. what is there ---------------------------------------------------------------
$usedBefore = Get-UsedBytes
$volume = $null
try { $volume = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$sys'" -ErrorAction Stop } catch { }
$copies = @()
if ($volume) {
    try {
        $copies = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop |
            Where-Object { $_.VolumeName -eq $volume.DeviceID -and $_.Persistent -and $_.ClientAccessible } | Sort-Object InstallDate -Descending)
    } catch { Write-Output "  Shadow copies could not be listed: $($_.Exception.Message)" }
}
$delete = @($copies | Select-Object -Skip ([math]::Max(0, $KeepNewest)))
Write-Output "  Shadow copies use $(if ($usedBefore -ge 0) { "$(ConvertTo-Mb $usedBefore) MB" } else { 'an unknown amount' }). Restore points on ${sys}: $($copies.Count); to delete: $($delete.Count); to keep: $($copies.Count - $delete.Count)."

$v = [ordered]@{ LastShadowCopyCleanupAt = (Get-Date -Format 's'); LastShadowCopyCleanupVersion = $SCRIPT_VERSION; LastShadowCopyDeleted = 0; LastShadowCopyFreedMb = 0 }
function Save-AndExit {
    param([string]$Status)
    $v['LastShadowCopyCleanupStatus'] = $Status
    try {
        if (-not (Test-Path $CachePath)) { New-Item -Path $CachePath -Force -ErrorAction Stop | Out-Null }
        foreach ($k in $v.Keys) { Set-ItemProperty -Path $CachePath -Name $k -Value ([string]$v[$k]) -Type String -ErrorAction Stop }
    } catch { Write-Output "  Cache not updated: $($_.Exception.Message)" }
    exit 0
}
if ($usedBefore -ge 0) { $v['ShadowCopyMb'] = ConvertTo-Mb $usedBefore }

if ($usedBefore -ge 0 -and (ConvertTo-Mb $usedBefore) -lt $MinTotalMb) {
    Write-Output "  Below the $MinTotalMb MB minimum (MinTotalMb). Nothing done."
    Save-AndExit 'BelowMinimum'
}

if ($whatIf) {
    foreach ($c in $delete) { Write-Output "  Would delete the restore point of $($c.InstallDate.ToString('yyyy-MM-dd HH:mm')) (WhatIf)" }
    if ($MaxStoragePercent -gt 0) { Write-Output "  Would cap shadow storage on $sys at $MaxStoragePercent% of the drive (WhatIf)" }
    Write-Output "  WhatIf: would delete $($delete.Count) restore point(s). Nothing was changed."
    Save-AndExit 'WhatIf'
}

# -- 2. delete the old restore points ---------------------------------------------------
$deleted = 0; $failed = 0
foreach ($c in $delete) {
    try {
        Remove-CimInstance -InputObject $c -ErrorAction Stop
        $deleted++
        Write-Output "  Deleted the restore point of $($c.InstallDate.ToString('yyyy-MM-dd HH:mm'))."
    } catch {
        $failed++
        Write-Output "  Could not delete the restore point of $($c.InstallDate.ToString('yyyy-MM-dd HH:mm')): $($_.Exception.Message)"
    }
}

# -- 3. cap the storage, when asked -------------------------------------------------------
if ($MaxStoragePercent -gt 0) {
    $pct = [math]::Min(50, [math]::Max(1, [int]$MaxStoragePercent))
    try {
        $out = & "$env:windir\System32\vssadmin.exe" resize shadowstorage /for=$sys /on=$sys /maxsize=$pct% 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { Write-Output "  Shadow storage on $sys capped at $pct% of the drive." }
        else { Write-Output "  The storage limit could not be changed (vssadmin exit $LASTEXITCODE): $($out.Trim() -replace '\s+', ' ')" }
    } catch { Write-Output "  The storage limit could not be changed: $($_.Exception.Message)" }
}

# -- 4. report and refresh the cache ---------------------------------------------------
$usedAfter = Get-UsedBytes
$freedMb = if ($usedBefore -ge 0 -and $usedAfter -ge 0) { [math]::Max(0, (ConvertTo-Mb ($usedBefore - $usedAfter))) } else { 0 }
if ($usedAfter -ge 0) { $v['ShadowCopyMb'] = ConvertTo-Mb $usedAfter }
$v['LastShadowCopyDeleted'] = $deleted; $v['LastShadowCopyFreedMb'] = $freedMb
Write-Output "  Deleted $deleted restore point(s)$(if ($failed) { "; $failed could not be deleted" }); kept $($copies.Count - $delete.Count). About $freedMb MB freed. Shadow copies now use $(if ($usedAfter -ge 0) { "$(ConvertTo-Mb $usedAfter) MB" } else { 'an unknown amount' })."
Save-AndExit $(if ($failed) { 'Partial' } elseif ($delete.Count -eq 0) { 'NothingToDelete' } else { 'Completed' })
