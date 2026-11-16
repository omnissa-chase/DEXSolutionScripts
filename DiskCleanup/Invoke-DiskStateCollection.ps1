<#
.SYNOPSIS
    Invoke-DiskStateCollection -- measures where the system drive's space has gone, once,
    and caches the figures for the disk_* sensors and the disk cleanup playbook.

.DESCRIPTION
    One scan, many cheap sensors. Walking the disk from every sensor would be wasteful,
    so this collector does the walk (schedule it once a day) and writes one value per
    item to HKLM:\Software\AirWatch\Extensions\DiskState. Each disk_* sensor reads one
    value. The cleanup scripts refresh their own values when they finish.

    Measured:
      Safe bundle     the categories Start-DiskCleanupSafe.ps1 clears, by the same rules
                      (same SHARED BLOCK), so ReclaimableSafeMb is what that script frees:
                      Windows temp, user temp, error reports, Windows Update download
                      cache, Delivery Optimization cache, servicing logs, Defender history.
      Own script      crash dumps, previous Windows installation and upgrade leftovers,
                      recycle bin, shadow copies. Sized here; cleared by their own scripts.
      Report only     hibernation file, page file, Outlook data files, WSL/Docker virtual
                      disks, Downloads, the other user folders, OneDrive content kept on
                      the device. Nothing clears these: the fix is a policy.
    TopConsumer names the largest item of 1 GB or more (None when there is none).

    Free space itself is not a sensor: DEX already collects it. It is cached only as
    context for the health sensor.

    The scan has a 100 s budget, cheap items first. When the budget runs out the items
    not yet measured keep their previous values and TimedOut is set to 1.

.NOTES
    Script Name  : Invoke-DiskStateCollection.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Timeout      : 120 seconds
    Schedule     : once a day (and on demand before reading the sensors)
    Cached to    : HKLM:\Software\AirWatch\Extensions\DiskState

    No input. Exit codes: 0 = cache written; 1 = not elevated or the cache write failed.
    Not measured yet (values absent, sensors report -1): component store, stale driver
    packages, orphaned installer files.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$SCRIPT_VERSION  = '1.0.0'
$CachePath       = 'HKLM:\Software\AirWatch\Extensions\DiskState'
$script:Deadline = (Get-Date).AddSeconds(100)
$script:TimedOut = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()

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

function Measure-Paths {
    # Sum of several trees (patterns with tokens). Returns bytes.
    param([string[]]$Patterns, [string[]]$Profiles, [switch]$SkipCloud)
    $t = [long]0
    foreach ($pat in $Patterns) { foreach ($p in @(Expand-DiskPath $pat $Profiles)) { $t += (Measure-DiskTree -Path $p -SkipCloud:$SkipCloud).Bytes } }
    return $t
}

function Measure-Files {
    # Sum of files matched by wildcard patterns (hidden and system files included). Returns bytes.
    param([string[]]$Patterns, [string[]]$Profiles)
    $t = [long]0
    foreach ($pat in $Patterns) {
        foreach ($p in @(Expand-DiskPath $pat $Profiles)) {
            foreach ($f in @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue)) { if (-not $f.PSIsContainer) { $t += $f.Length } }
        }
    }
    return $t
}

Write-Output "-- Invoke-DiskStateCollection $SCRIPT_VERSION ------------------------------"

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output '  Not elevated: run as SYSTEM or an administrator (other users'' folders and the cache key need it).'
    exit 1
}

$profiles = @(Get-DiskProfiles)
$v = [ordered]@{}     # values to cache
$sizes = [ordered]@{} # label -> MB, for TopConsumer

# -- the drive ------------------------------------------------------------------
try {
    $drive = New-Object System.IO.DriveInfo ([string]$env:SystemDrive)
    $v['FreeMb'] = ConvertTo-Mb $drive.AvailableFreeSpace
    $v['SizeMb'] = ConvertTo-Mb $drive.TotalSize
} catch { }

# -- safe bundle ------------------------------------------------------------------
$safe = [long]0
foreach ($c in $SafeCategories) {
    if ($script:TimedOut) { break }
    $m = Measure-SafeCategory $c $profiles
    $v["Safe_$($c.Key)Mb"]      = ConvertTo-Mb $m.Eligible
    $v["Safe_$($c.Key)TotalMb"] = ConvertTo-Mb $m.Bytes
    $safe += $m.Eligible
    Write-Output ("  {0,-34} {1,7} MB reclaimable of {2,7} MB" -f $c.Label, (ConvertTo-Mb $m.Eligible), (ConvertTo-Mb $m.Bytes))
}
if (-not $script:TimedOut) { $v['ReclaimableSafeMb'] = ConvertTo-Mb $safe; $sizes['SafeCleanup'] = ConvertTo-Mb $safe }

