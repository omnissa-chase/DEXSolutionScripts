# Generates the Clear-<App>Cache.ps1 family from one engine template plus a per-app catalogue.
# Re-run after editing the template or a catalogue; every generated file is overwritten.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent   # repository root; this file lives in AutomatedTesting\Tools
$date = '2026-11-12'

$template = @'
<#
.SYNOPSIS
    Clear-__KEY__Cache -- clears the __PRODUCT__ cache folders for the signed-in user (or every
    user), skipping any user whose __PRODUCT__ is running. Action script: no threshold, no
    detection, it clears what it is pointed at and reports what it freed.

.DESCRIPTION
    Hub runs this as SYSTEM, so per-user paths are built from each profile's folder under
    ProfileList, never from the SYSTEM environment. Only the folders listed below are
    touched, and only their contents (the folders themselves stay, so the app finds them).
    Anything not listed is never read or deleted.

    Clears (per user):
__CLEARS__

    Never touches:
__NEVER__

    Gate: __GATE__ When the app is running for a user that user is skipped and reported,
    unless CloseApp=true, in which case the app is asked to close (CloseMainWindow, up to
    20 s) and the user is still skipped if it stays open. Nothing is ever killed.

    Budget: stops deleting after 50 s and reports Partial, so Hub's 60 s timeout never
    cuts the report off. The next run finishes the job.

    Variables (Workspace ONE script variables, read from the environment):
      WhatIf                   true  -> report sizes, delete nothing             (default false)
      CloseApp                 true  -> ask a running __PRODUCT__ to close first (default false)
      Users                    Console (signed-in user, default) or All (every local profile)
      IncludeOptional          true  -> also clear the entries marked optional   (default false)
__DESTRUCTIVE_DOC__
    Output: one line per user ([Cleared], [WhatIf], [Skipped] with the reason) and a summary.
    Cache: HKLM\Software\AirWatch\Extensions\AppCache\__KEY__ (LastRun, Status, MBFreed,
    UsersCleared, UsersSkipped, LockedFiles, BudgetHit, WhatIf). Exit 0 unless the script
    itself fails (exit 1, Status Error). Runs unchanged on Windows PowerShell 5.1 and
    PowerShell 7.

.NOTES
    Script Name  : Clear-__KEY__Cache.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: __DATE__
    Timeout      : 60 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

#Requires -Version 5.1

$SCRIPT_VERSION = '1.0.0'
$Product   = '__PRODUCT__'
$RegPath   = 'HKLM:\Software\AirWatch\Extensions\AppCache\__KEY__'
$LogPath   = "$env:SystemRoot\Temp\UEM_Clear__KEY__Cache.log"
$BudgetSec = 50
$CloseWaitSec = 20
$RequiresDestructiveFlag = __DESTRUCTIVE__

