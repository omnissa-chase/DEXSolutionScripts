<#
.SYNOPSIS
    Clear-PreviousWindowsInstall -- removes the previous Windows installation (Windows.old)
    and the leftovers of finished or failed upgrades, once the roll-back period is over.
    Takes no input.

.DESCRIPTION
    A feature update leaves the old installation behind so the device can roll back,
    usually 15 to 30 GB. Windows removes it by itself after the roll-back period, but
    that clean-up is often late or never happens, and the folders of a failed upgrade
    ($Windows.~BT, $Windows.~WS, $GetCurrent) are not always removed at all. This script
    is that branch of the disk cleanup playbook. Pair it with the
    disk_previous_windows_mb sensor and run it when that value is over the threshold
    the admin chooses.

    Removing Windows.old ends the option to go back to the previous version. So:
      * Nothing younger than MinAgeDays (10, the default roll-back period) is touched.
        A folder Windows Setup has written to within that time may belong to an update
        that is still being installed; it is left alone too.
      * Nothing is done while Windows Setup is running.
      * Set MinAgeDays to 0 only when the admin has decided the space matters more than
        the roll-back (an approval step in the playbook is the place for that decision).

    The removal is done by Windows' own Disk Cleanup handlers (cleanmgr), the supported
    way to delete these folders: they are owned by TrustedInstaller and contain links
    into the live profile folders, so they are never deleted by hand here. Only the
    handlers for the items found are enabled, under this script's own profile number,
    so an admin's Disk Cleanup settings are not changed.

    The removal can outlast the script: it waits up to 100 s, reports what has been
    freed so far, and says so when Disk Cleanup is still working. The next run of
    Invoke-DiskStateCollection.ps1 (or of this script) records the final figure.

.NOTES
    Script Name  : Clear-PreviousWindowsInstall.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Timeout      : 180 seconds
    Reporting    : HKLM:\Software\AirWatch\Extensions\DiskState (PreviousWindowsMb, LastPreviousWindows* values)

    No input. Settings are the constants in the SETTINGS block. Optional environment
    variable WhatIf (true = report only).

    Exit codes: 0 = done, started, or nothing to do; 1 = not elevated or Disk Cleanup
    could not be started.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# ==============================================================================
# SETTINGS -- edit here; there are no script variables to pass.
# ==============================================================================
$MinAgeDays          = 10      # leave anything younger than this (the roll-back period); 0 = remove regardless
$MinTotalMb          = 0       # do nothing unless the items total at least this (0 = always run; the playbook condition on disk_previous_windows_mb is the usual gate)
$IncludeSetupFolders = $true   # also remove upgrade leftovers ($Windows.~BT, $Windows.~WS, $GetCurrent)
# ==============================================================================

$SCRIPT_VERSION = '1.0.0'
$CachePath      = 'HKLM:\Software\AirWatch\Extensions\DiskState'
$VolumeCaches   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
$ProfileId      = 57           # this script's own cleanmgr profile (StateFlags0057)
$WaitSeconds    = 100
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$whatIf = "$env:WhatIf" -match '^(?i)(true|1|yes)$'
$sys = [string]$env:SystemDrive

function ConvertTo-Mb { param([long]$Bytes) return [int][math]::Round($Bytes / 1MB) }

function Measure-Tree {
    # Bytes under a folder, within a time budget. Reparse points are never followed.
    # Sets $script:MeasureTimedOut when the budget ran out (the figure is then a minimum).
    param([string]$Path, [datetime]$Deadline)
    $t = [long]0
    if (-not [IO.Directory]::Exists($Path)) { return $t }
    $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($Path)
    while ($stack.Count -gt 0) {
        if ((Get-Date) -gt $Deadline) { $script:MeasureTimedOut = $true; break }
        $d = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo $d
            foreach ($f in $di.GetFiles()) { $t += $f.Length }
            foreach ($s in $di.GetDirectories()) { if (($s.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($s.FullName) } }
        } catch { }
    }
    return $t
}

