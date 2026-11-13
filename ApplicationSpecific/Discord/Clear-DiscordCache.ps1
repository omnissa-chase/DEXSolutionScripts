<#
.SYNOPSIS
    Clear-DiscordCache -- clears the Discord cache folders for the signed-in user (or every
    user), skipping any user whose Discord is running. Action script: no threshold, no
    detection, it clears what it is pointed at and reports what it freed.

.DESCRIPTION
    Hub runs this as SYSTEM, so per-user paths are built from each profile's folder under
    ProfileList, never from the SYSTEM environment. Only the folders listed below are
    touched, and only their contents (the folders themselves stay, so the app finds them).
    Anything not listed is never read or deleted.

    Clears (per user):
      - Cache, Code Cache, GPUCache and the Dawn caches under %AppData%\discord
      - optional: Service Worker storage

    Never touches:
      - Local Storage, Session Storage, IndexedDB, settings.json (sign-in and settings)
      - the app binaries under %LocalAppData%\Discord

    Gate: Discord.exe. When the app is running for a user that user is skipped and reported,
    unless CloseApp=true, in which case the app is asked to close (CloseMainWindow, up to
    20 s) and the user is still skipped if it stays open. Nothing is ever killed.

    Budget: stops deleting after 50 s and reports Partial, so Hub's 60 s timeout never
    cuts the report off. The next run finishes the job.

    Variables (Workspace ONE script variables, read from the environment):
      WhatIf                   true  -> report sizes, delete nothing             (default false)
      CloseApp                 true  -> ask a running Discord to close first (default false)
      Users                    Console (signed-in user, default) or All (every local profile)
      IncludeOptional          true  -> also clear the entries marked optional   (default false)

    Output: one line per user ([Cleared], [WhatIf], [Skipped] with the reason) and a summary.
    Cache: HKLM\Software\AirWatch\Extensions\AppCache\Discord (LastRun, Status, MBFreed,
    UsersCleared, UsersSkipped, LockedFiles, BudgetHit, WhatIf). Exit 0 unless the script
    itself fails (exit 1, Status Error). Runs unchanged on Windows PowerShell 5.1 and
    PowerShell 7.

.NOTES
    Script Name  : Clear-DiscordCache.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

#Requires -Version 5.1

$SCRIPT_VERSION = '1.0.0'
$Product   = 'Discord'
$RegPath   = 'HKLM:\Software\AirWatch\Extensions\AppCache\Discord'
$LogPath   = "$env:SystemRoot\Temp\UEM_ClearDiscordCache.log"
$BudgetSec = 50
$CloseWaitSec = 20
$RequiresDestructiveFlag = $false

# Process names (no .exe) that hold the cache open. Empty: no gate.
$ProcessNames = @('Discord')
# Install markers: any one present (for the machine or for a target user) means the product is installed.
# Tokens: {Profile} {Local} {Roaming} {Packages} {PF} {PF86}. Wildcards allowed.
$InstallMarkers = @('{Local}\Discord', '{Roaming}\discord')
# Catalogue: folders whose CONTENTS are cleared. Exclude is a regex on the resolved folder path.
$Catalogue = @(
    @{ Name = 'Electron caches'; Paths = @('{Roaming}\discord\Cache', '{Roaming}\discord\Code Cache', '{Roaming}\discord\GPUCache', '{Roaming}\discord\DawnGraphiteCache', '{Roaming}\discord\DawnWebGPUCache'); Optional = $false },
    @{ Name = 'Service worker storage'; Paths = @('{Roaming}\discord\Service Worker\CacheStorage', '{Roaming}\discord\Service Worker\ScriptCache'); Optional = $true }
)

# -- Variables ------------------------------------------------------------------
function Get-BoolVar { param([string]$Name, [bool]$Default) $v = [Environment]::GetEnvironmentVariable($Name); if ([string]::IsNullOrWhiteSpace($v)) { return $Default }; try { return [Convert]::ToBoolean($v) } catch { return ($v -match '^(?i)(1|yes|y|on)$') } }
$WhatIf          = Get-BoolVar 'WhatIf' $false
$CloseApp        = Get-BoolVar 'CloseApp' $false
$IncludeOptional = Get-BoolVar 'IncludeOptional' $false
$AllowDestructive = Get-BoolVar 'AllowDestructiveActions' $false
$UsersMode = [string]$env:Users; if ($UsersMode -notmatch '^(?i)(Console|All)$') { $UsersMode = 'Console' }
$ReportOnly = $false
if ($RequiresDestructiveFlag -and -not $AllowDestructive -and -not $WhatIf) { $ReportOnly = $true; $WhatIf = $true }

