<#
.SYNOPSIS
    Clear-InstallerOrphans -- finds the cached installer files in %windir%\Installer that
    no installed product or patch uses any more, reports them, and deletes them only
    when that has been approved. Takes no input.

.DESCRIPTION
    Windows Installer keeps a copy of every .msi and .msp it installs in
    %windir%\Installer, because repair, change and uninstall need it. When a product is
    upgraded or removed its copy is not always removed with it, and on a device that
    updates the same products for years those orphans add up to gigabytes. This script
    is that branch of the disk cleanup playbook. Pair it with the
    disk_installer_orphans_mb sensor.

    Deleting a file here that a product still needs breaks that product's repair and
    uninstall, so the script is careful and off by default:
      * Report only until approved. Without ConfirmDelete (or the script variable
        ConfirmHighImpact = true) it lists the orphans and changes nothing.
      * An orphan is a top-level .msi or .msp that no product or patch of any user is
        registered to (LocalPackage under Installer\UserData, 64-bit registry view).
      * Windows Installer is asked the same question, and every file it names is kept.
        When it cannot be asked, nothing is deleted.
      * A file stays until it has been in the folder MinAgeDays (30).
      * Nothing is deleted while an installation is in progress.
      * When no registration at all can be read, nothing is called an orphan.
    Folders ($PatchCache$, the icon folders) and other file types are never touched.
    Every deleted file is written to
    %ProgramData%\AirWatch\Extensions\DiskState\installer-orphans.log.

.NOTES
    Script Name  : Clear-InstallerOrphans.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-17
    Timeout      : 120 seconds
    Reporting    : HKLM:\Software\AirWatch\Extensions\DiskState (InstallerOrphansMb, LastInstallerOrphan* values)

    No input. Settings are the constants in the SETTINGS block. Optional environment
    variables: WhatIf (true = report only, wins over everything) and ConfirmHighImpact
    (true = delete; the same switch as ConfirmDelete, for a second copy of the script
    in the console that is the approved one).

    Exit codes: 0 = done (including report only, nothing to delete and every refusal);
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
$ConfirmDelete = $false   # false = report only. true = delete the orphans (the approval switch)
$MinAgeDays    = 30       # leave a file alone until it has been in the Installer folder this many days
$MinTotalMb    = 0        # do nothing unless the orphans total at least this (0 = always; the playbook condition on disk_installer_orphans_mb is the usual gate)
$NameFilter    = '*'      # file name wildcard; leave at * (the break test narrows a run to its own files)
# ==============================================================================

$SCRIPT_VERSION = '1.0.0'
$CachePath      = 'HKLM:\Software\AirWatch\Extensions\DiskState'
$LogFile        = "$env:ProgramData\AirWatch\Extensions\DiskState\installer-orphans.log"
$whatIf = "$env:WhatIf" -match '^(?i)(true|1|yes)$'
$confirmed = [bool]$ConfirmDelete
if ($env:ConfirmHighImpact) { try { $confirmed = [System.Convert]::ToBoolean($env:ConfirmHighImpact) } catch { $confirmed = $false } }

function ConvertTo-Mb { param([long]$Bytes) return [int][math]::Round($Bytes / 1MB) }

#region SHARED BLOCK msi-v1 -- identical in Clear-InstallerOrphans.ps1 and disk_installer_orphans_mb.ps1
function Get-InstallerOrphans {
    # Top-level .msi and .msp files in %windir%\Installer that no product or patch of any
    # user is registered to. Ok is false when the registrations cannot be read or there
    # are none: then nothing may be called an orphan. Orphans are FileInfo objects, old
    # enough (created and last written more than MinAgeDays ago) and matching NameFilter.
    param([int]$MinAgeDays = 30, [string]$NameFilter = '*')
    $r = @{ Ok = $false; Reason = ''; Registered = 0; Files = 0; FileBytes = [long]0; Young = 0; Orphans = @(); OrphanBytes = [long]0 }
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
        $ud = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData')
        if (-not $ud) { $r.Reason = 'NoRegistrations'; return $r }
        $reg = @{}
        foreach ($sid in $ud.GetSubKeyNames()) {
            foreach ($kind in 'Products', 'Patches') {
                $k = $ud.OpenSubKey("$sid\$kind")
                if (-not $k) { continue }
                foreach ($code in $k.GetSubKeyNames()) {
                    $p = $k.OpenSubKey($(if ($kind -eq 'Products') { "$code\InstallProperties" } else { $code }))
                    if (-not $p) { continue }
                    $local = [string]$p.GetValue('LocalPackage')
                    if ($local) { $reg[[IO.Path]::GetFileName($local).ToLowerInvariant()] = $true }
                }
            }
        }
        $r.Registered = $reg.Count
        if ($reg.Count -eq 0) { $r.Reason = 'NoRegistrations'; return $r }
        $dir = "$env:windir\Installer"
        if (-not [IO.Directory]::Exists($dir)) { $r.Ok = $true; return $r }
        $cut = (Get-Date).AddDays(-$MinAgeDays)
        $found = New-Object System.Collections.Generic.List[object]
        foreach ($f in (New-Object System.IO.DirectoryInfo $dir).GetFiles()) {
            if ($f.Extension -notmatch '^(?i)\.(msi|msp)$') { continue }
            $r.Files++; $r.FileBytes += $f.Length
            if ($reg.ContainsKey($f.Name.ToLowerInvariant())) { continue }
            if ($f.Name -notlike $NameFilter) { continue }
            if ($f.CreationTime -gt $cut -or $f.LastWriteTime -gt $cut) { $r.Young++; continue }
            $found.Add($f); $r.OrphanBytes += $f.Length
        }
        $r.Orphans = $found.ToArray()
        $r.Ok = $true
    } catch { $r.Reason = "Error: $($_.Exception.Message)" }
    return $r
}
#endregion