function Get-LastActivity {
    # The latest time anything was created or written at the top of the folder, or
    # Windows Setup wrote its log there. This is what "younger than MinAgeDays" means.
    param([string]$Path)
    $latest = [datetime]::MinValue
    try {
        $di = New-Object System.IO.DirectoryInfo $Path
        foreach ($t in @($di.CreationTime, $di.LastWriteTime)) { if ($t -gt $latest) { $latest = $t } }
        foreach ($c in $di.GetFileSystemInfos()) { if ($c.LastWriteTime -gt $latest) { $latest = $c.LastWriteTime } }
        $log = "$Path\Sources\Panther\setupact.log"
        if ([IO.File]::Exists($log)) { $t = [IO.File]::GetLastWriteTime($log); if ($t -gt $latest) { $latest = $t } }
    } catch { }
    return $latest
}

function Get-Items {
    # The folders this script knows, with the cleanmgr handlers that remove each.
    $all = @(
        @{ Key = 'WindowsOld';  Label = 'Previous installation (Windows.old)';  Path = "$sys\Windows.old";  Handlers = @('Previous Installations'); Setup = $false },
        @{ Key = 'WindowsBT';   Label = 'Upgrade files ($Windows.~BT)';         Path = "$sys\`$Windows.~BT"; Handlers = @('Temporary Setup Files', 'Upgrade Discarded Files'); Setup = $true },
        @{ Key = 'WindowsWS';   Label = 'Upgrade download ($Windows.~WS)';      Path = "$sys\`$Windows.~WS"; Handlers = @('Temporary Setup Files', 'Windows ESD installation files'); Setup = $true },
        @{ Key = 'GetCurrent';  Label = 'Update assistant files ($GetCurrent)'; Path = "$sys\`$GetCurrent";  Handlers = @('Temporary Setup Files'); Setup = $true }
    )
    foreach ($i in $all) { if ([IO.Directory]::Exists($i.Path)) { $i } }
}

function Measure-Items {
    param($Items, [int]$BudgetSeconds)
    $deadline = (Get-Date).AddSeconds($BudgetSeconds)
    $total = [long]0
    foreach ($i in $Items) { $i.Bytes = Measure-Tree -Path $i.Path -Deadline $deadline; $total += $i.Bytes }
    return $total
}

function Write-Cache {
    param([hashtable]$Values)
    try {
        if (-not (Test-Path $CachePath)) { New-Item -Path $CachePath -Force -ErrorAction Stop | Out-Null }
        foreach ($k in $Values.Keys) { Set-ItemProperty -Path $CachePath -Name $k -Value ([string]$Values[$k]) -Type String -ErrorAction Stop }
    } catch { Write-Output "  Cache not updated: $($_.Exception.Message)" }
}

Write-Output "-- Clear-PreviousWindowsInstall $SCRIPT_VERSION$(if ($whatIf) { ' [WhatIf]' }) ------------------------------"

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output '  Not elevated: run as SYSTEM or an administrator.'
    exit 1
}

# -- 1. what is there, and how old ---------------------------------------------------
$script:MeasureTimedOut = $false
$items = @(Get-Items)
if ($items.Count -eq 0) {
    Write-Output '  No previous Windows installation or upgrade leftovers on this device. Nothing to do.'
    Write-Cache @{ PreviousWindowsMb = 0; LastPreviousWindowsCleanupAt = (Get-Date -Format 's'); LastPreviousWindowsCleanupStatus = 'NothingToDo'; LastPreviousWindowsCleanupVersion = $SCRIPT_VERSION }
    exit 0
}