# -- items with their own script, and report-only items; cheap ones first ---------------
$items = @(
    @{ Key = 'CrashDumpMb';       Top = 'CrashDumps';       Label = 'Crash dumps';                      Run = { (Measure-Files @('{Win}\MEMORY.DMP') $profiles) + (Measure-Paths @('{Win}\Minidump', '{Win}\LiveKernelReports', '{Local}\CrashDumps', '{Win}\System32\config\systemprofile\AppData\Local\CrashDumps') $profiles) } },
    @{ Key = 'HiberfileMb';       Top = 'HibernationFile';  Label = 'Hibernation file';                 Run = { Measure-Files @('{Sys}\hiberfil.sys') $profiles } },
    @{ Key = 'PagefileMb';        Top = 'PageFile';         Label = 'Page file';                        Run = { Measure-Files @('{Sys}\pagefile.sys', '{Sys}\swapfile.sys') $profiles } },
    @{ Key = 'ShadowCopyMb';      Top = 'ShadowCopies';     Label = 'Shadow copies (restore points)';   Run = { $s = [long]0; foreach ($x in @(Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction SilentlyContinue)) { $s += [long]$x.UsedSpace }; $s } },
    @{ Key = 'OutlookDataMb';     Top = 'OutlookData';      Label = 'Outlook data files (OST, PST)';    Run = { Measure-Files @('{Local}\Microsoft\Outlook\*.ost', '{Local}\Microsoft\Outlook\*.pst', '{Local}\Microsoft\Outlook\*.nst') $profiles } },
    @{ Key = 'VirtualDiskMb';     Top = 'VirtualDisks';     Label = 'WSL and Docker virtual disks';     Run = { Measure-Files @('{Local}\Packages\*\LocalState\*.vhdx', '{Local}\Docker\wsl\*\*.vhdx', '{Local}\wsl\*\*.vhdx') $profiles } },
    @{ Key = 'RecycleBinMb';      Top = 'RecycleBin';       Label = 'Recycle bin';                      Run = { Measure-Paths @('{Sys}\$Recycle.Bin') $profiles } },
    @{ Key = 'DownloadsMb';       Top = 'Downloads';        Label = 'Downloads folders';                Run = { Measure-Paths @('{Profile}\Downloads') $profiles -SkipCloud } },
    @{ Key = 'PreviousWindowsMb'; Top = 'PreviousWindows';  Label = 'Previous Windows installation';    Run = { Measure-Paths @('{Sys}\Windows.old', '{Sys}\$Windows.~BT', '{Sys}\$Windows.~WS', '{Sys}\$GetCurrent') $profiles } },
    @{ Key = 'UserFoldersMb';     Top = 'UserFolders';      Label = 'Desktop, Documents, Pictures, Videos, Music'; Run = { Measure-Paths @('{Profile}\Desktop', '{Profile}\Documents', '{Profile}\Pictures', '{Profile}\Videos', '{Profile}\Music') $profiles -SkipCloud } },
    @{ Key = 'OneDriveLocalMb';   Top = 'OneDriveLocal';    Label = 'OneDrive content kept on the device'; Run = { $t = [long]0; foreach ($u in $profiles) { foreach ($d in @(Get-ChildItem -LiteralPath $u -Directory -Filter 'OneDrive*' -Force -ErrorAction SilentlyContinue)) { $t += (Measure-DiskTree -Path $d.FullName -SkipCloud).Bytes } }; $t } }
)
foreach ($i in $items) {
    if ($script:TimedOut -or (Get-Date) -gt $script:Deadline) { $script:TimedOut = $true; Write-Output ("  {0,-34} not measured (time budget spent); previous value kept" -f $i.Label); continue }
    $bytes = [long]0
    try { $bytes = [long](& $i.Run) } catch { }
    if ($script:TimedOut) { Write-Output ("  {0,-34} not measured (time budget spent); previous value kept" -f $i.Label); continue }
    $v[$i.Key] = ConvertTo-Mb $bytes; $sizes[$i.Top] = ConvertTo-Mb $bytes
    Write-Output ("  {0,-34} {1,7} MB" -f $i.Label, (ConvertTo-Mb $bytes))
}

# -- largest item of 1 GB or more ------------------------------------------------------
$top = 'None'; $topMb = 0
foreach ($k in $sizes.Keys) { if ([int]$sizes[$k] -ge 1024 -and [int]$sizes[$k] -gt $topMb) { $top = $k; $topMb = [int]$sizes[$k] } }
$v['TopConsumer'] = $top; $v['TopConsumerMb'] = $topMb
$v['TimedOut']    = $(if ($script:TimedOut) { 1 } else { 0 })
$v['DurationMs']  = [int]$sw.ElapsedMilliseconds
$v['CollectedAt'] = (Get-Date -Format 's')
$v['CollectorVersion'] = $SCRIPT_VERSION

try {
    if (-not (Test-Path $CachePath)) { New-Item -Path $CachePath -Force -ErrorAction Stop | Out-Null }
    foreach ($k in $v.Keys) { Set-ItemProperty -Path $CachePath -Name $k -Value ([string]$v[$k]) -Type String -ErrorAction Stop }
} catch {
    Write-Output "  Error: could not write the cache: $($_.Exception.Message)"
    exit 1
}

Write-Output "  Largest item: $top ($topMb MB). Free: $($v['FreeMb']) MB of $($v['SizeMb']) MB. Scan took $([int]($sw.ElapsedMilliseconds / 1000)) s$(if ($script:TimedOut) { '; time budget spent, some items kept their previous values' })."
exit 0