# Process names (no .exe) that hold the cache open. Empty: no gate.
$ProcessNames = @(__PROCESSES__)
# Install markers: any one present (for the machine or for a target user) means the product is installed.
# Tokens: {Profile} {Local} {Roaming} {Packages} {PF} {PF86}. Wildcards allowed.
$InstallMarkers = @(__MARKERS__)
# Catalogue: folders whose CONTENTS are cleared. Exclude is a regex on the resolved folder path.
$Catalogue = @(
__CATALOGUE__
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
Write-Output "[$RunEventId] Executing Clear-__KEY__Cache, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIf CloseApp=$CloseApp Users=$UsersMode IncludeOptional=$IncludeOptional"
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
'@

function Q([string[]]$Items) { return (($Items | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ', ') }
function Lines([string[]]$Items, [string]$Indent = '      ') { return (($Items | ForEach-Object { "$Indent- $_" }) -join "`r`n") }
function Entry([string]$Name, [string[]]$Paths, [bool]$Optional = $false, [string]$Exclude = '') {
    $ex = if ($Exclude) { "; Exclude = '$Exclude'" } else { '' }
    return "    @{ Name = '$Name'; Paths = @($(Q $Paths)); Optional = `$$($Optional.ToString().ToLower())$ex }"
}


$apps = @(
    @{
        Key = 'Chrome'; Product = 'Google Chrome'; Dir = 'ApplicationSpecific\Chrome'
        Processes = @('chrome')
        Markers = @('{Local}\Google\Chrome\User Data', '{PF}\Google\Chrome\Application\chrome.exe', '{PF86}\Google\Chrome\Application\chrome.exe')
        Catalogue = @(
            (Entry 'Profile caches' @('{Local}\Google\Chrome\User Data\*\Cache', '{Local}\Google\Chrome\User Data\*\Code Cache', '{Local}\Google\Chrome\User Data\*\GPUCache', '{Local}\Google\Chrome\User Data\*\DawnGraphiteCache', '{Local}\Google\Chrome\User Data\*\DawnWebGPUCache')),
            (Entry 'Shader caches' @('{Local}\Google\Chrome\User Data\ShaderCache', '{Local}\Google\Chrome\User Data\GrShaderCache', '{Local}\Google\Chrome\User Data\GraphiteDawnCache')),
            (Entry 'Service worker storage (web apps rebuild it; may drop offline content)' @('{Local}\Google\Chrome\User Data\*\Service Worker\CacheStorage', '{Local}\Google\Chrome\User Data\*\Service Worker\ScriptCache') $true)
        )
        Clears = @('Cache, Code Cache, GPUCache and the Dawn GPU caches of every profile (Default, Profile 1, ...)', 'ShaderCache, GrShaderCache and GraphiteDawnCache under User Data', 'optional: Service Worker CacheStorage and ScriptCache (web apps rebuild them, offline content is lost)')
        Never = @('Cookies, Login Data, History, Bookmarks, Preferences, Local Storage, Session Storage, Sessions', 'Extensions and their storage', 'anything outside User Data')
        Gate = 'chrome.exe.'
    },
    @{
        Key = 'Edge'; Product = 'Microsoft Edge'; Dir = 'ApplicationSpecific\Microsoft\Edge'
        Processes = @('msedge')
        Markers = @('{Local}\Microsoft\Edge\User Data', '{PF86}\Microsoft\Edge\Application\msedge.exe', '{PF}\Microsoft\Edge\Application\msedge.exe')
        Catalogue = @(
            (Entry 'Profile caches' @('{Local}\Microsoft\Edge\User Data\*\Cache', '{Local}\Microsoft\Edge\User Data\*\Code Cache', '{Local}\Microsoft\Edge\User Data\*\GPUCache', '{Local}\Microsoft\Edge\User Data\*\DawnGraphiteCache', '{Local}\Microsoft\Edge\User Data\*\DawnWebGPUCache')),
            (Entry 'Shader caches' @('{Local}\Microsoft\Edge\User Data\ShaderCache', '{Local}\Microsoft\Edge\User Data\GrShaderCache', '{Local}\Microsoft\Edge\User Data\GraphiteDawnCache')),
            (Entry 'Service worker storage (web apps rebuild it; may drop offline content)' @('{Local}\Microsoft\Edge\User Data\*\Service Worker\CacheStorage', '{Local}\Microsoft\Edge\User Data\*\Service Worker\ScriptCache') $true)
        )
        Clears = @('Cache, Code Cache, GPUCache and the Dawn GPU caches of every profile', 'ShaderCache, GrShaderCache and GraphiteDawnCache under User Data', 'optional: Service Worker CacheStorage and ScriptCache')
        Never = @('Cookies, Login Data, History, Bookmarks, Preferences, Local Storage, Session Storage, Sessions, Collections', 'Extensions and their storage', 'the WebView2 runtime caches other apps own (Teams, Outlook new) -- those have their own scripts')
        Gate = 'msedge.exe.'
    },
    @{
        Key = 'Teams'; Product = 'Microsoft Teams'; Dir = 'ApplicationSpecific\Microsoft\Teams'
        Processes = @('Teams', 'ms-teams', 'msteams')
        Markers = @('{Local}\Microsoft\Teams\Update.exe', '{Packages}\MSTeams_8wekyb3d8bbwe')
        Catalogue = @(
            (Entry 'Classic Teams caches (same list as Invoke-AutoRemediateTeams step 1)' @('{Roaming}\Microsoft\Teams\Cache', '{Roaming}\Microsoft\Teams\blob_storage', '{Roaming}\Microsoft\Teams\IndexedDB', '{Roaming}\Microsoft\Teams\databases', '{Roaming}\Microsoft\Teams\Code Cache', '{Roaming}\Microsoft\Teams\GPUCache')),
            (Entry 'New Teams WebView2 caches' @('{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*\Cache', '{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*\Code Cache', '{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*\GPUCache', '{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*\DawnGraphiteCache', '{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*\DawnWebGPUCache', '{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\ShaderCache', '{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\GrShaderCache', '{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\GPUPersistentCache'))
        )
        Clears = @('classic Teams: Cache, blob_storage, IndexedDB, databases, Code Cache, GPUCache under %AppData%\Microsoft\Teams (the list the remediation already clears)', 'new Teams: Cache, Code Cache, GPUCache and Dawn caches of each WebView2 profile plus the shared shader caches under the MSTeams package LocalCache')
        Never = @('new Teams Local Storage, IndexedDB and Session Storage (drafts, state)', 'sign-in tokens (IdentityCache, OneAuth, the classic Teams Local Storage) -- the remediation has a gated step for those', 'Teams logs and the package itself')
        Gate = 'Teams.exe (classic) and ms-teams.exe (new).'
    },
    @{
        Key = 'Zoom'; Product = 'Zoom'; Dir = 'ApplicationSpecific\Zoom'
        Processes = @('Zoom')
        Markers = @('{Roaming}\Zoom\bin\Zoom.exe', '{Roaming}\Zoom\data')
        Catalogue = @(
            (Entry 'Data cache' @('{Roaming}\Zoom\data\cache')),
            (Entry 'Logs' @('{Roaming}\Zoom\logs'))
        )
        Clears = @('%AppData%\Zoom\data\cache (the data cache subfolder only)', '%AppData%\Zoom\logs')
        Never = @('the rest of %AppData%\Zoom\data: SQLite databases, zoomus.conf, the SSO token store', 'the Zoom binaries under %AppData%\Zoom\bin')
        Gate = 'Zoom.exe.'
    },
    @{
        Key = 'Office'; Product = 'Microsoft Office'; Dir = 'ApplicationSpecific\Microsoft\Office'
        Processes = @('WINWORD', 'EXCEL', 'POWERPNT', 'MSACCESS', 'ONENOTE', 'MSPUB', 'OUTLOOK', 'MSOSYNC')
        Markers = @('{PF}\Microsoft Office\root\Office16\WINWORD.EXE', '{PF86}\Microsoft Office\root\Office16\WINWORD.EXE', '{Local}\Microsoft\Office\16.0')
        Catalogue = @(
            (Entry 'Office Document Cache (Upload Center)' @('{Local}\Microsoft\Office\16.0\OfficeFileCache')),
            (Entry 'Web service and Backstage caches' @('{Local}\Microsoft\Office\16.0\WebServiceCache', '{Local}\Microsoft\Office\16.0\BackstageInAppNavCache')),
            (Entry 'Office temporary internet files' @('{Local}\Microsoft\Windows\INetCache\Content.MSO', '{Local}\Microsoft\Windows\INetCache\Content.Word')),
            (Entry 'Web add-in cache (add-ins re-download, may ask to sign in again)' @('{Local}\Microsoft\Office\16.0\Wef') $true)
        )
        Clears = @('OfficeFileCache (the Office Document Cache; pending uploads are lost, so the gate covers every Office process including Outlook and MSOSYNC)', 'WebServiceCache and BackstageInAppNavCache', 'INetCache\Content.MSO and Content.Word', 'optional: Wef (web add-in cache)')
        Never = @('Outlook OST and PST files (%LocalAppData%\Microsoft\Outlook): the mailbox, not a cache', '%AppData%\Microsoft\Office and \Templates and \UProof: recent files, custom dictionaries, templates', 'Licensing and identity folders')
        Gate = 'WINWORD, EXCEL, POWERPNT, MSACCESS, ONENOTE, MSPUB, OUTLOOK and MSOSYNC (all share the Document Cache).'
    },
    @{
        Key = 'OneNote'; Product = 'Microsoft OneNote'; Dir = 'ApplicationSpecific\Microsoft\OneNote'; Destructive = $true
        Processes = @('ONENOTE', 'ONENOTEM')
        Markers = @('{Local}\Microsoft\OneNote\16.0', '{PF}\Microsoft Office\root\Office16\ONENOTE.EXE', '{PF86}\Microsoft Office\root\Office16\ONENOTE.EXE')
        Catalogue = @(
            (Entry 'Notebook cache (rebuilt from the server; unsynced edits are lost)' @('{Local}\Microsoft\OneNote\16.0\cache'))
        )
        Clears = @('%LocalAppData%\Microsoft\OneNote\16.0\cache, only with AllowDestructiveActions=true (without it the script reports the size and clears nothing): the cache holds notebook content until it has synced, so clear it only when OneNote shows no sync errors')
        Never = @('%LocalAppData%\Microsoft\OneNote\16.0\Backup (local notebook backups)', '%AppData%\Microsoft\OneNote (settings, recent notebooks)')
        Gate = 'ONENOTE.exe and ONENOTEM.exe.'
    },
    @{
        Key = 'VSCode'; Product = 'Visual Studio Code'; Dir = 'ApplicationSpecific\Microsoft\VSCode'
        Processes = @('Code', 'Code - Insiders')
        Markers = @('{Roaming}\Code', '{Roaming}\Code - Insiders', '{Local}\Programs\Microsoft VS Code\Code.exe', '{PF}\Microsoft VS Code\Code.exe')
        Catalogue = @(
            (Entry 'Electron and renderer caches' @('{Roaming}\Code\Cache', '{Roaming}\Code\Code Cache', '{Roaming}\Code\GPUCache', '{Roaming}\Code\DawnGraphiteCache', '{Roaming}\Code\DawnWebGPUCache', '{Roaming}\Code - Insiders\Cache', '{Roaming}\Code - Insiders\Code Cache', '{Roaming}\Code - Insiders\GPUCache', '{Roaming}\Code - Insiders\DawnGraphiteCache', '{Roaming}\Code - Insiders\DawnWebGPUCache')),
            (Entry 'VS Code data caches (rebuilt on launch)' @('{Roaming}\Code\CachedData', '{Roaming}\Code\CachedExtensionVSIXs', '{Roaming}\Code\CachedProfilesData', '{Roaming}\Code - Insiders\CachedData', '{Roaming}\Code - Insiders\CachedExtensionVSIXs', '{Roaming}\Code - Insiders\CachedProfilesData')),
            (Entry 'Service worker storage and crash reports' @('{Roaming}\Code\Service Worker\CacheStorage', '{Roaming}\Code\Service Worker\ScriptCache', '{Roaming}\Code\Crashpad\reports', '{Roaming}\Code - Insiders\Service Worker\CacheStorage', '{Roaming}\Code - Insiders\Service Worker\ScriptCache', '{Roaming}\Code - Insiders\Crashpad\reports')),
            (Entry 'Logs and cached configurations' @('{Roaming}\Code\logs', '{Roaming}\Code\CachedConfigurations', '{Roaming}\Code - Insiders\logs', '{Roaming}\Code - Insiders\CachedConfigurations') $true)
        )
        Clears = @('Cache, Code Cache, GPUCache, Dawn caches under %AppData%\Code (and Code - Insiders)', 'CachedData, CachedExtensionVSIXs, CachedProfilesData', 'Service Worker CacheStorage and ScriptCache, Crashpad reports', 'optional: logs and CachedConfigurations')
        Never = @('%AppData%\Code\User: settings, keybindings, snippets, globalStorage, workspaceStorage, History', '%AppData%\Code\Backups: hot-exit copies of unsaved files', 'Local Storage and Session Storage (window state, sign-ins)', '%UserProfile%\.vscode\extensions')
        Gate = 'Code.exe (stable and Insiders).'
    },
    @{
        Key = 'Claude'; Product = 'Claude (desktop app and Claude Code)'; Dir = 'ApplicationSpecific\Anthropic\Claude'
        Processes = @('Claude', 'claude')
        Markers = @('{Roaming}\Claude', '{Local}\AnthropicClaude', '{Profile}\.claude')
        Catalogue = @(
            (Entry 'Claude desktop app caches' @('{Roaming}\Claude\Cache', '{Roaming}\Claude\Code Cache', '{Roaming}\Claude\GPUCache', '{Roaming}\Claude\DawnGraphiteCache', '{Roaming}\Claude\DawnWebGPUCache', '{Roaming}\Claude\Service Worker\CacheStorage', '{Roaming}\Claude\Service Worker\ScriptCache')),
            (Entry 'Claude desktop app logs' @('{Roaming}\Claude\logs')),
            (Entry 'Claude Code debug logs' @('{Profile}\.claude\debug')),
            (Entry 'Claude desktop installer packages (old updates kept by the installer)' @('{Local}\AnthropicClaude\packages') $true)
        )
        Clears = @('Claude desktop app: Cache, Code Cache, GPUCache, Dawn caches, Service Worker caches and logs under %AppData%\Claude', 'Claude Code: %UserProfile%\.claude\debug (debug logs)', 'optional: %LocalAppData%\AnthropicClaude\packages (downloaded update packages)')
        Never = @('%AppData%\Claude\Local Storage, Session Storage, IndexedDB and claude_desktop_config.json (sign-in, MCP configuration)', '%UserProfile%\.claude\projects, memory, settings*.json, plugins, shell-snapshots (conversation history, memory and configuration of Claude Code)', '%LocalAppData%\Temp\claude: live session scratch folders', 'the installed app under %LocalAppData%\AnthropicClaude\app-*')
        Gate = 'Claude.exe (desktop app) and claude.exe (Claude Code).'
    },
    @{
        Key = 'GitHubDesktop'; Product = 'GitHub Desktop'; Dir = 'ApplicationSpecific\GitHub'
        Processes = @('GitHubDesktop')
        Markers = @('{Roaming}\GitHub Desktop', '{Local}\GitHubDesktop\GitHubDesktop.exe')
        Catalogue = @(
            (Entry 'Electron caches' @('{Roaming}\GitHub Desktop\Cache', '{Roaming}\GitHub Desktop\Code Cache', '{Roaming}\GitHub Desktop\GPUCache', '{Roaming}\GitHub Desktop\DawnGraphiteCache', '{Roaming}\GitHub Desktop\DawnWebGPUCache')),
            (Entry 'Logs' @('{Roaming}\GitHub Desktop\logs')),
            (Entry 'Installer packages (old updates kept by the installer)' @('{Local}\GitHubDesktop\packages') $true)
        )
        Clears = @('Cache, Code Cache, GPUCache, Dawn caches and logs under %AppData%\GitHub Desktop', 'optional: %LocalAppData%\GitHubDesktop\packages (downloaded update packages)')
        Never = @('%AppData%\GitHub Desktop\Local Storage and IndexedDB (accounts, repository list, settings)', 'the installed app under %LocalAppData%\GitHubDesktop\app-*', 'Git itself: repositories, .gitconfig, Git Credential Manager stores')
        Gate = 'GitHubDesktop.exe.'
    },
    @{
        Key = 'VisualStudio'; Product = 'Visual Studio'; Dir = 'ApplicationSpecific\Microsoft\VisualStudio'
        Processes = @('devenv')
        Markers = @('{Local}\Microsoft\VisualStudio\1*.0_*', '{PF}\Microsoft Visual Studio', '{PF86}\Microsoft Visual Studio')
        Catalogue = @(
            (Entry 'MEF component model cache (the classic fix for a broken IDE)' @('{Local}\Microsoft\VisualStudio\1*.0_*\ComponentModelCache')),
            (Entry 'Designer shadow cache' @('{Local}\Microsoft\VisualStudio\1*.0_*\Designer\ShadowCache')),
            (Entry 'Web project cache' @('{Local}\Microsoft\WebsiteCache')),
            (Entry 'Telemetry and feedback logs' @('{Local}\Microsoft\VSApplicationInsights', '{Local}\Microsoft\VisualStudio\1*.0_*\ActivityLog*') $true)
        )
        Clears = @('ComponentModelCache of every VS instance (%LocalAppData%\Microsoft\VisualStudio\<ver>_<id>)', 'Designer\ShadowCache', '%LocalAppData%\Microsoft\WebsiteCache', 'optional: VSApplicationInsights and ActivityLog files')
        Never = @('Extensions, Settings and privateregistry.bin of each instance', '%AppData%\Microsoft\VisualStudio', 'project .vs folders, solutions and the installer under Program Files')
        Gate = 'devenv.exe.'
    },
    @{
        Key = 'JetBrains'; Product = 'JetBrains IDEs'; Dir = 'ApplicationSpecific\JetBrains'
        Processes = @('idea64', 'pycharm64', 'webstorm64', 'rider64', 'clion64', 'goland64', 'phpstorm64', 'datagrip64', 'rubymine64', 'dataspell64', 'fleet')
        Markers = @('{Local}\JetBrains')
        Catalogue = @(
            (Entry 'IDE caches and indexes (rebuilt on the next open)' @('{Local}\JetBrains\*\caches') $false '(?i)\\Toolbox\\'),
            (Entry 'IDE temp folders' @('{Local}\JetBrains\*\tmp') $false '(?i)\\Toolbox\\'),
            (Entry 'IDE logs' @('{Local}\JetBrains\*\log') $true '(?i)\\Toolbox\\')
        )
        Clears = @('%LocalAppData%\JetBrains\<Product><version>\caches (indexes rebuild on the next open; the first open after a clear is slow)', '%LocalAppData%\JetBrains\<Product><version>\tmp', 'optional: the log folders')
        Never = @('%AppData%\JetBrains: options, keymaps, plugins, colour schemes', 'the Toolbox app and the IDEs it installs (%LocalAppData%\JetBrains\Toolbox)', 'projects and their .idea folders')
        Gate = 'idea64, pycharm64, webstorm64, rider64, clion64, goland64, phpstorm64, datagrip64, rubymine64, dataspell64 and fleet.'
    },
    @{
        Key = 'DevPackage'; Product = 'developer package-manager caches'; Dir = 'ApplicationSpecific\DeveloperTools'
        Processes = @()
        Markers = @('{Local}\npm-cache', '{Local}\Yarn', '{Local}\pip', '{Local}\NuGet', '{Local}\go-build', '{Local}\pnpm', '{Profile}\.gradle', '{Profile}\.m2', '{Profile}\.cargo')
        Catalogue = @(
            (Entry 'npm cache and logs' @('{Local}\npm-cache\_cacache', '{Local}\npm-cache\_logs')),
            (Entry 'Yarn cache' @('{Local}\Yarn\Cache')),
            (Entry 'pip cache' @('{Local}\pip\cache')),
            (Entry 'NuGet HTTP and plugin caches' @('{Local}\NuGet\v3-cache', '{Local}\NuGet\plugins-cache', '{Local}\NuGet\Cache')),
            (Entry 'Go build cache' @('{Local}\go-build')),
            (Entry 'NuGet global packages folder (every project restores again)' @('{Profile}\.nuget\packages') $true),
            (Entry 'Gradle caches (dependencies download again)' @('{Profile}\.gradle\caches') $true),
            (Entry 'Maven local repository (dependencies download again)' @('{Profile}\.m2\repository') $true),
            (Entry 'Cargo registry cache' @('{Profile}\.cargo\registry\cache') $true),
            (Entry 'pnpm content-addressable store' @('{Local}\pnpm\store', '{Local}\pnpm-cache') $true)
        )
        Clears = @('npm: %LocalAppData%\npm-cache\_cacache and _logs', 'Yarn: %LocalAppData%\Yarn\Cache', 'pip: %LocalAppData%\pip\cache', 'NuGet: v3-cache, plugins-cache, Cache under %LocalAppData%\NuGet', 'Go: %LocalAppData%\go-build', 'optional (IncludeOptional=true, large and slow to rebuild): ~\.nuget\packages, ~\.gradle\caches, ~\.m2\repository, ~\.cargo\registry\cache, the pnpm store')
        Never = @('global installs: %AppData%\npm\node_modules, ~\.cargo\bin, ~\go\bin, pipx and venv folders', 'configuration: .npmrc, NuGet.Config, ~\.gradle\gradle.properties, ~\.m2\settings.xml, ~\.cargo\config', 'Gradle wrapper distributions (~\.gradle\wrapper)', 'project folders and their node_modules')
        Gate = 'none (package managers hold no long-lived process); a file a running install holds is counted as locked and left.'
    }
)

$written = @()
foreach ($a in $apps) {
    $destructive = [bool]$a.Destructive
    $t = $template
    $t = $t.Replace('__KEY__', $a.Key).Replace('__PRODUCT__', $a.Product).Replace('__DATE__', $date)
    $t = $t.Replace('__CLEARS__', (Lines $a.Clears)).Replace('__NEVER__', (Lines $a.Never)).Replace('__GATE__', $a.Gate)
    $t = $t.Replace('__PROCESSES__', (Q $a.Processes)).Replace('__MARKERS__', (Q $a.Markers))
    $t = $t.Replace('__CATALOGUE__', ($a.Catalogue -join ",`r`n"))
    $t = $t.Replace('__DESTRUCTIVE__', $(if ($destructive) { '$true' } else { '$false' }))
    $t = $t.Replace('__DESTRUCTIVE_DOC__', $(if ($destructive) { "      AllowDestructiveActions  true  -> actually clear; without it the script only reports sizes`r`n" } else { '' }))
    $dir = Join-Path $repo $a.Dir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir "Clear-$($a.Key)Cache.ps1"
    [IO.File]::WriteAllText($path, $t, (New-Object Text.UTF8Encoding($false)))
    $e = $null; [void][Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$e)
    "{0,-70} {1,6} chars  parse errors {2}" -f $path.Replace("$repo\", ''), $t.Length, $e.Count
    $written += $path
}
"$($written.Count) scripts written"

# ==============================================================================
# Sensors: <app>_cache_mb (Integer, recurring) for the caches that grow large, and the
# one-time JSON app_cache_health across every product.
# ==============================================================================
$sizeApps = @{ Chrome = 500; Edge = 500; Teams = 500; VSCode = 1000; Office = 1000; JetBrains = 2000; DevPackage = 2000 }
$warnMb   = @{ Chrome = 500; Edge = 500; Teams = 500; Zoom = 300; Office = 1000; OneNote = 2000; VSCode = 1000; Claude = 300; GitHubDesktop = 300; VisualStudio = 500; JetBrains = 2000; DevPackage = 2000 }

$measureBlock = @'
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
function Get-ConsoleUser {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if (-not $cs -or -not $cs.UserName) { return $null }
    try {
        $sid = ([Security.Principal.NTAccount]([string]$cs.UserName)).Translate([Security.Principal.SecurityIdentifier]).Value
        $p = [string](Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { return $null }
        return @{ Name = [string]$cs.UserName; Sid = $sid; Profile = $p; Local = "$p\AppData\Local"; Roaming = "$p\AppData\Roaming"; Packages = "$p\AppData\Local\Packages" }
    } catch { return $null }
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
function Measure-Catalogue { param($Catalogue, $User, [switch]$IncludeOptional)
    $bytes = [long]0; $folders = 0
    foreach ($e in @($Catalogue | Where-Object { -not $_.Optional -or $IncludeOptional })) {
        foreach ($pat in @($e.Paths)) { foreach ($f in (Resolve-Folders $pat $User $e.Exclude)) { $bytes += Measure-Folder $f; $folders++ } }
    }
    return @{ Bytes = $bytes; Folders = $folders }
}
function Test-Installed { param($Markers, $User)
    foreach ($m in $Markers) { if (Test-Marker $m $null) { return $true } }
    if ($User) { foreach ($m in $Markers) { if (Test-Marker $m $User) { return $true } } }
    return $false
}
'@

$sizeTemplate = @'
<#
.SYNOPSIS
    __LKEY___cache_mb -- size in MB of the __PRODUCT__ cache folders that Clear-__KEY__Cache.ps1
    would clear for the signed-in user (the non-optional catalogue entries).

.DESCRIPTION
    Integer sensor. Measures the same folders as the clear script, for the console user only
    (per-user data; Hub runs the sensor as SYSTEM, so the profile path comes from ProfileList).
    -1 when __PRODUCT__ is not installed or no user is signed in. 0 when installed and empty.
    A value at or above __WARN__ MB is where the clear script earns its keep.

.NOTES
    Sensor Name  : __LKEY___cache_mb
    Data Type    : Integer
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: __DATE__
    Timeout      : 30 seconds
    Companion    : Clear-__KEY__Cache.ps1 (same catalogue), app_cache_health.ps1 (all products)

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
#Requires -Version 5.1
$InstallMarkers = @(__MARKERS__)
$Catalogue = @(
__CATALOGUE__
)
__MEASURE__
$u = Get-ConsoleUser
if (-not $u -or -not (Test-Installed $InstallMarkers $u)) { Write-Output -1; exit 0 }
$m = Measure-Catalogue $Catalogue $u
Write-Output ([int][math]::Round($m.Bytes / 1MB))
exit 0
'@

foreach ($a in $apps) {
    if (-not $sizeApps.ContainsKey($a.Key)) { continue }
    $t = $sizeTemplate.Replace('__KEY__', $a.Key).Replace('__LKEY__', $a.Key.ToLower()).Replace('__PRODUCT__', $a.Product).Replace('__DATE__', $date).Replace('__WARN__', [string]$sizeApps[$a.Key])
    $t = $t.Replace('__MARKERS__', (Q $a.Markers)).Replace('__CATALOGUE__', ($a.Catalogue -join ",`r`n")).Replace('__MEASURE__', $measureBlock)
    $dir = Join-Path (Join-Path $repo $a.Dir) 'Sensors'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir "$($a.Key.ToLower())_cache_mb.ps1"
    [IO.File]::WriteAllText($path, $t, (New-Object Text.UTF8Encoding($false)))
    $e = $null; [void][Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$e)
    "{0,-70} {1,6} chars  parse errors {2}" -f $path.Replace("$repo\", ''), $t.Length, $e.Count
}

$healthTemplate = @'
<#
.SYNOPSIS
    app_cache_health -- one-time JSON sensor: the cache footprint of every product that has a
    Clear-<App>Cache.ps1, for the signed-in user, with the last clear's outcome.

.DESCRIPTION
    For each product: installed or not, MB in the folders its clear script would clear (the
    non-optional catalogue), folder count, whether the gated process is running right now, and
    the last clear from HKLM\Software\AirWatch\Extensions\AppCache\<App> (Status and MB freed).
    Over lists the products at or above their threshold (the same thresholds the size sensors
    document), which is the shortlist for a clear. Products that are not installed are omitted.

    One line of compact JSON, kept under Hub's 1 KB sensor cap by a trim ladder (last-clear
    detail first, then folder counts, then products under 1 MB). Keys:
      Schema 1, User, At, Ms, TotalMb, Over [names], Apps { <App>: { Mb, N (folders), Run (0/1),
      Last "<Status> <MM-dd> <MB>" } }, TO (true when the 25 s budget cut the measurement short).
    Run on demand from the DEX console; MUST NOT be scheduled as a recurring sensor.

.NOTES
    Sensor Name  : app_cache_health
    Data Type    : String (JSON)
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: __DATE__
    Timeout      : One-time / run-once only. Self-enforced 25 s budget, 30 s UEM ceiling.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
#Requires -Version 5.1
$Deadline = (Get-Date).AddSeconds(25)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$Products = @(
__PRODUCTS__
)
__MEASURE__
$u = Get-ConsoleUser
$o = [ordered]@{ Schema = 1; User = $(if ($u) { $u.Name } else { '' }); At = (Get-Date -Format 's'); Ms = 0; TotalMb = 0; Over = @(); Apps = [ordered]@{}; TO = $false }
$total = [long]0
foreach ($p in $Products) {
    if ((Get-Date) -gt $Deadline) { $o.TO = $true; break }
    if (-not $u -or -not (Test-Installed $p.Markers $u)) { continue }
    $m = Measure-Catalogue $p.Catalogue $u
    $mb = [int][math]::Round($m.Bytes / 1MB); $total += $m.Bytes
    $run = 0; if ($p.Processes.Count -gt 0 -and @(Get-Process -Name $p.Processes -ErrorAction SilentlyContinue).Count -gt 0) { $run = 1 }
    $last = ''
    try { $r = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\AppCache\$($p.Key)" -ErrorAction Stop; $d = ''; try { $d = ([datetime]$r.LastRun).ToString('MM-dd') } catch { }; $last = "$($r.Status) $d $($r.MBFreed)" } catch { }
    $o.Apps[$p.Key] = [ordered]@{ Mb = $mb; N = $m.Folders; Run = $run; Last = $last }
    if ($mb -ge $p.WarnMb) { $o.Over += $p.Key }
}
$o.TotalMb = [int][math]::Round($total / 1MB)
$o.Ms = [int]$sw.ElapsedMilliseconds
$j = $o | ConvertTo-Json -Depth 4 -Compress
if ($j.Length -gt 1000) { foreach ($k in @($o.Apps.Keys)) { $o.Apps[$k].Remove('Last') }; $j = $o | ConvertTo-Json -Depth 4 -Compress }
if ($j.Length -gt 1000) { foreach ($k in @($o.Apps.Keys)) { $o.Apps[$k].Remove('N') }; $j = $o | ConvertTo-Json -Depth 4 -Compress }
if ($j.Length -gt 1000) { foreach ($k in @($o.Apps.Keys)) { if ($o.Apps[$k].Mb -lt 1) { $o.Apps.Remove($k) } }; $j = $o | ConvertTo-Json -Depth 4 -Compress }
if ($j.Length -gt 1000) { $j = '{"Schema":1,"User":"' + $o.User + '","TotalMb":' + $o.TotalMb + ',"Over":' + ($o.Over | ConvertTo-Json -Compress) + ',"Apps":{},"TO":true}' }
Write-Output $j
exit 0
'@

$prodLines = @()
foreach ($a in $apps) {
    $cat = ($a.Catalogue | ForEach-Object { $_.Trim() }) -join ', '
    $prodLines += "    @{ Key = '$($a.Key)'; WarnMb = $($warnMb[$a.Key]); Processes = @($(Q $a.Processes)); Markers = @($(Q $a.Markers)); Catalogue = @($cat) }"
}
$t = $healthTemplate.Replace('__DATE__', $date).Replace('__PRODUCTS__', ($prodLines -join ",`r`n")).Replace('__MEASURE__', $measureBlock)
$dir = Join-Path $repo 'ApplicationSpecific\OneTimeSensor'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$path = Join-Path $dir 'app_cache_health.ps1'
[IO.File]::WriteAllText($path, $t, (New-Object Text.UTF8Encoding($false)))
$e = $null; [void][Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$e)
"{0,-70} {1,6} chars  parse errors {2}" -f $path.Replace("$repo\", ''), $t.Length, $e.Count