$totalBefore = Measure-Items $items 40
$atLeast = $(if ($script:MeasureTimedOut) { 'at least ' } else { '' })
$cut = (Get-Date).AddDays(-$MinAgeDays)
$eligible = @(); $eligibleBytes = [long]0
foreach ($i in $items) {
    $i.Activity = Get-LastActivity $i.Path
    $ageDays = [int][math]::Floor(((Get-Date) - $i.Activity).TotalDays)
    $why = ''
    if ($i.Setup -and -not $IncludeSetupFolders) { $why = 'left: IncludeSetupFolders is off' }
    elseif ($MinAgeDays -gt 0 -and $i.Activity -gt $cut) { $why = "left: last written $ageDays day(s) ago, inside the $MinAgeDays-day roll-back period" }
    if ($why) { Write-Output ("  {0,-40} {1,7} MB  {2}" -f $i.Label, (ConvertTo-Mb $i.Bytes), $why) }
    else { Write-Output ("  {0,-40} {1,7} MB  {2} day(s) old, to be removed" -f $i.Label, (ConvertTo-Mb $i.Bytes), $ageDays); $eligible += $i; $eligibleBytes += $i.Bytes }
}
Write-Output "  Total: $atLeast$(ConvertTo-Mb $totalBefore) MB; $atLeast$(ConvertTo-Mb $eligibleBytes) MB can be removed under the current settings."

$base = @{ LastPreviousWindowsCleanupAt = (Get-Date -Format 's'); LastPreviousWindowsCleanupVersion = $SCRIPT_VERSION; LastPreviousWindowsWouldFreeMb = (ConvertTo-Mb $eligibleBytes) }
if (-not $script:MeasureTimedOut) { $base['PreviousWindowsMb'] = ConvertTo-Mb $totalBefore }

if ($eligible.Count -eq 0) {
    Write-Output '  Nothing is old enough to remove. Nothing done.'
    $base['LastPreviousWindowsCleanupStatus'] = 'NothingEligible'; $base['LastPreviousWindowsFreedMb'] = 0
    Write-Cache $base; exit 0
}
if ((ConvertTo-Mb $totalBefore) -lt $MinTotalMb -and -not $script:MeasureTimedOut) {
    Write-Output "  Below the $MinTotalMb MB minimum (MinTotalMb). Nothing done."
    $base['LastPreviousWindowsCleanupStatus'] = 'BelowMinimum'; $base['LastPreviousWindowsFreedMb'] = 0
    Write-Cache $base; exit 0
}

$handlers = @($eligible | ForEach-Object { $_.Handlers } | Select-Object -Unique | Where-Object { Test-Path -LiteralPath "$VolumeCaches\$_" })
if ($whatIf) {
    Write-Output "  WhatIf: would remove $atLeast$(ConvertTo-Mb $eligibleBytes) MB with Disk Cleanup ($($handlers -join ', ')). Nothing was changed."
    $base['LastPreviousWindowsCleanupStatus'] = 'WhatIf'; $base['LastPreviousWindowsFreedMb'] = 0
    Write-Cache $base; exit 0
}

