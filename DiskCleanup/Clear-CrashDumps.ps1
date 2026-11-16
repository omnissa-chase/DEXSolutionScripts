<#
.SYNOPSIS
    Clear-CrashDumps -- deletes crash dump files (the full memory dump, minidumps, live
    kernel reports, application dumps) and keeps the newest few minidumps for diagnosis.
    Takes no input.

.DESCRIPTION
    Crash dumps are worth keeping until they take real space: one full memory dump is as
    large as the device's RAM. This script is the "they have become too large" branch of
    the disk cleanup playbook. Pair it with the disk_crashdump_mb sensor and run it when
    that value is over the threshold the admin chooses.

    What it deletes (dump files only: .dmp, .mdmp, .hdmp, .kdmp):
      MemoryDump          the full or kernel dump, %windir%\MEMORY.DMP (or the path set in
                          CrashControl\DumpFile)
      Minidumps           %windir%\Minidump, except the newest KeepNewestMinidumps
      LiveKernelReports   %windir%\LiveKernelReports (watchdog and hardware reports)
      UserDumps           every user's AppData\Local\CrashDumps and the SYSTEM profile's

    What it keeps: the newest minidumps (a few MB each, and the files a support engineer
    asks for first), anything younger than KeepDays when that is set, and a dump that is
    being written right now (in use: skipped and counted).

    Windows Error Reporting's own queue and archive are not here; the safe cleanup
    (Start-DiskCleanupSafe.ps1) ages those out.

.NOTES
    Script Name  : Clear-CrashDumps.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Timeout      : 120 seconds
    Reporting    : HKLM:\Software\AirWatch\Extensions\DiskState (CrashDumpMb, LastCrashDump* values)

    No input. Settings are the constants in the SETTINGS block. Optional environment
    variable WhatIf (true = report only).

    Exit codes: 0 = done (including "nothing to free" and "below the minimum"); 1 = not elevated.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# ==============================================================================
# SETTINGS -- edit here; there are no script variables to pass.
# ==============================================================================
$MinTotalMb          = 0     # do nothing unless the dumps total at least this (0 = always run; the playbook condition on disk_crashdump_mb is the usual gate)
$KeepNewestMinidumps = 3     # newest files in %windir%\Minidump to keep (0 = keep none)
$KeepDays            = 0     # keep any dump younger than this many days (0 = age does not matter)
$SkipLocations       = @()   # location keys to leave alone: 'MemoryDump','Minidumps','LiveKernelReports','UserDumps'
# ==============================================================================

$SCRIPT_VERSION = '1.0.0'
$CachePath      = 'HKLM:\Software\AirWatch\Extensions\DiskState'
$DumpExt        = '^(?i)\.(dmp|mdmp|hdmp|kdmp)$'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$whatIf = "$env:WhatIf" -match '^(?i)(true|1|yes)$'

function ConvertTo-Mb { param([long]$Bytes) return [int][math]::Round($Bytes / 1MB) }

function Get-DiskProfiles {
    # Profile folders of real users (local, domain and Entra ID). Emits them one by one.
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue)) {
        if ($k.PSChildName -notmatch '^S-1-(5-21|12-1)-') { continue }
        $p = [string]$k.GetValue('ProfileImagePath')
        if ($p -and [IO.Directory]::Exists($p)) { $p }
    }
}

function Get-TreeFiles {
    # Every file under a folder as FileInfo, one by one. Reparse points are never followed.
    param([string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return }
    $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo $d
            foreach ($f in $di.GetFiles()) { $f }
            foreach ($s in $di.GetDirectories()) { if (($s.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($s.FullName) } }
        } catch { }
    }
}

Write-Output "-- Clear-CrashDumps $SCRIPT_VERSION$(if ($whatIf) { ' [WhatIf]' }) ------------------------------"

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output '  Not elevated: run as SYSTEM or an administrator.'
    exit 1
}

# -- 1. find the dumps -------------------------------------------------------------
$profiles = @(Get-DiskProfiles)

# The memory dump: the default path, and the configured one when it differs.
$memPaths = @("$env:windir\MEMORY.DMP")
try {
    $cfg = [string](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name DumpFile -ErrorAction Stop).DumpFile
    $cfg = [Environment]::ExpandEnvironmentVariables($cfg)
    if ($cfg -and [IO.Path]::IsPathRooted($cfg) -and [IO.Path]::GetExtension($cfg) -match $DumpExt -and ($memPaths -notcontains $cfg)) { $memPaths += $cfg }
} catch { }

$locations = @(
    @{ Key = 'MemoryDump';        Label = 'Memory dump';          Files = @($memPaths | Where-Object { [IO.File]::Exists($_) } | ForEach-Object { New-Object System.IO.FileInfo $_ }) },
    @{ Key = 'Minidumps';         Label = 'Minidumps';            Files = @(Get-TreeFiles "$env:windir\Minidump") },
    @{ Key = 'LiveKernelReports'; Label = 'Live kernel reports';  Files = @(Get-TreeFiles "$env:windir\LiveKernelReports") },
    @{ Key = 'UserDumps';         Label = 'Application dumps';    Files = @(@($profiles | ForEach-Object { "$_\AppData\Local\CrashDumps" }) + @("$env:windir\System32\config\systemprofile\AppData\Local\CrashDumps") | ForEach-Object { Get-TreeFiles $_ }) }
)

