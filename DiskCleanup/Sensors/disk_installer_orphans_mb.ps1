#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : disk_installer_orphans_mb
    Data Type    : Integer
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-17
    Timeout      : < 10 seconds
    Requires     : nothing; measured live

    MB of cached installer files in %windir%\Installer (.msi, .msp) that no installed
    product or patch of any user is registered to, and that have been there longer than
    MinAgeDays. 0 means there are none. -1 means unknown: the registrations could not
    be read, and then nothing is called an orphan.

    This is the playbook's trigger for Clear-InstallerOrphans.ps1, which reports the
    same files and deletes them only when approved (ConfirmDelete). The script also
    asks Windows Installer for a second opinion, so it can keep a file this sensor
    counts. Keep MinAgeDays here equal to the script's.
#>

# ==============================================================================
# SETTINGS -- keep equal to Clear-InstallerOrphans.ps1.
# ==============================================================================
$MinAgeDays = 30   # a file is not counted until it has been in the Installer folder this many days
# ==============================================================================

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

try {
    $o = Get-InstallerOrphans -MinAgeDays $MinAgeDays
    if (-not $o.Ok) { Write-Output -1; return }
    Write-Output ([int][math]::Round($o.OrphanBytes / 1MB))
    return
}
catch {
    Write-Output -1
    return
}
