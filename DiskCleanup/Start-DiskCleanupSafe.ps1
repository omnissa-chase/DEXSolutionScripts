<#
.SYNOPSIS
    Start-DiskCleanupSafe -- frees the disk space nobody needs a decision about: old temp
    files, error reports, update download leftovers, old servicing logs. Reports what it
    freed, per category. Takes no input.

.DESCRIPTION
    The safe bundle of the disk cleanup playbook. It measures each category itself, so
    it can say what it will free before it frees anything (WhatIf), and what it freed
    afterwards, immediately: it does not hand off to cleanmgr.

    Categories and the age a file must reach (created AND last written before then):
      Windows temp files                7 days    %windir%\Temp
      User temp files                   7 days    every user's AppData\Local\Temp
      Windows error reports             7 days    WER ReportArchive / ReportQueue / Temp
      Windows Update download cache    14 days    SoftwareDistribution\Download
      Delivery Optimization cache       all       through Delete-DeliveryOptimizationCache
      Servicing logs (CBS, DISM)       30 days    never the live CBS.log / dism.log
      Defender scan history            30 days    best effort; tamper protection may refuse

    Not here, on purpose: crash dumps, the previous Windows installation, the recycle
    bin, shadow copies, the component store, driver packages and installer files. Each
    of those is a decision with its own sensor and its own script, so an admin can set
    a threshold for it in the playbook. Nothing a user created is ever touched.

    A file in use is skipped and counted, never forced. Reparse points are not followed.
    Deletion has a 100 s budget; a run that hits it stops cleanly (Status Partial) and
    the next run continues.

    The disk_reclaimable_safe_mb sensor (from Invoke-DiskStateCollection.ps1) reports
    what this script would free, by the same rules: the SHARED BLOCK below is identical
    in both. This script refreshes those cached values when it finishes.

.NOTES
    Script Name  : Start-DiskCleanupSafe.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Timeout      : 180 seconds
    Reporting    : HKLM:\Software\AirWatch\Extensions\DiskState (LastCleanup* values)

    No input. Settings are the constants in the SETTINGS block and the MinAgeDays column
    of the category table. Optional environment variable WhatIf (true = report only).

    Exit codes: 0 = done (including Partial and "nothing to free"); 1 = not elevated.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# ==============================================================================
# SETTINGS -- edit here; there are no script variables to pass.
# ==============================================================================
$MinReclaimableMb = 0     # do nothing unless at least this much can be freed (0 = always run)
$SkipCategories   = @()   # category keys to leave alone, e.g. @('UpdateCache','DefenderHistory')
# Per-category ages are the MinAgeDays values in the table below.
# ==============================================================================

$SCRIPT_VERSION  = '1.0.0'
$CachePath       = 'HKLM:\Software\AirWatch\Extensions\DiskState'
$script:Deadline = $null   # measuring is not budgeted here; deleting is (below)
$script:TimedOut = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$whatIf = "$env:WhatIf" -match '^(?i)(true|1|yes)$'

#region SHARED BLOCK disk-v1 -- identical in Invoke-DiskStateCollection.ps1, Start-DiskCleanupSafe.ps1 and disk_space_health.ps1
# The safe bundle. A file counts when it was both created and last written more than
# MinAgeDays ago. Tokens: {Win} Windows folder, {PD} ProgramData, {Local} each user's
# AppData\Local. Exclude is a regex on the file name. Engine 'DO' is cleared with the
# Delivery Optimization cmdlet, never by deleting its files.
$SafeCategories = @(
    @{ Key = 'WinTemp';         Label = 'Windows temp files';             MinAgeDays = 7;  Paths = @('{Win}\Temp') },
    @{ Key = 'UserTemp';        Label = 'User temp files';                MinAgeDays = 7;  Paths = @('{Local}\Temp') },
    @{ Key = 'ErrorReports';    Label = 'Windows error reports';          MinAgeDays = 7;  Paths = @('{PD}\Microsoft\Windows\WER\ReportArchive', '{PD}\Microsoft\Windows\WER\ReportQueue', '{PD}\Microsoft\Windows\WER\Temp', '{Local}\Microsoft\Windows\WER\ReportArchive', '{Local}\Microsoft\Windows\WER\ReportQueue') },
    @{ Key = 'UpdateCache';     Label = 'Windows Update download cache';  MinAgeDays = 14; Paths = @('{Win}\SoftwareDistribution\Download') },
    @{ Key = 'DeliveryOpt';     Label = 'Delivery Optimization cache';    MinAgeDays = 0;  Paths = @('{Win}\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'); Engine = 'DO' },
    @{ Key = 'ServicingLogs';   Label = 'Servicing logs (CBS, DISM)';     MinAgeDays = 30; Paths = @('{Win}\Logs\CBS', '{Win}\Logs\DISM', '{Win}\Logs\MoSetup'); Exclude = '^(?i)(CBS|dism)\.log$' },
    @{ Key = 'DefenderHistory'; Label = 'Defender scan history';          MinAgeDays = 30; Paths = @('{PD}\Microsoft\Windows Defender\Scans\History\Results') }
)