function Get-ComValue { param($Object, [string]$Name, [object[]]$Arguments) return $Object.GetType().InvokeMember($Name, 'GetProperty', $null, $Object, $Arguments) }

function Get-InstallerSecondOpinion {
    # Asks Windows Installer itself which cached files it uses. Returns the lower-case file
    # names, or $null when it cannot be asked.
    param($Installer)
    $names = @{}
    $products = $null
    foreach ($sid in 's-1-1-0', '') {   # every user; then this user and the machine, which is what a non-admin may ask
        try { $products = Get-ComValue $Installer 'ProductsEx' @('', $sid, 7); break } catch { $products = $null }
    }
    if ($null -eq $products) { return $null }
    $count = 0
    foreach ($p in $products) {
        $count++
        try { $local = [string](Get-ComValue $p 'InstallProperty' @('LocalPackage')); if ($local) { $names[[IO.Path]::GetFileName($local).ToLowerInvariant()] = $true } } catch { }
    }
    if ($count -eq 0) { return $null }
    foreach ($sid in 's-1-1-0', '') {
        try {
            foreach ($p in (Get-ComValue $Installer 'PatchesEx' @('', $sid, 7, 15))) {
                try { $local = [string](Get-ComValue $p 'PatchProperty' @('LocalPackage')); if ($local) { $names[[IO.Path]::GetFileName($local).ToLowerInvariant()] = $true } } catch { }
            }
            break
        } catch { }
    }
    return $names
}

function Test-InstallRunning {
    # An installation in progress: its InProgress key, or the mutex Windows Installer holds while it works.
    try { if ([Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64').OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress')) { return $true } } catch { }
    try { $m = [System.Threading.Mutex]::OpenExisting('Global\_MSIExecute'); $m.Close(); return $true }
    catch [System.Threading.WaitHandleCannotBeOpenedException] { return $false }
    catch { return $true }   # it exists and may not be opened: an installation owns it
}

Write-Output "-- Clear-InstallerOrphans $SCRIPT_VERSION$(if ($whatIf) { ' [WhatIf]' }) ------------------------------"

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output '  Not elevated: run as SYSTEM or an administrator.'
    exit 1
}

$v = [ordered]@{ LastInstallerOrphanCleanupAt = (Get-Date -Format 's'); LastInstallerOrphanCleanupVersion = $SCRIPT_VERSION
                 LastInstallerOrphanDeleted = 0; LastInstallerOrphanFreedMb = 0; LastInstallerOrphanWouldFreeMb = 0 }
function Save-AndExit {
    param([string]$Status)
    $v['LastInstallerOrphanCleanupStatus'] = $Status
    try {
        if (-not (Test-Path $CachePath)) { New-Item -Path $CachePath -Force -ErrorAction Stop | Out-Null }
        foreach ($k in $v.Keys) { Set-ItemProperty -Path $CachePath -Name $k -Value ([string]$v[$k]) -Type String -ErrorAction Stop }
    } catch { Write-Output "  Cache not updated: $($_.Exception.Message)" }
    exit 0
}

# -- 1. find the orphans -------------------------------------------------------------
$o = Get-InstallerOrphans -MinAgeDays $MinAgeDays -NameFilter $NameFilter
if (-not $o.Ok) {
    if ($o.Reason -eq 'NoRegistrations') { Write-Output '  No installed product registration could be read, so no file can be called an orphan. Nothing done.'; Save-AndExit 'NoRegistrations' }
    Write-Output "  The Installer folder could not be read ($($o.Reason)). Nothing done."
    Save-AndExit 'Failed'
}
$orphans = @($o.Orphans)

