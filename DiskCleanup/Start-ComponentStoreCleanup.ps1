<#
.SYNOPSIS
    Start-ComponentStoreCleanup -- starts a component store (WinSxS) cleanup in the
    background and a fresh analysis after it, so the sensor shows what was freed.
    Takes no input.

.DESCRIPTION
    Superseded update files stay in the component store until a cleanup removes them;
    on a device that has taken a year of updates that is several GB. Windows runs this
    cleanup itself only when the device sits idle on AC power, which many laptops never
    do. This script is that branch of the disk cleanup playbook. Pair it with the
    disk_component_store_reclaimable_mb sensor and run it when that value is over the
    threshold the admin chooses.

    The cleanup takes 5 to 40 minutes, far longer than a Hub step may run, so it is
    started detached and this script returns at once:
        DISM /Online /Cleanup-Image /StartComponentCleanup
        DISM /Online /Cleanup-Image /AnalyzeComponentStore      (straight after)
    The sensor reads the new analysis when it lands. The next run of this script or of
    Invoke-ComponentStoreAnalysis.ps1 records the outcome (Completed or Failed, MB
    freed) in the cache.

    It is supported and safe: the same operation as the built-in StartComponentCleanup
    scheduled task. Installed updates stay removable, because ResetBase is off by
    default. It uses CPU and disk while it runs; nothing restarts.

    Nothing is started when DISM or the Windows Modules Installer is already working,
    when a restart is pending for servicing, or when the last analysis says less than
    MinReclaimableMb can be freed.

.NOTES
    Script Name  : Start-ComponentStoreCleanup.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Timeout      : 60 seconds (the cleanup itself runs detached)
    Reporting    : HKLM:\Software\AirWatch\Extensions\DiskState (LastComponentCleanup* values)

    No input. Settings are the constants in the SETTINGS block. Optional environment
    variable WhatIf (true = report only).

    Exit codes: 0 = started, already running, or nothing to do; 1 = not elevated or
    DISM could not be started.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# ==============================================================================
# SETTINGS -- edit here; there are no script variables to pass.
# ==============================================================================
$MinReclaimableMb = 0        # do nothing unless the last analysis shows at least this (0 = always run; needs Invoke-ComponentStoreAnalysis.ps1 when above 0)
$ResetBase        = $false   # $true also removes the ability to uninstall the updates already installed (frees more; not reversible)
# ==============================================================================

$SCRIPT_VERSION = '1.0.0'
$CachePath      = 'HKLM:\Software\AirWatch\Extensions\DiskState'
$whatIf = "$env:WhatIf" -match '^(?i)(true|1|yes)$'

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

function Get-CacheText {
    param([string]$Name)
    try { return [string](Get-ItemProperty -Path $CachePath -Name $Name -ErrorAction Stop).$Name } catch { return '' }
}

function Write-Cache {
    param($Values)
    try {
        if (-not (Test-Path $CachePath)) { New-Item -Path $CachePath -Force -ErrorAction Stop | Out-Null }
        foreach ($k in $Values.Keys) { Set-ItemProperty -Path $CachePath -Name $k -Value ([string]$Values[$k]) -Type String -ErrorAction Stop }
    } catch { Write-Output "  Cache not updated: $($_.Exception.Message)" }
}

Write-Output "-- Start-ComponentStoreCleanup $SCRIPT_VERSION$(if ($whatIf) { ' [WhatIf]' }) ------------------------------"

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output '  Not elevated: run as SYSTEM or an administrator.'
    exit 1
}

$dismRunning = @(Get-Process -Name 'dism' -ErrorAction SilentlyContinue).Count -gt 0
$report = Read-ComponentStoreReport $CsAnalyzeLog

# -- 1. close out an earlier run ---------------------------------------------------------
# A cleanup this script started is finished when its log is there under the final name.
if ((Get-CacheText 'LastComponentCleanupStatus') -eq 'Started' -and [IO.File]::Exists($CsCleanupLog)) {
    $ok = $false
    try { $ok = [IO.File]::ReadAllText($CsCleanupLog) -match 'The operation completed successfully' } catch { }
    $v = [ordered]@{ LastComponentCleanupStatus = $(if ($ok) { 'Completed' } else { 'Failed' }); LastComponentCleanupFinishedAt = [IO.File]::GetLastWriteTime($CsCleanupLog).ToString('s') }
    $before = Get-CacheText 'LastComponentCleanupBeforeMb'
    if ($ok -and $report.Ok -and $before -match '^\d+$' -and $report.At -ge $v.LastComponentCleanupFinishedAt) {
        $v['LastComponentCleanupFreedMb'] = [math]::Max(0, [int]$before - $report.ReclaimableMb)
        $v['ComponentStoreReclaimableMb'] = $report.ReclaimableMb; $v['ComponentStoreMb'] = $report.ActualMb; $v['ComponentStoreAnalyzedAt'] = $report.At
    }
    Write-Cache $v
    Write-Output "  The cleanup started $(Get-CacheText 'LastComponentCleanupStartedAt') ended: $($v.LastComponentCleanupStatus)$(if ($v.Contains('LastComponentCleanupFreedMb')) { ", about $($v.LastComponentCleanupFreedMb) MB freed" })."
}

