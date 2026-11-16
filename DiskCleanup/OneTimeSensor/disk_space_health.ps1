<#
.SYNOPSIS
    disk_space_health -- one-time JSON sensor: where the system drive's space has gone,
    what a cleanup would free, and what no cleanup will free.

.DESCRIPTION
    Run on demand from the DEX console when a device is low on disk; MUST NOT be scheduled
    as a recurring sensor (the recurring ones are disk_reclaimable_safe_mb and
    disk_top_consumer, which read the collector's cache).

    Measured live, inside a 20 s budget: the safe bundle (by the rules of
    Start-DiskCleanupSafe.ps1, same SHARED BLOCK), crash dumps, recycle bin, shadow
    copies, hibernation file, page file, Outlook data files, WSL/Docker virtual disks.
    Taken from the collector's cache, because walking them takes too long for a sensor:
    previous Windows installation, Downloads, the other user folders, OneDrive content
    kept on the device (-1 when Invoke-DiskStateCollection.ps1 has never run).

    One line of compact JSON under Hub's 1 KB sensor cap. Keys, all sizes in MB:
      Schema 1, At, Ms, FreeMb, SizeMb
      SafeMb          what Start-DiskCleanupSafe would free now
      Safe { WinTemp, UserTemp, ErrorReports, UpdateCache, DeliveryOpt, ServicingLogs,
             DefenderHistory }                      reclaimable per category
      Own  { CrashDumps, PreviousWindows, RecycleBin, ShadowCopies }
                                                    cleared by their own scripts
      Rep  { HibernationFile, PageFile, OutlookData, VirtualDisks, Downloads,
             UserFolders, OneDriveLocal }           report only: a policy fix, no script
      Top             largest item of 1 GB or more, same keys as disk_top_consumer
      Cached          "MM-dd" date of the cached figures, "" when there is no cache
      Last            last safe cleanup: "<Status> <MM-dd> <MB freed>", "" when never
      TO              true when the budget cut the live measurement short

.NOTES
    Sensor Name  : disk_space_health
    Data Type    : String (JSON)
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Timeout      : One-time / run-once only. Self-enforced 20 s budget, 30 s UEM ceiling.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
#Requires -Version 5.1
$script:Deadline = (Get-Date).AddSeconds(20)
$script:TimedOut = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$CachePath = 'HKLM:\Software\AirWatch\Extensions\DiskState'

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
function Measure-Paths { param([string[]]$Patterns, [string[]]$Profiles)
    $t = [long]0
    foreach ($pat in $Patterns) { foreach ($p in @(Expand-DiskPath $pat $Profiles)) { $t += (Measure-DiskTree -Path $p).Bytes } }
    return $t
}
function Measure-Files { param([string[]]$Patterns, [string[]]$Profiles)
    $t = [long]0
    foreach ($pat in $Patterns) { foreach ($p in @(Expand-DiskPath $pat $Profiles)) { foreach ($f in @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue)) { if (-not $f.PSIsContainer) { $t += $f.Length } } } }
    return $t
}

$profiles = @(Get-DiskProfiles)
$cache = $null
try { $cache = Get-ItemProperty -Path $CachePath -ErrorAction Stop } catch { }
function Get-Cached { param([string]$Name) if ($cache -and "$($cache.$Name)" -match '^-?\d+$') { return [int]$cache.$Name }; return -1 }

$o = [ordered]@{ Schema = 1; At = (Get-Date -Format 's'); Ms = 0; FreeMb = -1; SizeMb = -1; SafeMb = 0
                 Safe = [ordered]@{}; Own = [ordered]@{}; Rep = [ordered]@{}; Top = 'None'; Cached = ''; Last = ''; TO = $false }
try { $d = New-Object System.IO.DriveInfo ([string]$env:SystemDrive); $o.FreeMb = ConvertTo-Mb $d.AvailableFreeSpace; $o.SizeMb = ConvertTo-Mb $d.TotalSize } catch { }