function Get-DiskProfiles {
    # Profile folders of real users (local, domain and Entra ID). Emits them one by one.
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue)) {
        if ($k.PSChildName -notmatch '^S-1-(5-21|12-1)-') { continue }
        $p = [string]$k.GetValue('ProfileImagePath')
        if ($p -and (Test-Path -LiteralPath $p -PathType Container)) { $p }
    }
}

function Expand-DiskPath {
    # One path per profile for {Local}/{Profile} patterns, else one path. Emits strings.
    param([string]$Pattern, [string[]]$Profiles)
    $p = $Pattern.Replace('{Win}', [string]$env:windir).Replace('{PD}', [string]$env:ProgramData).Replace('{Sys}', [string]$env:SystemDrive)
    if ($p -match '\{(Local|Profile)\}') { foreach ($u in $Profiles) { $p.Replace('{Local}', "$u\AppData\Local").Replace('{Profile}', $u) } }
    else { $p }
}

function Measure-DiskTree {
    # Total and age-eligible bytes under a folder. Reparse points are never followed.
    # SkipCloud leaves out files whose content is not on the device (OneDrive placeholders).
    param([string]$Path, [int]$MinAgeDays = 0, [string]$Exclude = '', [switch]$SkipCloud)
    $r = @{ Bytes = [long]0; Eligible = [long]0; Files = 0 }
    if (-not [IO.Directory]::Exists($Path)) { return $r }
    $cut = (Get-Date).AddDays(-$MinAgeDays)
    $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($Path)
    while ($stack.Count -gt 0) {
        if ($script:Deadline -and (Get-Date) -gt $script:Deadline) { $script:TimedOut = $true; break }
        $d = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo $d
            foreach ($f in $di.GetFiles()) {
                if ($SkipCloud -and (([int]$f.Attributes -band 0x401000) -ne 0)) { continue }
                $r.Bytes += $f.Length; $r.Files++
                if ($Exclude -and $f.Name -match $Exclude) { continue }
                if ($MinAgeDays -le 0 -or ($f.LastWriteTime -lt $cut -and $f.CreationTime -lt $cut)) { $r.Eligible += $f.Length }
            }
            foreach ($s in $di.GetDirectories()) { if (($s.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($s.FullName) } }
        } catch { }
    }
    return $r
}

function Measure-SafeCategory {
    param($Cat, [string[]]$Profiles)
    $t = [long]0; $e = [long]0
    foreach ($pat in $Cat.Paths) {
        foreach ($p in @(Expand-DiskPath $pat $Profiles)) {
            $m = Measure-DiskTree -Path $p -MinAgeDays ([int]$Cat.MinAgeDays) -Exclude "$($Cat.Exclude)"
            $t += $m.Bytes; $e += $m.Eligible
        }
    }
    if ("$($Cat.Engine)" -eq 'DO' -and -not (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)) { $e = 0 }
    return @{ Bytes = $t; Eligible = $e }
}
#endregion

function ConvertTo-Mb { param([long]$Bytes) return [int][math]::Round($Bytes / 1MB) }