# -- 2. the second opinion, and what each file is ----------------------------------------
$installer = $null; $second = $null
try { $installer = New-Object -ComObject WindowsInstaller.Installer -ErrorAction Stop; $second = Get-InstallerSecondOpinion $installer } catch { $second = $null }
$vetoed = 0
if ($null -ne $second) {
    $vetoed = @($orphans | Where-Object { $second.ContainsKey($_.Name.ToLowerInvariant()) }).Count
    $orphans = @($orphans | Where-Object { -not $second.ContainsKey($_.Name.ToLowerInvariant()) })
}
$bytes = [long]0; foreach ($f in $orphans) { $bytes += $f.Length }
$v['InstallerOrphansMb'] = ConvertTo-Mb $bytes; $v['LastInstallerOrphanWouldFreeMb'] = ConvertTo-Mb $bytes

$subject = @{}
foreach ($f in $orphans) {
    $s = '(not readable)'
    if ($installer) { try { $s = [string](Get-ComValue (Get-ComValue $installer 'SummaryInformation' @($f.FullName, 0)) 'Property' @(3)); if (-not $s) { $s = '(no subject)' } } catch { $s = '(not readable)' } }
    $subject[$f.Name] = ($s -replace '[\r\n\t]+', ' ').Trim()
}

Write-Output "  Installer folder: $($o.Files) cached file(s), $(ConvertTo-Mb $o.FileBytes) MB; $($o.Registered) in use by installed products and patches."
Write-Output "  Orphans older than $MinAgeDays day(s): $($orphans.Count), $(ConvertTo-Mb $bytes) MB.$(if ($o.Young) { " $($o.Young) younger left alone." })$(if ($vetoed) { " $vetoed kept because Windows Installer names them." })"
$groups = @($orphans | Group-Object { $subject[$_.Name] } | Sort-Object { ($_.Group | Measure-Object Length -Sum).Sum } -Descending)
foreach ($g in ($groups | Select-Object -First 12)) {
    Write-Output ("    {0,3} x {1,-60} {2,6} MB" -f $g.Count, $g.Name, (ConvertTo-Mb (($g.Group | Measure-Object Length -Sum).Sum)))
}
if ($groups.Count -gt 12) { Write-Output "    ... and $($groups.Count - 12) more product(s)" }

# -- 3. the gates ---------------------------------------------------------------------
if ($orphans.Count -eq 0) { Write-Output '  Nothing to delete.'; Save-AndExit 'NothingToDelete' }
if ((ConvertTo-Mb $bytes) -lt $MinTotalMb) { Write-Output "  Below the $MinTotalMb MB minimum (MinTotalMb). Nothing done."; Save-AndExit 'BelowMinimum' }
if ($whatIf) { Write-Output "  WhatIf: would delete $($orphans.Count) file(s), $(ConvertTo-Mb $bytes) MB. Nothing was changed."; Save-AndExit 'WhatIf' }
if (-not $confirmed) {
    Write-Output "  Report only: $($orphans.Count) file(s), $(ConvertTo-Mb $bytes) MB could be deleted. Set ConfirmDelete (or the script variable ConfirmHighImpact = true) to delete them. Nothing was changed."
    Save-AndExit 'ReportOnly'
}
if ($null -eq $second) {
    Write-Output '  Windows Installer could not be asked which files it uses, so the list is not confirmed. Nothing deleted.'
    Save-AndExit 'NotConfirmed'
}
if (Test-InstallRunning) { Write-Output '  An installation is in progress on this device. Nothing deleted; run again later.'; Save-AndExit 'InstallRunning' }

# -- 4. delete ------------------------------------------------------------------------
$deleted = 0; $freed = [long]0; $left = 0; $log = New-Object System.Collections.Generic.List[string]
foreach ($f in $orphans) {
    $len = $f.Length
    try {
        if (($f.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) { $f.Attributes = [IO.FileAttributes]::Normal }
        [IO.File]::Delete($f.FullName)
        $deleted++; $freed += $len
        $log.Add(('{0}  deleted  {1}  {2} bytes  cached {3:yyyy-MM-dd}  {4}' -f (Get-Date -Format 's'), $f.Name, $len, $f.CreationTime, $subject[$f.Name]))
    } catch { $left++ }
}
try {
    $logDir = Split-Path $LogFile -Parent
    if (-not [IO.Directory]::Exists($logDir)) { [void][IO.Directory]::CreateDirectory($logDir) }
    [IO.File]::AppendAllLines($LogFile, $log)
} catch { Write-Output "  Log not written: $($_.Exception.Message)" }

# -- 5. report and refresh the cache ------------------------------------------------------
$v['LastInstallerOrphanDeleted'] = $deleted; $v['LastInstallerOrphanFreedMb'] = ConvertTo-Mb $freed
$v['InstallerOrphansMb'] = ConvertTo-Mb ($bytes - $freed)
Write-Output "  Deleted $deleted file(s), $(ConvertTo-Mb $freed) MB freed$(if ($left) { "; $left in use or protected, left in place" }). The list is in $LogFile."
Save-AndExit $(if ($left) { 'Partial' } else { 'Completed' })
