#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : disk_component_store_reclaimable_mb
    Data Type    : Integer
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Timeout      : < 5 seconds
    Requires     : Invoke-ComponentStoreAnalysis.ps1 scheduled weekly

    MB of the component store (WinSxS) that a component cleanup can remove: superseded
    update backups and disabled features, plus cache and temporary data, as reported by
    DISM. -1 means unknown: no analysis has finished on this device.

    This is the playbook's trigger for Start-ComponentStoreCleanup.ps1. It is not the
    size of WinSxS, most of which is shared with the running system and cannot be
    freed. The sensor reads the newest finished DISM report directly, so the value moves
    as soon as an analysis or a cleanup ends; it never runs DISM itself.
#>

#region SHARED BLOCK cs-v1 -- identical in Invoke-ComponentStoreAnalysis.ps1, Start-ComponentStoreCleanup.ps1 and disk_component_store_reclaimable_mb.ps1
$CsDir        = "$env:ProgramData\AirWatch\Extensions\DiskState"
$CsAnalyzeLog = "$CsDir\component-analyze.log"
$CsCleanupLog = "$CsDir\component-cleanup.log"

function Read-ComponentStoreReport {
    # Parses a finished DISM /AnalyzeComponentStore /English report. Ok is false when the
    # file is missing, unfinished or failed. Reclaimable = backups and disabled features
    # + cache and temporary data: the two parts a component cleanup can remove.
    param([string]$Path)
    $r = @{ Ok = $false; ActualMb = -1; BackupsMb = -1; CacheMb = -1; ReclaimableMb = -1; Packages = -1; Recommended = ''; At = '' }
    if (-not [IO.File]::Exists($Path)) { return $r }
    try { $text = [IO.File]::ReadAllText($Path) } catch { return $r }
    if ($text -notmatch 'The operation completed successfully') { return $r }
    $size = {
        param([string]$Label)
        $m = [regex]::Match($text, [regex]::Escape($Label) + '\s*:\s*([\d.,]+)\s*(bytes|KB|MB|GB|TB)', 'IgnoreCase')
        if (-not $m.Success) { return -1 }
        $n = [double]::Parse($m.Groups[1].Value.Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)
        switch ($m.Groups[2].Value.ToUpper()) { 'BYTES' { $n = $n / 1MB } 'KB' { $n = $n / 1024 } 'GB' { $n = $n * 1024 } 'TB' { $n = $n * 1024 * 1024 } }
        return [int][math]::Round($n)
    }
    $r.ActualMb  = & $size 'Actual Size of Component Store'
    $r.BackupsMb = & $size 'Backups and Disabled Features'
    $r.CacheMb   = & $size 'Cache and Temporary Data'
    if ($r.BackupsMb -lt 0 -or $r.CacheMb -lt 0) { return $r }
    $r.ReclaimableMb = $r.BackupsMb + $r.CacheMb
    $m = [regex]::Match($text, 'Number of Reclaimable Packages\s*:\s*(\d+)'); if ($m.Success) { $r.Packages = [int]$m.Groups[1].Value }
    $m = [regex]::Match($text, 'Component Store Cleanup Recommended\s*:\s*(\w+)'); if ($m.Success) { $r.Recommended = $m.Groups[1].Value }
    $r.At = [IO.File]::GetLastWriteTime($Path).ToString('s')
    $r.Ok = $true
    return $r
}
#endregion

try {
    $report = Read-ComponentStoreReport $CsAnalyzeLog
    if ($report.Ok) { Write-Output ([int]$report.ReclaimableMb); return }
    # No finished report on disk: fall back to the last value a script cached.
    $cached = Get-ItemProperty -Path 'HKLM:\Software\AirWatch\Extensions\DiskState' -Name 'ComponentStoreReclaimableMb' -ErrorAction SilentlyContinue
    if ($null -ne $cached -and "$($cached.ComponentStoreReclaimableMb)" -match '^\d+$') { Write-Output ([int]$cached.ComponentStoreReclaimableMb); return }
    Write-Output -1
    return
}
catch {
    Write-Output -1
    return
}
