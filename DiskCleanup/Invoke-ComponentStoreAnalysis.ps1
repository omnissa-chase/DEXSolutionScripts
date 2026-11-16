<#
.SYNOPSIS
    Invoke-ComponentStoreAnalysis -- asks Windows how much of the component store (WinSxS)
    can be reclaimed, and caches the answer for the disk_component_store_reclaimable_mb
    sensor. Takes no input.

.DESCRIPTION
    The component store is usually the largest thing under the Windows folder, and most
    of it is not reclaimable: it is shared with the running system. The only honest
    figure is the one DISM gives (Backups and Disabled Features, plus Cache and
    Temporary Data), and getting it takes one to five minutes of servicing work. That is
    too slow for the daily disk collector, so it has its own script: schedule it weekly,
    or run it from the playbook before deciding on Start-ComponentStoreCleanup.ps1.

    The analysis runs detached (DISM /Online /Cleanup-Image /AnalyzeComponentStore
    /English) and writes its report to
    %ProgramData%\AirWatch\Extensions\DiskState\component-analyze.log. This script waits
    up to 100 s for it; when the analysis takes longer it finishes on its own and the
    sensor reads the report when it is there.

    Read only: an analysis changes nothing on the device.

.NOTES
    Script Name  : Invoke-ComponentStoreAnalysis.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Timeout      : 180 seconds
    Schedule     : weekly (and on demand before the cleanup decision)
    Reporting    : HKLM:\Software\AirWatch\Extensions\DiskState (ComponentStore* values)

    No input. Exit codes: 0 = analysis read, started, or already running; 1 = not
    elevated or DISM could not be started.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$SCRIPT_VERSION = '1.0.0'
$CachePath      = 'HKLM:\Software\AirWatch\Extensions\DiskState'
$WaitSeconds    = 100

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

function Write-Cache {
    param($Values)
    try {
        if (-not (Test-Path $CachePath)) { New-Item -Path $CachePath -Force -ErrorAction Stop | Out-Null }
        foreach ($k in $Values.Keys) { Set-ItemProperty -Path $CachePath -Name $k -Value ([string]$Values[$k]) -Type String -ErrorAction Stop }
    } catch { Write-Output "  Cache not updated: $($_.Exception.Message)" }
}

function Save-Report {
    param($Report)
    Write-Cache ([ordered]@{ ComponentStoreMb = $Report.ActualMb; ComponentStoreReclaimableMb = $Report.ReclaimableMb; ComponentStoreBackupsMb = $Report.BackupsMb
                             ComponentStoreCacheMb = $Report.CacheMb; ComponentStorePackages = $Report.Packages; ComponentStoreCleanupRecommended = $Report.Recommended
                             ComponentStoreAnalyzedAt = $Report.At })
    Write-Output "  Component store: $($Report.ActualMb) MB; reclaimable $($Report.ReclaimableMb) MB (backups and disabled features $($Report.BackupsMb), cache and temporary data $($Report.CacheMb)); $($Report.Packages) reclaimable package(s); cleanup recommended: $($Report.Recommended)."
}

Write-Output "-- Invoke-ComponentStoreAnalysis $SCRIPT_VERSION ------------------------------"

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output '  Not elevated: run as SYSTEM or an administrator.'
    exit 1
}

$started = Get-Date
if (@(Get-Process -Name 'dism' -ErrorAction SilentlyContinue).Count -gt 0) {
    # Ours from an earlier run, a cleanup, or somebody else's: either way a second DISM would only queue behind it.
    # Only a report written from now on counts as its result.
    Write-Output '  DISM is already running on this device; not starting another. Waiting for the report.'
} else {
    try {
        if (-not [IO.Directory]::Exists($CsDir)) { [void][IO.Directory]::CreateDirectory($CsDir) }
        $dism = "$env:windir\System32\dism.exe"
        if ([IO.File]::Exists("$env:windir\Sysnative\dism.exe")) { $dism = "$env:windir\Sysnative\dism.exe" }   # 32-bit host
        $tmp = "$CsAnalyzeLog.tmp"
        # The report appears under its final name only when DISM has finished writing it.
        $cmd = "`"$dism`" /Online /Cleanup-Image /AnalyzeComponentStore /English > `"$tmp`" 2>&1 & move /y `"$tmp`" `"$CsAnalyzeLog`" >nul"
        # Start-Process, not the call operator: a child that inherits this host's output pipe keeps the Hub step open.
        Start-Process -FilePath "$env:windir\System32\cmd.exe" -ArgumentList "/s /c `"$cmd`"" -WindowStyle Hidden -ErrorAction Stop
        Write-Output "  Analysis started. Waiting up to $WaitSeconds s."
    } catch {
        Write-Output "  Error: DISM could not be started: $($_.Exception.Message)"
        exit 1
    }
}

$deadline = (Get-Date).AddSeconds($WaitSeconds)
$fresh = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if ([IO.File]::Exists($CsAnalyzeLog) -and [IO.File]::GetLastWriteTime($CsAnalyzeLog) -ge $started.AddSeconds(-2)) { $fresh = $true; break }
}

$report = Read-ComponentStoreReport $CsAnalyzeLog
if ($fresh -and $report.Ok) {
    Save-Report $report
} elseif ($fresh) {
    Write-Output "  The analysis finished without a usable report (see $CsAnalyzeLog). Servicing may be busy or a restart may be pending."
    Write-Cache @{ ComponentStoreAnalysisError = (Get-Date -Format 's') }
} else {
    Write-Output "  The analysis is still running after $WaitSeconds s. It finishes on its own; the sensor reads the report when it is there."
    if ($report.Ok) { Write-Output "  Previous report ($($report.At)): reclaimable $($report.ReclaimableMb) MB." }
}
exit 0