$cut = (Get-Date).AddDays(-$KeepDays)
$allBytes = [long]0; $eligibleBytes = [long]0
foreach ($loc in $locations) {
    $loc.Total = [long]0; $loc.Eligible = [long]0; $loc.Kept = 0; $loc.Freed = [long]0; $loc.Skipped = 0
    $loc.Skip = $SkipLocations -contains $loc.Key
    $dumps = @($loc.Files | Where-Object { $_.Extension -match $DumpExt })
    foreach ($f in $loc.Files) { $loc.Total += $f.Length }
    # The newest minidumps stay: small, and the first thing support asks for.
    if ($loc.Key -eq 'Minidumps' -and $KeepNewestMinidumps -gt 0) {
        $sorted = @($dumps | Sort-Object LastWriteTime -Descending)
        $loc.Kept = [math]::Min($KeepNewestMinidumps, $sorted.Count)
        $dumps = @($sorted | Select-Object -Skip $KeepNewestMinidumps)
    }
    if ($KeepDays -gt 0) {
        $old = @($dumps | Where-Object { $_.LastWriteTime -lt $cut })
        $loc.Kept += ($dumps.Count - $old.Count)
        $dumps = $old
    }
    $loc.Delete = $dumps
    foreach ($f in $dumps) { $loc.Eligible += $f.Length }
    $allBytes += $loc.Total
    if (-not $loc.Skip) { $eligibleBytes += $loc.Eligible }
}
Write-Output "  Crash dumps on this device: $(ConvertTo-Mb $allBytes) MB; $(ConvertTo-Mb $eligibleBytes) MB can be freed under the current settings."

if ((ConvertTo-Mb $allBytes) -lt $MinTotalMb) {
    Write-Output "  Below the $MinTotalMb MB minimum (MinTotalMb). Nothing done."
    exit 0
}

# -- 2. delete -----------------------------------------------------------------------
$totalFreed = [long]0; $totalSkipped = 0
foreach ($loc in $locations) {
    $kept = $(if ($loc.Kept) { "; $($loc.Kept) kept" } else { '' })
    if ($loc.Skip) { Write-Output ("  {0,-22} skipped by SkipLocations ({1} MB left)" -f $loc.Label, (ConvertTo-Mb $loc.Total)); continue }
    if (@($loc.Delete).Count -eq 0) { Write-Output ("  {0,-22} nothing to free{1}" -f $loc.Label, $kept); continue }
    if ($whatIf) { Write-Output ("  {0,-22} would free {1,6} MB in {2} file(s){3} (WhatIf)" -f $loc.Label, (ConvertTo-Mb $loc.Eligible), @($loc.Delete).Count, $kept); continue }
    foreach ($f in $loc.Delete) {
        $len = $f.Length
        try {
            if (($f.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) { $f.Attributes = [IO.FileAttributes]::Normal }
            [IO.File]::Delete($f.FullName)
            $loc.Freed += $len
        } catch { $loc.Skipped++ }
    }
    $totalFreed += $loc.Freed; $totalSkipped += $loc.Skipped
    Write-Output ("  {0,-22} freed {1,6} MB{2}{3}" -f $loc.Label, (ConvertTo-Mb $loc.Freed), $kept, $(if ($loc.Skipped) { " ($($loc.Skipped) file(s) in use or protected, left)" } else { '' }))
}

# -- 3. report and refresh the cache --------------------------------------------------
$status = if ($whatIf) { 'WhatIf' } else { 'Completed' }
if ($whatIf) { Write-Output "  WhatIf: would free $(ConvertTo-Mb $eligibleBytes) MB. Nothing was changed." }
else { Write-Output "  Freed $(ConvertTo-Mb $totalFreed) MB$(if ($totalSkipped) { "; $totalSkipped file(s) left in place" }). Crash dumps now: $(ConvertTo-Mb ($allBytes - $totalFreed)) MB." }

try {
    if (-not (Test-Path $CachePath)) { New-Item -Path $CachePath -Force -ErrorAction Stop | Out-Null }
    $v = [ordered]@{ LastCrashDumpCleanupAt = (Get-Date -Format 's'); LastCrashDumpCleanupStatus = $status; LastCrashDumpCleanupVersion = $SCRIPT_VERSION
                     LastCrashDumpFreedMb = $(if ($whatIf) { 0 } else { ConvertTo-Mb $totalFreed }); LastCrashDumpWouldFreeMb = (ConvertTo-Mb $eligibleBytes)
                     CrashDumpMb = (ConvertTo-Mb ($allBytes - $totalFreed)) }   # the sensor shows the result at once
    foreach ($k in $v.Keys) { Set-ItemProperty -Path $CachePath -Name $k -Value ([string]$v[$k]) -Type String -ErrorAction Stop }
} catch { Write-Output "  Cache not updated: $($_.Exception.Message)" }

exit 0