# -- live: cheap items first, then the safe bundle ------------------------------------
$live = @(
    @{ G = 'Rep'; K = 'HibernationFile'; Run = { Measure-Files @('{Sys}\hiberfil.sys') $profiles } },
    @{ G = 'Rep'; K = 'PageFile';        Run = { Measure-Files @('{Sys}\pagefile.sys', '{Sys}\swapfile.sys') $profiles } },
    @{ G = 'Own'; K = 'ShadowCopies';    Run = { $s = [long]0; foreach ($x in @(Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction SilentlyContinue)) { $s += [long]$x.UsedSpace }; $s } },
    @{ G = 'Rep'; K = 'OutlookData';     Run = { Measure-Files @('{Local}\Microsoft\Outlook\*.ost', '{Local}\Microsoft\Outlook\*.pst', '{Local}\Microsoft\Outlook\*.nst') $profiles } },
    @{ G = 'Rep'; K = 'VirtualDisks';    Run = { Measure-Files @('{Local}\Packages\*\LocalState\*.vhdx', '{Local}\Docker\wsl\*\*.vhdx', '{Local}\wsl\*\*.vhdx') $profiles } },
    @{ G = 'Own'; K = 'CrashDumps';      Run = { (Measure-Files @('{Win}\MEMORY.DMP') $profiles) + (Measure-Paths @('{Win}\Minidump', '{Win}\LiveKernelReports', '{Local}\CrashDumps', '{Win}\System32\config\systemprofile\AppData\Local\CrashDumps') $profiles) } },
    @{ G = 'Own'; K = 'RecycleBin';      Run = { Measure-Paths @('{Sys}\$Recycle.Bin') $profiles } }
)
foreach ($i in $live) {
    if ($script:TimedOut) { $o[$i.G][$i.K] = -1; continue }
    $b = [long]0
    try { $b = [long](& $i.Run) } catch { }
    $o[$i.G][$i.K] = $(if ($script:TimedOut) { -1 } else { ConvertTo-Mb $b })
}
$safe = [long]0
foreach ($c in $SafeCategories) {
    if ($script:TimedOut) { $o.Safe[$c.Key] = -1; continue }
    $m = Measure-SafeCategory $c $profiles
    if ($script:TimedOut) { $o.Safe[$c.Key] = -1; continue }
    $o.Safe[$c.Key] = ConvertTo-Mb $m.Eligible; $safe += $m.Eligible
}
$o.SafeMb = ConvertTo-Mb $safe

# -- from the collector's cache: too slow to walk inside a sensor -------------------------
$o.Own['PreviousWindows'] = Get-Cached 'PreviousWindowsMb'
$o.Rep['Downloads']       = Get-Cached 'DownloadsMb'
$o.Rep['UserFolders']     = Get-Cached 'UserFoldersMb'
$o.Rep['OneDriveLocal']   = Get-Cached 'OneDriveLocalMb'
if ($cache) {
    try { $o.Cached = ([datetime]$cache.CollectedAt).ToString('MM-dd') } catch { }
    if ("$($cache.LastCleanupStatus)") {
        $when = ''; try { $when = ([datetime]$cache.LastCleanupAt).ToString('MM-dd') } catch { }
        $o.Last = "$($cache.LastCleanupStatus) $when $($cache.LastCleanupFreedMb)".Trim()
    }
}

# -- largest item of 1 GB or more ---------------------------------------------------------
$topMb = 0
$all = [ordered]@{ SafeCleanup = $o.SafeMb }
foreach ($g in 'Own', 'Rep') { foreach ($k in $o[$g].Keys) { $all[$k] = $o[$g][$k] } }
foreach ($k in $all.Keys) { if ([int]$all[$k] -ge 1024 -and [int]$all[$k] -gt $topMb) { $o.Top = $k; $topMb = [int]$all[$k] } }

$o.TO = [bool]$script:TimedOut
$o.Ms = [int]$sw.ElapsedMilliseconds
$j = $o | ConvertTo-Json -Depth 4 -Compress
if ($j.Length -gt 1000) { $o.Remove('Last'); $o.Remove('Cached'); $j = $o | ConvertTo-Json -Depth 4 -Compress }
if ($j.Length -gt 1000) { $o.Safe = [ordered]@{}; $j = $o | ConvertTo-Json -Depth 4 -Compress }
if ($j.Length -gt 1000) { $j = '{"Schema":1,"FreeMb":' + $o.FreeMb + ',"SafeMb":' + $o.SafeMb + ',"Top":"' + $o.Top + '","TO":true}' }
Write-Output $j
exit 0