function Test-SafeRoot {
    # A root this script may delete under: inside the Windows folder, ProgramData, or a
    # user's AppData\Local, and never one of those folders itself.
    param([string]$Path, [string[]]$Profiles)
    if (-not $Path -or $Path.Length -lt 12 -or -not [IO.Path]::IsPathRooted($Path)) { return $false }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $roots = @("$env:windir\", "$env:ProgramData\") + @($Profiles | ForEach-Object { "$_\AppData\Local\" })
    foreach ($r in $roots) { if ($full.StartsWith($r, [StringComparison]::OrdinalIgnoreCase) -and $full.Length -gt $r.Length) { return $true } }
    return $false
}

function Remove-DiskTree {
    # Deletes the age-eligible files under a folder, then the folders left empty that are
    # themselves older than the cut. The root stays. Returns bytes freed and files skipped.
    param([string]$Path, [int]$MinAgeDays, [string]$Exclude)
    $r = @{ Freed = [long]0; Skipped = 0; Files = 0 }
    if (-not [IO.Directory]::Exists($Path)) { return $r }
    $cut = (Get-Date).AddDays(-$MinAgeDays)
    $dirs = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($Path)
    while ($stack.Count -gt 0) {
        if ((Get-Date) -gt $script:DeleteDeadline) { $script:Partial = $true; break }
        $d = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo $d
            foreach ($f in $di.GetFiles()) {
                if ($Exclude -and $f.Name -match $Exclude) { continue }
                if ($MinAgeDays -gt 0 -and -not ($f.LastWriteTime -lt $cut -and $f.CreationTime -lt $cut)) { continue }
                $len = $f.Length
                try {
                    if (($f.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) { $f.Attributes = [IO.FileAttributes]::Normal }
                    [IO.File]::Delete($f.FullName)
                    $r.Freed += $len; $r.Files++
                } catch { $r.Skipped++ }
            }
            foreach ($s in $di.GetDirectories()) {
                if (($s.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($s.FullName); $dirs.Add($s.FullName) }
            }
        } catch { }
    }
    # Deepest first, so a parent emptied by its children can go too.
    foreach ($d in @($dirs | Sort-Object { $_.Length } -Descending)) {
        try {
            $di = New-Object System.IO.DirectoryInfo $d
            if ($di.Exists -and $di.CreationTime -lt $cut -and @($di.GetFileSystemInfos()).Count -eq 0) { $di.Delete() }
        } catch { }
    }
    return $r
}

Write-Output "-- Start-DiskCleanupSafe $SCRIPT_VERSION$(if ($whatIf) { ' [WhatIf]' }) ------------------------------"

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output '  Not elevated: run as SYSTEM or an administrator.'
    exit 1
}

$profiles = @(Get-DiskProfiles)
$freeBefore = [long]0
try { $freeBefore = (New-Object System.IO.DriveInfo ([string]$env:SystemDrive)).AvailableFreeSpace } catch { }

# -- 1. measure -------------------------------------------------------------------
$plan = @()
$reclaimable = [long]0
foreach ($c in $SafeCategories) {
    $m = Measure-SafeCategory $c $profiles
    $skip = $SkipCategories -contains $c.Key
    $plan += @{ Cat = $c; Eligible = $m.Eligible; Total = $m.Bytes; Skip = $skip; Freed = [long]0; Skipped = 0 }
    if (-not $skip) { $reclaimable += $m.Eligible }
}
Write-Output "  Reclaimable under the current rules: $(ConvertTo-Mb $reclaimable) MB."

if ((ConvertTo-Mb $reclaimable) -lt $MinReclaimableMb) {
    Write-Output "  Below the $MinReclaimableMb MB minimum (MinReclaimableMb). Nothing done."
    exit 0
}

# -- 2. clean -----------------------------------------------------------------------
$script:DeleteDeadline = (Get-Date).AddSeconds(100)
$script:Partial = $false
$totalFreed = [long]0; $totalSkipped = 0
foreach ($p in $plan) {
    $c = $p.Cat
    if ($p.Skip) { Write-Output ("  {0,-32} skipped by SkipCategories ({1} MB left)" -f $c.Label, (ConvertTo-Mb $p.Eligible)); continue }
    if ($p.Eligible -le 0) { Write-Output ("  {0,-32} nothing to free" -f $c.Label); continue }
    if ($whatIf) { Write-Output ("  {0,-32} would free {1,6} MB (WhatIf)" -f $c.Label, (ConvertTo-Mb $p.Eligible)); continue }
    if ($script:Partial) { Write-Output ("  {0,-32} not reached (time budget spent); the next run takes it" -f $c.Label); continue }

    if ("$($c.Engine)" -eq 'DO') {
        try {
            Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
            $after = (Measure-SafeCategory $c $profiles).Bytes
            $p.Freed = [math]::Max([long]0, $p.Total - $after)
        } catch { $p.Skipped = 1; Write-Output "    Delivery Optimization cache could not be cleared: $($_.Exception.Message)" }
    } else {
        foreach ($pat in $c.Paths) {
            foreach ($root in @(Expand-DiskPath $pat $profiles)) {
                if (-not (Test-SafeRoot $root $profiles)) { Write-Output "    Refused (not a permitted root): $root"; continue }
                $r = Remove-DiskTree -Path $root -MinAgeDays ([int]$c.MinAgeDays) -Exclude "$($c.Exclude)"
                $p.Freed += $r.Freed; $p.Skipped += $r.Skipped
            }
        }
    }
    $totalFreed += $p.Freed; $totalSkipped += $p.Skipped
    Write-Output ("  {0,-32} freed {1,6} MB{2}" -f $c.Label, (ConvertTo-Mb $p.Freed), $(if ($p.Skipped) { " ($($p.Skipped) file(s) in use or protected, left)" } else { '' }))
}

# -- 3. report and refresh the cache --------------------------------------------------
$freeAfter = $freeBefore
try { $freeAfter = (New-Object System.IO.DriveInfo ([string]$env:SystemDrive)).AvailableFreeSpace } catch { }
$status = if ($whatIf) { 'WhatIf' } elseif ($script:Partial) { 'Partial' } else { 'Completed' }

if ($whatIf) {
    Write-Output "  WhatIf: would free $(ConvertTo-Mb $reclaimable) MB. Nothing was changed."
} else {
    Write-Output "  Freed $(ConvertTo-Mb $totalFreed) MB$(if ($totalSkipped) { "; $totalSkipped file(s) left in place" }). Free space: $(ConvertTo-Mb $freeAfter) MB (was $(ConvertTo-Mb $freeBefore) MB).$(if ($script:Partial) { ' Time budget spent; the next run continues.' })"
}

try {
    if (-not (Test-Path $CachePath)) { New-Item -Path $CachePath -Force -ErrorAction Stop | Out-Null }
    $v = [ordered]@{ LastCleanupAt = (Get-Date -Format 's'); LastCleanupStatus = $status; LastCleanupVersion = $SCRIPT_VERSION
                     LastCleanupFreedMb = $(if ($whatIf) { 0 } else { ConvertTo-Mb $totalFreed }); LastCleanupWouldFreeMb = (ConvertTo-Mb $reclaimable)
                     LastCleanupSeconds = [int]($sw.ElapsedMilliseconds / 1000) }
    if (-not $whatIf) {
        # What is left is what could not be freed; the sensors show the result at once.
        $left = [long]0
        foreach ($p in $plan) {
            $remain = [math]::Max([long]0, $p.Eligible - $p.Freed)
            $v["Safe_$($p.Cat.Key)Mb"] = ConvertTo-Mb $remain
            if (-not $p.Skip) { $left += $remain }
        }
        $v['ReclaimableSafeMb'] = ConvertTo-Mb $left
        $v['FreeMb'] = ConvertTo-Mb $freeAfter
    }
    foreach ($k in $v.Keys) { Set-ItemProperty -Path $CachePath -Name $k -Value ([string]$v[$k]) -Type String -ErrorAction Stop }
} catch { Write-Output "  Cache not updated: $($_.Exception.Message)" }

exit 0