if ($report.Ok) { Write-Output "  Last analysis ($($report.At)): reclaimable $($report.ReclaimableMb) MB of a $($report.ActualMb) MB component store; cleanup recommended: $($report.Recommended)." }
else { Write-Output '  No finished analysis on this device (Invoke-ComponentStoreAnalysis.ps1 has not run); the reclaimable figure is unknown.' }

# -- 2. guards -------------------------------------------------------------------------
$stop = ''
if ($dismRunning) { $stop = 'AlreadyRunning'; Write-Output '  DISM is already running on this device (a cleanup or analysis in progress). Nothing started.' }
elseif (@(Get-Process -Name 'TiWorker' -ErrorAction SilentlyContinue).Count -gt 0) { $stop = 'ServicingBusy'; Write-Output '  The Windows Modules Installer is working (an update is being installed). Nothing started; run again later.' }
elseif (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $stop = 'RebootPending'; Write-Output '  A restart is pending for servicing. Nothing started; a cleanup cannot run until the device has restarted.' }
elseif ($MinReclaimableMb -gt 0 -and -not $report.Ok) { $stop = 'NoAnalysis'; Write-Output "  MinReclaimableMb is $MinReclaimableMb but there is no analysis to compare with. Nothing started; run Invoke-ComponentStoreAnalysis.ps1 first." }
elseif ($MinReclaimableMb -gt 0 -and $report.ReclaimableMb -lt $MinReclaimableMb) { $stop = 'BelowMinimum'; Write-Output "  Below the $MinReclaimableMb MB minimum (MinReclaimableMb). Nothing started." }
if ($stop) {
    if ($stop -ne 'AlreadyRunning') { Write-Cache @{ LastComponentCleanupStatus = $stop; LastComponentCleanupAt = (Get-Date -Format 's') } }
    exit 0
}

$dismArgs = '/Online /Cleanup-Image /StartComponentCleanup' + $(if ($ResetBase) { ' /ResetBase' } else { '' })
if ($whatIf) {
    Write-Output "  WhatIf: would start DISM $dismArgs in the background$(if ($report.Ok) { ", to free about $($report.ReclaimableMb) MB" }). Nothing was changed."
    Write-Cache @{ LastComponentCleanupStatus = 'WhatIf'; LastComponentCleanupAt = (Get-Date -Format 's') }
    exit 0
}

# -- 3. start the cleanup, then a fresh analysis, detached ---------------------------------
try {
    if (-not [IO.Directory]::Exists($CsDir)) { [void][IO.Directory]::CreateDirectory($CsDir) }
    if ([IO.File]::Exists($CsCleanupLog)) { [IO.File]::Delete($CsCleanupLog) }
    $dism = "$env:windir\System32\dism.exe"
    if ([IO.File]::Exists("$env:windir\Sysnative\dism.exe")) { $dism = "$env:windir\Sysnative\dism.exe" }   # 32-bit host
    # Each log appears under its final name only when DISM has finished writing it.
    $cmd = "`"$dism`" $dismArgs /English > `"$CsCleanupLog.tmp`" 2>&1 & move /y `"$CsCleanupLog.tmp`" `"$CsCleanupLog`" >nul & " +
           "`"$dism`" /Online /Cleanup-Image /AnalyzeComponentStore /English > `"$CsAnalyzeLog.tmp`" 2>&1 & move /y `"$CsAnalyzeLog.tmp`" `"$CsAnalyzeLog`" >nul"
    # Start-Process, not the call operator: a child that inherits this host's output pipe keeps the Hub step open.
    Start-Process -FilePath "$env:windir\System32\cmd.exe" -ArgumentList "/s /c `"$cmd`"" -WindowStyle Hidden -ErrorAction Stop
} catch {
    Write-Output "  Error: DISM could not be started: $($_.Exception.Message)"
    Write-Cache @{ LastComponentCleanupStatus = 'Failed'; LastComponentCleanupAt = (Get-Date -Format 's') }
    exit 1
}

Write-Cache ([ordered]@{ LastComponentCleanupStatus = 'Started'; LastComponentCleanupAt = (Get-Date -Format 's'); LastComponentCleanupStartedAt = (Get-Date -Format 's')
                         LastComponentCleanupVersion = $SCRIPT_VERSION; LastComponentCleanupBeforeMb = $(if ($report.Ok) { $report.ReclaimableMb } else { '' }); LastComponentCleanupFreedMb = '' })
Write-Output "  Component cleanup started in the background (DISM $dismArgs), with a fresh analysis after it. It usually takes 5 to 40 minutes; the sensor shows the new figure when it ends."
exit 0