$RunEventId = ([Random]::new()).Next(1000, 9999)
$HEAD = "`r`n[$RunEventId]"
$Deadline = (Get-Date).AddSeconds($BudgetSec)
$script:BudgetHit = $false
function Write-Log { param([string]$Message, [string]$Level = 'INFO') "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$RunEventId] [$Level] $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8 -ErrorAction SilentlyContinue }
Write-Output "[$RunEventId] Executing Clear-DiscordCache, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIf CloseApp=$CloseApp Users=$UsersMode IncludeOptional=$IncludeOptional"
if ($ReportOnly) { Write-Output "$HEAD $Product cache is only cleared with AllowDestructiveActions=true; reporting sizes only." }

# -- Helpers --------------------------------------------------------------------
function Expand-Token { param([string]$Path, $User)
    $p = $Path.Replace('{PF}', [string]$env:ProgramFiles).Replace('{PF86}', [string]${env:ProgramFiles(x86)})
    if ($User) { $p = $p.Replace('{Profile}', $User.Profile).Replace('{Local}', $User.Local).Replace('{Roaming}', $User.Roaming).Replace('{Packages}', $User.Packages) }
    return $p
}
function Resolve-Folders { param([string]$Pattern, $User, [string]$Exclude)
    $p = Expand-Token $Pattern $User
    if ($p -match '\{(Profile|Local|Roaming|Packages)\}') { return ,@() }
    $hits = @()
    if ($p -match '[\*\?]') { $hits = @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer } | ForEach-Object { $_.FullName }) }
    elseif (Test-Path -LiteralPath $p -PathType Container) { $hits = @($p) }
    if ($Exclude) { $hits = @($hits | Where-Object { $_ -notmatch $Exclude }) }
    return ,@($hits)
}
function Test-Marker { param([string]$Pattern, $User)
    $p = Expand-Token $Pattern $User
    if ($p -match '\{(Profile|Local|Roaming|Packages)\}') { return $false }
    if ($p -match '[\*\?]') { return (@(Get-Item -Path $p -Force -ErrorAction SilentlyContinue).Count -gt 0) }
    return (Test-Path -LiteralPath $p)
}
function Get-TargetUsers {
    $out = @()
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $console = if ($cs -and $cs.UserName) { [string]$cs.UserName } else { '' }
    $consoleSid = ''
    if ($console) { try { $consoleSid = ([Security.Principal.NTAccount]$console).Translate([Security.Principal.SecurityIdentifier]).Value } catch { } }
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue)) {
        $sid = $k.PSChildName
        if ($sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { continue }
        if ($UsersMode -eq 'Console' -and $sid -ne $consoleSid) { continue }
        $p = [string](Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $name = Split-Path $p -Leaf
        try { $name = ([Security.Principal.SecurityIdentifier]$sid).Translate([Security.Principal.NTAccount]).Value } catch { }
        $out += @{ Sid = $sid; Name = $name; Profile = $p; Local = "$p\AppData\Local"; Roaming = "$p\AppData\Roaming"; Packages = "$p\AppData\Local\Packages" }
    }
    if ($UsersMode -eq 'Console' -and $out.Count -eq 0) { Write-Output "$HEAD No signed-in console user$(if ($console) { " with a profile on disk ($console)" }); nothing to clear. Use Users=All to clear every profile." }
    return ,@($out)
}
function Get-ProcessOwner { param($Process)
    try { $o = Invoke-CimMethod -InputObject (Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($Process.Id)" -ErrorAction Stop) -MethodName GetOwner -ErrorAction Stop; if ($o.ReturnValue -eq 0) { return "$($o.Domain)\$($o.User)" } } catch { }
    return ''
}
function Get-AppProcesses { param($User)
    if ($ProcessNames.Count -eq 0) { return ,@() }
    $owned = @()
    foreach ($p in @(Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue)) {
        $owner = Get-ProcessOwner $p
        if (-not $owner -or $owner -ieq $User.Name -or $UsersMode -eq 'Console') { $owned += $p }   # unknown owner counts as this user's: safe side
    }
    return ,@($owned)
}
function Close-AppProcesses { param($Procs)
    foreach ($p in $Procs) { try { [void]$p.CloseMainWindow() } catch { } }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    do { Start-Sleep -Seconds 1; $alive = @($Procs | Where-Object { try { -not $_.HasExited } catch { $false } }) } while ($alive.Count -gt 0 -and $sw.Elapsed.TotalSeconds -lt $CloseWaitSec)
    return ($alive.Count -eq 0)
}
function Measure-Folder { param([string]$Path)
    # .NET walk with a try/catch per directory: an order of magnitude faster than Get-ChildItem -Recurse on cache folders with thousands of small files.
    $s = [long]0; $stack = New-Object System.Collections.Generic.Stack[string]; $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try { $di = New-Object System.IO.DirectoryInfo $d; foreach ($f in $di.GetFiles()) { $s += $f.Length }; foreach ($sub in $di.GetDirectories()) { if (($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($sub.FullName) } } } catch { }
    }
    return $s
}
function Clear-FolderContents { param([string]$Path, [ref]$Locked)
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        if ((Get-Date) -gt $Deadline) { $script:BudgetHit = $true; return }
        try { Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop }
        catch { if ($item.PSIsContainer) { $Locked.Value += @(Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue).Count } else { $Locked.Value++ } }
    }
}
function Format-MB { param([long]$Bytes) return ('{0:N0} MB' -f ($Bytes / 1MB)) }

# -- Main ------------------------------------------------------------------------
$status = 'Error'; $totalFreed = [long]0; $totalBefore = [long]0; $usersCleared = 0; $usersSkipped = 0; $lockedTotal = 0; $exitCode = 0
try {
    $users = Get-TargetUsers
    $installed = $false
    foreach ($m in $InstallMarkers) { if (Test-Marker $m $null) { $installed = $true; break } }
    if (-not $installed) { foreach ($u in $users) { foreach ($m in $InstallMarkers) { if (Test-Marker $m $u) { $installed = $true; break } }; if ($installed) { break } } }
    if (-not $installed) {
        Write-Output "$HEAD $Product is not present on this device (no install marker for the machine or the target user$(if ($users.Count -ne 1) { 's' })). Nothing to clear."
        $status = 'NotInstalled'
    } elseif ($users.Count -eq 0) {
        $status = 'NoUser'
    } else {
        $entries = @($Catalogue | Where-Object { -not $_.Optional -or $IncludeOptional })
        foreach ($u in $users) {
            $procs = Get-AppProcesses $u
            if ($procs.Count -gt 0 -and -not $WhatIf) {
                $closed = $false
                if ($CloseApp) { Write-Output "$HEAD $($u.Name): asking $Product to close ($($procs.Count) process(es))..."; $closed = Close-AppProcesses $procs }
                if (-not $closed) {
                    $usersSkipped++
                    $size = [long]0; foreach ($e in $entries) { foreach ($f in (Resolve-Folders $e.Paths $u $e.Exclude)) { $size += Measure-Folder $f } }
                    Write-Output "  [Skipped] $($u.Name): $Product is running ($($procs.Count) process(es)); $(Format-MB $size) of cache left in place.$(if (-not $CloseApp) { ' Set CloseApp=true to close it first.' })"
                    Write-Log "Skipped $($u.Name): running"
                    continue
                }
            }
            $before = [long]0; $after = [long]0; $folders = 0; $locked = 0; $skippedNames = @()
            foreach ($e in $entries) {
                $hits = @()
                foreach ($pat in @($e.Paths)) { $hits += Resolve-Folders $pat $u $e.Exclude }
                if ($hits.Count -eq 0) { continue }
                foreach ($f in $hits) {
                    $b = Measure-Folder $f; $before += $b; $folders++
                    if ($WhatIf) { $after += $b; continue }
                    $l = 0; Clear-FolderContents $f ([ref]$l); $locked += $l
                    $after += Measure-Folder $f
                    if ($script:BudgetHit) { break }
                }
                if ($script:BudgetHit) { break }
            }
            $freed = $before - $after
            $totalBefore += $before; $totalFreed += $freed; $lockedTotal += $locked
            if ($WhatIf) {
                Write-Output "  [WhatIf ] $($u.Name): $(Format-MB $before) in $folders $Product cache folder(s) would be cleared$(if ($procs.Count -gt 0) { " ($Product is running: a real run would skip this user)" })."
            } else {
                $usersCleared++
                Write-Output "  [Cleared] $($u.Name): $(Format-MB $freed) freed from $folders $Product cache folder(s)$(if ($locked) { ", $locked file(s) in use left behind" })$(if ($script:BudgetHit) { '; time budget reached, the rest clears on the next run' })."
                Write-Log "Cleared $($u.Name): $freed bytes, $folders folders, $locked locked"
            }
        }
        $status = if ($WhatIf) { 'WhatIf' } elseif ($usersCleared -eq 0) { 'Skipped' } elseif ($script:BudgetHit -or $lockedTotal -gt 0 -or $usersSkipped -gt 0) { 'Partial' } else { 'Cleared' }
    }
} catch {
    Write-Output "$HEAD Script error: $($_.Exception.Message)"
    Write-Log "Error: $($_.Exception.Message)" 'ERROR'
    $status = 'Error'; $exitCode = 1
}

Write-Output "$HEAD Users: $(if ($users) { $users.Count } else { 0 })  Cleared: $usersCleared  Skipped: $usersSkipped  Freed: $(Format-MB $totalFreed)$(if ($WhatIf) { " (measured $(Format-MB $totalBefore))" })  Locked: $lockedTotal  Status: $status"
try {
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null }
    $vals = [ordered]@{ LastRun = (Get-Date -Format 'o'); Status = $status; ScriptVersion = $SCRIPT_VERSION }
    foreach ($k in $vals.Keys) { Set-ItemProperty -Path $RegPath -Name $k -Value $vals[$k] -Type String -ErrorAction Stop }
    $nums = [ordered]@{ MBFreed = [int][math]::Round($totalFreed / 1MB); MBMeasured = [int][math]::Round($totalBefore / 1MB); UsersCleared = $usersCleared; UsersSkipped = $usersSkipped; LockedFiles = $lockedTotal; BudgetHit = [int]$script:BudgetHit; WhatIf = [int]$WhatIf }
    foreach ($k in $nums.Keys) { Set-ItemProperty -Path $RegPath -Name $k -Value ([int]$nums[$k]) -Type DWord -ErrorAction Stop }
} catch { Write-Output "  [Warning] Could not write $RegPath : $($_.Exception.Message)" }
exit $exitCode