# -- 2. guards -------------------------------------------------------------------------
$setup = @(Get-Process -Name 'SetupHost', 'SetupPrep', 'Windows10UpgraderApp', 'WindowsUpdateBox' -ErrorAction SilentlyContinue)
if ($setup.Count -gt 0) {
    Write-Output "  Windows Setup is running ($(@($setup | ForEach-Object { $_.ProcessName } | Select-Object -Unique) -join ', ')). Nothing done; run again when the update has finished."
    $base['LastPreviousWindowsCleanupStatus'] = 'SetupRunning'; $base['LastPreviousWindowsFreedMb'] = 0
    Write-Cache $base; exit 0
}
if (@(Get-Process -Name 'cleanmgr' -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Output '  Disk Cleanup is already running on this device. Nothing started; run again when it has finished.'
    $base['LastPreviousWindowsCleanupStatus'] = 'CleanupAlreadyRunning'; $base['LastPreviousWindowsFreedMb'] = 0
    Write-Cache $base; exit 0
}
if ($handlers.Count -eq 0) {
    Write-Output '  Error: the Disk Cleanup handlers for these items are not registered on this device.'
    $base['LastPreviousWindowsCleanupStatus'] = 'NoHandler'; $base['LastPreviousWindowsFreedMb'] = 0
    Write-Cache $base; exit 1
}

# -- 3. run Disk Cleanup with only the handlers needed ---------------------------------
$flag = 'StateFlags{0:D4}' -f $ProfileId
$freeBefore = [long]0
try { $freeBefore = (New-Object System.IO.DriveInfo $sys).AvailableFreeSpace } catch { }
try {
    foreach ($k in @(Get-ChildItem -LiteralPath $VolumeCaches -ErrorAction Stop)) {
        $on = $handlers -contains $k.PSChildName
        New-ItemProperty -LiteralPath $k.PSPath -Name $flag -Value $(if ($on) { 2 } else { 0 }) -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    }
    # Start-Process, not the call operator: a child that inherits this host's output pipe
    # keeps the Hub step open until Disk Cleanup ends.
    Start-Process -FilePath "$env:windir\System32\cleanmgr.exe" -ArgumentList "/sagerun:$ProfileId" -WindowStyle Hidden -ErrorAction Stop
} catch {
    Write-Output "  Error: Disk Cleanup could not be started: $($_.Exception.Message)"
    $base['LastPreviousWindowsCleanupStatus'] = 'Failed'; $base['LastPreviousWindowsFreedMb'] = 0
    Write-Cache $base; exit 1
}
Write-Output "  Disk Cleanup started ($($handlers -join ', ')). Waiting up to $WaitSeconds s."

$deadline = (Get-Date).AddSeconds($WaitSeconds)
Start-Sleep -Seconds 3
# Done when the folders are gone. Disk Cleanup itself can stay around long after that
# (seen in the lab: folders removed in seconds, the process still there at 100 s), so
# its exit is only the fallback signal.
while ((Get-Date) -lt $deadline -and @(Get-Process -Name 'cleanmgr' -ErrorAction SilentlyContinue).Count -gt 0 -and
       @($eligible | Where-Object { [IO.Directory]::Exists($_.Path) }).Count -gt 0) { Start-Sleep -Seconds 3 }

# -- 4. report and refresh the cache ---------------------------------------------------
$stillThere = @($eligible | Where-Object { [IO.Directory]::Exists($_.Path) })
$running = $stillThere.Count -gt 0 -and @(Get-Process -Name 'cleanmgr' -ErrorAction SilentlyContinue).Count -gt 0
$freeAfter = $freeBefore
try { $freeAfter = (New-Object System.IO.DriveInfo $sys).AvailableFreeSpace } catch { }
$wasPartial = $script:MeasureTimedOut
$left = @(Get-Items)
$script:MeasureTimedOut = $false
$totalAfter = Measure-Items $left 20
# Freed is what was measured before minus what is left; the drive's free-space change
# is only used when one of the two measurements ran out of time.
$freedMb = if ($wasPartial -or $script:MeasureTimedOut) { [math]::Max(0, (ConvertTo-Mb ($freeAfter - $freeBefore))) } else { [math]::Max(0, (ConvertTo-Mb ($totalBefore - $totalAfter))) }

if ($running) {
    $status = 'Running'
    Write-Output "  Disk Cleanup is still working after $WaitSeconds s; about $freedMb MB freed so far. It finishes on its own; the next collection records the final figure."
} elseif ($stillThere.Count -eq 0) {
    $status = 'Completed'
    Write-Output "  Removed. About $freedMb MB freed. Free space: $(ConvertTo-Mb $freeAfter) MB (was $(ConvertTo-Mb $freeBefore) MB)."
} else {
    $status = 'Incomplete'
    Write-Output "  Disk Cleanup finished but left: $(@($stillThere | ForEach-Object { $_.Path }) -join ', '). About $freedMb MB freed."
}

$base['LastPreviousWindowsCleanupStatus'] = $status
$base['LastPreviousWindowsFreedMb'] = $freedMb
$base['LastPreviousWindowsCleanupSeconds'] = [int]($sw.ElapsedMilliseconds / 1000)
if (-not $script:MeasureTimedOut) { $base['PreviousWindowsMb'] = ConvertTo-Mb $totalAfter } else { $base.Remove('PreviousWindowsMb') }
Write-Cache $base
exit 0
