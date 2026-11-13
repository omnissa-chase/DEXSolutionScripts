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
    Version      : 1.1.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
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
    @{ Key = 'Chrome'; WarnMb = 500; Processes = @('chrome'); Markers = @('{Local}\Google\Chrome\User Data', '{PF}\Google\Chrome\Application\chrome.exe', '{PF86}\Google\Chrome\Application\chrome.exe'); Catalogue = @(@{ Name = 'Profile caches'; Paths = @('{Local}\Google\Chrome\User Data\*\Cache', '{Local}\Google\Chrome\User Data\*\Code Cache', '{Local}\Google\Chrome\User Data\*\GPUCache', '{Local}\Google\Chrome\User Data\*\DawnGraphiteCache', '{Local}\Google\Chrome\User Data\*\DawnWebGPUCache'); Optional = $false }, @{ Name = 'Shader caches'; Paths = @('{Local}\Google\Chrome\User Data\ShaderCache', '{Local}\Google\Chrome\User Data\GrShaderCache', '{Local}\Google\Chrome\User Data\GraphiteDawnCache'); Optional = $false }, @{ Name = 'Service worker storage (web apps rebuild it; may drop offline content)'; Paths = @('{Local}\Google\Chrome\User Data\*\Service Worker\CacheStorage', '{Local}\Google\Chrome\User Data\*\Service Worker\ScriptCache'); Optional = $true }) },
    @{ Key = 'Edge'; WarnMb = 500; Processes = @('msedge'); Markers = @('{Local}\Microsoft\Edge\User Data', '{PF86}\Microsoft\Edge\Application\msedge.exe', '{PF}\Microsoft\Edge\Application\msedge.exe'); Catalogue = @(@{ Name = 'Profile caches'; Paths = @('{Local}\Microsoft\Edge\User Data\*\Cache', '{Local}\Microsoft\Edge\User Data\*\Code Cache', '{Local}\Microsoft\Edge\User Data\*\GPUCache', '{Local}\Microsoft\Edge\User Data\*\DawnGraphiteCache', '{Local}\Microsoft\Edge\User Data\*\DawnWebGPUCache'); Optional = $false }, @{ Name = 'Shader caches'; Paths = @('{Local}\Microsoft\Edge\User Data\ShaderCache', '{Local}\Microsoft\Edge\User Data\GrShaderCache', '{Local}\Microsoft\Edge\User Data\GraphiteDawnCache'); Optional = $false }, @{ Name = 'Service worker storage (web apps rebuild it; may drop offline content)'; Paths = @('{Local}\Microsoft\Edge\User Data\*\Service Worker\CacheStorage', '{Local}\Microsoft\Edge\User Data\*\Service Worker\ScriptCache'); Optional = $true }) },
    @{ Key = 'Teams'; WarnMb = 500; Processes = @('Teams', 'ms-teams', 'msteams'); Markers = @('{Local}\Microsoft\Teams\Update.exe', '{Packages}\MSTeams_8wekyb3d8bbwe'); Catalogue = @(@{ Name = 'Classic Teams caches (same list as Invoke-AutoRemediateTeams step 1)'; Paths = @('{Roaming}\Microsoft\Teams\Cache', '{Roaming}\Microsoft\Teams\blob_storage', '{Roaming}\Microsoft\Teams\IndexedDB', '{Roaming}\Microsoft\Teams\databases', '{Roaming}\Microsoft\Teams\Code Cache', '{Roaming}\Microsoft\Teams\GPUCache'); Optional = $false }, @{ Name = 'New Teams WebView2 caches'; Paths = @('{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*\Cache', '{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*\Code Cache', '{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*\GPUCache', '{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*\DawnGraphiteCache', '{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\*\DawnWebGPUCache', '{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\ShaderCache', '{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\GrShaderCache', '{Packages}\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\GPUPersistentCache'); Optional = $false }) },
    @{ Key = 'Zoom'; WarnMb = 300; Processes = @('Zoom'); Markers = @('{Roaming}\Zoom\bin\Zoom.exe', '{Roaming}\Zoom\data'); Catalogue = @(@{ Name = 'Data cache'; Paths = @('{Roaming}\Zoom\data\cache'); Optional = $false }, @{ Name = 'Logs'; Paths = @('{Roaming}\Zoom\logs'); Optional = $false }) },
    @{ Key = 'Office'; WarnMb = 1000; Processes = @('WINWORD', 'EXCEL', 'POWERPNT', 'MSACCESS', 'ONENOTE', 'MSPUB', 'OUTLOOK', 'MSOSYNC'); Markers = @('{PF}\Microsoft Office\root\Office16\WINWORD.EXE', '{PF86}\Microsoft Office\root\Office16\WINWORD.EXE', '{Local}\Microsoft\Office\16.0'); Catalogue = @(@{ Name = 'Office Document Cache (Upload Center)'; Paths = @('{Local}\Microsoft\Office\16.0\OfficeFileCache'); Optional = $false }, @{ Name = 'Web service and Backstage caches'; Paths = @('{Local}\Microsoft\Office\16.0\WebServiceCache', '{Local}\Microsoft\Office\16.0\BackstageInAppNavCache'); Optional = $false }, @{ Name = 'Office temporary internet files'; Paths = @('{Local}\Microsoft\Windows\INetCache\Content.MSO', '{Local}\Microsoft\Windows\INetCache\Content.Word'); Optional = $false }, @{ Name = 'Web add-in cache (add-ins re-download, may ask to sign in again)'; Paths = @('{Local}\Microsoft\Office\16.0\Wef'); Optional = $true }) },
    @{ Key = 'OneNote'; WarnMb = 2000; Processes = @('ONENOTE', 'ONENOTEM'); Markers = @('{Local}\Microsoft\OneNote\16.0', '{PF}\Microsoft Office\root\Office16\ONENOTE.EXE', '{PF86}\Microsoft Office\root\Office16\ONENOTE.EXE'); Catalogue = @(@{ Name = 'Notebook cache (rebuilt from the server; unsynced edits are lost)'; Paths = @('{Local}\Microsoft\OneNote\16.0\cache'); Optional = $false }) },
    @{ Key = 'VSCode'; WarnMb = 1000; Processes = @('Code', 'Code - Insiders'); Markers = @('{Roaming}\Code', '{Roaming}\Code - Insiders', '{Local}\Programs\Microsoft VS Code\Code.exe', '{PF}\Microsoft VS Code\Code.exe'); Catalogue = @(@{ Name = 'Electron and renderer caches'; Paths = @('{Roaming}\Code\Cache', '{Roaming}\Code\Code Cache', '{Roaming}\Code\GPUCache', '{Roaming}\Code\DawnGraphiteCache', '{Roaming}\Code\DawnWebGPUCache', '{Roaming}\Code - Insiders\Cache', '{Roaming}\Code - Insiders\Code Cache', '{Roaming}\Code - Insiders\GPUCache', '{Roaming}\Code - Insiders\DawnGraphiteCache', '{Roaming}\Code - Insiders\DawnWebGPUCache'); Optional = $false }, @{ Name = 'VS Code data caches (rebuilt on launch)'; Paths = @('{Roaming}\Code\CachedData', '{Roaming}\Code\CachedExtensionVSIXs', '{Roaming}\Code\CachedProfilesData', '{Roaming}\Code - Insiders\CachedData', '{Roaming}\Code - Insiders\CachedExtensionVSIXs', '{Roaming}\Code - Insiders\CachedProfilesData'); Optional = $false }, @{ Name = 'Service worker storage and crash reports'; Paths = @('{Roaming}\Code\Service Worker\CacheStorage', '{Roaming}\Code\Service Worker\ScriptCache', '{Roaming}\Code\Crashpad\reports', '{Roaming}\Code - Insiders\Service Worker\CacheStorage', '{Roaming}\Code - Insiders\Service Worker\ScriptCache', '{Roaming}\Code - Insiders\Crashpad\reports'); Optional = $false }, @{ Name = 'Logs and cached configurations'; Paths = @('{Roaming}\Code\logs', '{Roaming}\Code\CachedConfigurations', '{Roaming}\Code - Insiders\logs', '{Roaming}\Code - Insiders\CachedConfigurations'); Optional = $true }) },
    @{ Key = 'Claude'; WarnMb = 300; Processes = @('Claude', 'claude'); Markers = @('{Roaming}\Claude', '{Local}\AnthropicClaude', '{Profile}\.claude'); Catalogue = @(@{ Name = 'Claude desktop app caches'; Paths = @('{Roaming}\Claude\Cache', '{Roaming}\Claude\Code Cache', '{Roaming}\Claude\GPUCache', '{Roaming}\Claude\DawnGraphiteCache', '{Roaming}\Claude\DawnWebGPUCache', '{Roaming}\Claude\Service Worker\CacheStorage', '{Roaming}\Claude\Service Worker\ScriptCache'); Optional = $false }, @{ Name = 'Claude desktop app logs'; Paths = @('{Roaming}\Claude\logs'); Optional = $false }, @{ Name = 'Claude Code debug logs'; Paths = @('{Profile}\.claude\debug'); Optional = $false }, @{ Name = 'Claude desktop installer packages (old updates kept by the installer)'; Paths = @('{Local}\AnthropicClaude\packages'); Optional = $true }) },
    @{ Key = 'GitHubDesktop'; WarnMb = 300; Processes = @('GitHubDesktop'); Markers = @('{Roaming}\GitHub Desktop', '{Local}\GitHubDesktop\GitHubDesktop.exe'); Catalogue = @(@{ Name = 'Electron caches'; Paths = @('{Roaming}\GitHub Desktop\Cache', '{Roaming}\GitHub Desktop\Code Cache', '{Roaming}\GitHub Desktop\GPUCache', '{Roaming}\GitHub Desktop\DawnGraphiteCache', '{Roaming}\GitHub Desktop\DawnWebGPUCache'); Optional = $false }, @{ Name = 'Logs'; Paths = @('{Roaming}\GitHub Desktop\logs'); Optional = $false }, @{ Name = 'Installer packages (old updates kept by the installer)'; Paths = @('{Local}\GitHubDesktop\packages'); Optional = $true }) },
    @{ Key = 'VisualStudio'; WarnMb = 500; Processes = @('devenv'); Markers = @('{Local}\Microsoft\VisualStudio\1*.0_*', '{PF}\Microsoft Visual Studio', '{PF86}\Microsoft Visual Studio'); Catalogue = @(@{ Name = 'MEF component model cache (the classic fix for a broken IDE)'; Paths = @('{Local}\Microsoft\VisualStudio\1*.0_*\ComponentModelCache'); Optional = $false }, @{ Name = 'Designer shadow cache'; Paths = @('{Local}\Microsoft\VisualStudio\1*.0_*\Designer\ShadowCache'); Optional = $false }, @{ Name = 'Web project cache'; Paths = @('{Local}\Microsoft\WebsiteCache'); Optional = $false }, @{ Name = 'Telemetry and feedback logs'; Paths = @('{Local}\Microsoft\VSApplicationInsights', '{Local}\Microsoft\VisualStudio\1*.0_*\ActivityLog*'); Optional = $true }) },
    @{ Key = 'JetBrains'; WarnMb = 2000; Processes = @('idea64', 'pycharm64', 'webstorm64', 'rider64', 'clion64', 'goland64', 'phpstorm64', 'datagrip64', 'rubymine64', 'dataspell64', 'fleet'); Markers = @('{Local}\JetBrains'); Catalogue = @(@{ Name = 'IDE caches and indexes (rebuilt on the next open)'; Paths = @('{Local}\JetBrains\*\caches'); Optional = $false; Exclude = '(?i)\\Toolbox\\' }, @{ Name = 'IDE temp folders'; Paths = @('{Local}\JetBrains\*\tmp'); Optional = $false; Exclude = '(?i)\\Toolbox\\' }, @{ Name = 'IDE logs'; Paths = @('{Local}\JetBrains\*\log'); Optional = $true; Exclude = '(?i)\\Toolbox\\' }) },
    @{ Key = 'DevPackage'; WarnMb = 2000; Processes = @(); Markers = @('{Local}\npm-cache', '{Local}\Yarn', '{Local}\pip', '{Local}\NuGet', '{Local}\go-build', '{Local}\pnpm', '{Profile}\.gradle', '{Profile}\.m2', '{Profile}\.cargo'); Catalogue = @(@{ Name = 'npm cache and logs'; Paths = @('{Local}\npm-cache\_cacache', '{Local}\npm-cache\_logs'); Optional = $false }, @{ Name = 'Yarn cache'; Paths = @('{Local}\Yarn\Cache'); Optional = $false }, @{ Name = 'pip cache'; Paths = @('{Local}\pip\cache'); Optional = $false }, @{ Name = 'NuGet HTTP and plugin caches'; Paths = @('{Local}\NuGet\v3-cache', '{Local}\NuGet\plugins-cache', '{Local}\NuGet\Cache'); Optional = $false }, @{ Name = 'Go build cache'; Paths = @('{Local}\go-build'); Optional = $false }, @{ Name = 'NuGet global packages folder (every project restores again)'; Paths = @('{Profile}\.nuget\packages'); Optional = $true }, @{ Name = 'Gradle caches (dependencies download again)'; Paths = @('{Profile}\.gradle\caches'); Optional = $true }, @{ Name = 'Maven local repository (dependencies download again)'; Paths = @('{Profile}\.m2\repository'); Optional = $true }, @{ Name = 'Cargo registry cache'; Paths = @('{Profile}\.cargo\registry\cache'); Optional = $true }, @{ Name = 'pnpm content-addressable store'; Paths = @('{Local}\pnpm\store', '{Local}\pnpm-cache'); Optional = $true }) },
    @{ Key = 'Slack'; WarnMb = 300; Processes = @('slack'); Markers = @('{Local}\slack\app-*', '{Roaming}\Slack', '{Packages}\91750D7E.Slack_8wekyb3d8bbwe'); Catalogue = @(@{ Name = 'Electron caches'; Paths = @('{Roaming}\Slack\Cache', '{Roaming}\Slack\Code Cache', '{Roaming}\Slack\GPUCache', '{Roaming}\Slack\DawnGraphiteCache', '{Roaming}\Slack\DawnWebGPUCache'); Optional = $false }, @{ Name = 'Store (MSIX) install caches'; Paths = @('{Packages}\91750D7E.Slack_8wekyb3d8bbwe\LocalCache\Roaming\Slack\Cache', '{Packages}\91750D7E.Slack_8wekyb3d8bbwe\LocalCache\Roaming\Slack\Code Cache', '{Packages}\91750D7E.Slack_8wekyb3d8bbwe\LocalCache\Roaming\Slack\GPUCache'); Optional = $false }, @{ Name = 'Service worker storage and logs'; Paths = @('{Roaming}\Slack\Service Worker\CacheStorage', '{Roaming}\Slack\Service Worker\ScriptCache', '{Roaming}\Slack\logs'); Optional = $true }) },
    @{ Key = 'Discord'; WarnMb = 300; Processes = @('Discord'); Markers = @('{Local}\Discord', '{Roaming}\discord'); Catalogue = @(@{ Name = 'Electron caches'; Paths = @('{Roaming}\discord\Cache', '{Roaming}\discord\Code Cache', '{Roaming}\discord\GPUCache', '{Roaming}\discord\DawnGraphiteCache', '{Roaming}\discord\DawnWebGPUCache'); Optional = $false }, @{ Name = 'Service worker storage'; Paths = @('{Roaming}\discord\Service Worker\CacheStorage', '{Roaming}\discord\Service Worker\ScriptCache'); Optional = $true }) },
    @{ Key = 'Postman'; WarnMb = 300; Processes = @('Postman'); Markers = @('{Local}\Postman', '{Roaming}\Postman'); Catalogue = @(@{ Name = 'Electron caches'; Paths = @('{Roaming}\Postman\Cache', '{Roaming}\Postman\Code Cache', '{Roaming}\Postman\GPUCache', '{Roaming}\Postman\DawnGraphiteCache', '{Roaming}\Postman\DawnWebGPUCache'); Optional = $false }, @{ Name = 'Logs'; Paths = @('{Roaming}\Postman\logs'); Optional = $true }) },
    @{ Key = 'Notion'; WarnMb = 300; Processes = @('Notion'); Markers = @('{Local}\Programs\Notion', '{Roaming}\Notion'); Catalogue = @(@{ Name = 'Electron caches of the app and of each workspace partition'; Paths = @('{Roaming}\Notion\Cache', '{Roaming}\Notion\Code Cache', '{Roaming}\Notion\GPUCache', '{Roaming}\Notion\DawnGraphiteCache', '{Roaming}\Notion\DawnWebGPUCache', '{Roaming}\Notion\Partitions\*\Cache', '{Roaming}\Notion\Partitions\*\Code Cache', '{Roaming}\Notion\Partitions\*\GPUCache', '{Roaming}\Notion\Partitions\*\DawnGraphiteCache', '{Roaming}\Notion\Partitions\*\DawnWebGPUCache'); Optional = $false }, @{ Name = 'Service worker storage (offline pages download again)'; Paths = @('{Roaming}\Notion\Service Worker\CacheStorage', '{Roaming}\Notion\Partitions\*\Service Worker\CacheStorage'); Optional = $true }) },
    @{ Key = 'Obsidian'; WarnMb = 300; Processes = @('Obsidian'); Markers = @('{Local}\Obsidian', '{Roaming}\obsidian'); Catalogue = @(@{ Name = 'Electron caches'; Paths = @('{Roaming}\obsidian\Cache', '{Roaming}\obsidian\Code Cache', '{Roaming}\obsidian\GPUCache', '{Roaming}\obsidian\DawnGraphiteCache', '{Roaming}\obsidian\DawnWebGPUCache'); Optional = $false }) },
    @{ Key = 'Webex'; WarnMb = 300; Processes = @('CiscoCollabHost', 'atmgr'); Markers = @('{Local}\WebEx', '{Local}\CiscoSpark', '{Local}\CiscoSparkLauncher', '{PF86}\Webex', '{PF}\Webex'); Catalogue = @(@{ Name = 'Meetings client cache'; Paths = @('{Local}\WebEx\wbxcache'); Optional = $false }, @{ Name = 'Webex App renderer caches'; Paths = @('{Local}\CiscoSpark\*\Cache', '{Local}\CiscoSpark\*\Code Cache', '{Local}\CiscoSpark\*\GPUCache'); Optional = $false }) },
    @{ Key = 'Firefox'; WarnMb = 500; Processes = @('firefox'); Markers = @('{Local}\Mozilla\Firefox\Profiles', '{PF}\Mozilla Firefox\firefox.exe', '{PF86}\Mozilla Firefox\firefox.exe'); Catalogue = @(@{ Name = 'Profile disk caches (under %LocalAppData%, one set per profile)'; Paths = @('{Local}\Mozilla\Firefox\Profiles\*\cache2', '{Local}\Mozilla\Firefox\Profiles\*\startupCache', '{Local}\Mozilla\Firefox\Profiles\*\OfflineCache', '{Local}\Mozilla\Firefox\Profiles\*\jumpListCache', '{Local}\Mozilla\Firefox\Profiles\*\thumbnails', '{Local}\Mozilla\Firefox\Profiles\*\shader-cache'); Optional = $false }, @{ Name = 'Safe Browsing lists (downloaded again)'; Paths = @('{Local}\Mozilla\Firefox\Profiles\*\safebrowsing'); Optional = $true }) },
    @{ Key = 'Acrobat'; WarnMb = 300; Processes = @('Acrobat', 'AcroRd32', 'AcroCEF', 'RdrCEF'); Markers = @('{Local}\Adobe\Acrobat', '{Local}\Adobe\AcroCef', '{PF}\Adobe\Acrobat DC\Acrobat\Acrobat.exe', '{PF86}\Adobe\Acrobat DC\Acrobat\Acrobat.exe', '{PF86}\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe'); Catalogue = @(@{ Name = 'Acrobat caches (font list, connector icons)'; Paths = @('{Local}\Adobe\Acrobat\*\Cache', '{Local}\Adobe\Acrobat\*\ConnectorIcons'); Optional = $false }, @{ Name = 'Embedded browser (AcroCEF) caches'; Paths = @('{Local}\Adobe\AcroCef\*\*\Cache', '{Local}\Adobe\AcroCef\*\*\Code Cache', '{Local}\Adobe\AcroCef\*\*\GPUCache'); Optional = $false }) },
    @{ Key = 'CitrixWorkspace'; WarnMb = 300; Processes = @('wfica32', 'CDViewer'); Markers = @('{PF86}\Citrix\ICA Client\wfica32.exe', '{PF}\Citrix\ICA Client\wfica32.exe', '{Roaming}\ICAClient'); Catalogue = @(@{ Name = 'ICA client bitmap and persistent caches'; Paths = @('{Roaming}\ICAClient\Cache'); Optional = $false }) },
    @{ Key = 'Java'; WarnMb = 500; Processes = @('javaws', 'jp2launcher'); Markers = @('{Profile}\AppData\LocalLow\Sun\Java\Deployment', '{PF}\Java', '{PF86}\Java'); Catalogue = @(@{ Name = 'Deployment cache and temp (applets and Web Start apps download again)'; Paths = @('{Profile}\AppData\LocalLow\Sun\Java\Deployment\cache', '{Profile}\AppData\LocalLow\Sun\Java\Deployment\tmp'); Optional = $false }, @{ Name = 'Deployment logs'; Paths = @('{Profile}\AppData\LocalLow\Sun\Java\Deployment\log'); Optional = $true }) },
    @{ Key = 'Outlook'; WarnMb = 500; Processes = @('OUTLOOK', 'olk'); Markers = @('{Local}\Microsoft\Outlook', '{Local}\Microsoft\Olk', '{PF}\Microsoft Office\root\Office16\OUTLOOK.EXE', '{PF86}\Microsoft Office\root\Office16\OUTLOOK.EXE'); Catalogue = @(@{ Name = 'Autocomplete cache (RoamCache: the nickname list rebuilds as mail is sent)'; Paths = @('{Local}\Microsoft\Outlook\RoamCache'); Optional = $false }, @{ Name = 'Offline Address Books (downloaded again on the next send/receive)'; Paths = @('{Local}\Microsoft\Outlook\Offline Address Books'); Optional = $false }, @{ Name = 'Secure temp folder for opened attachments'; Paths = @('{Local}\Microsoft\Windows\INetCache\Content.Outlook'); Optional = $false }, @{ Name = 'New Outlook (olk) WebView2 caches'; Paths = @('{Local}\Microsoft\Olk\EBWebView\*\Cache', '{Local}\Microsoft\Olk\EBWebView\*\Code Cache', '{Local}\Microsoft\Olk\EBWebView\*\GPUCache', '{Local}\Microsoft\Olk\EBWebView\*\DawnGraphiteCache', '{Local}\Microsoft\Olk\EBWebView\*\DawnWebGPUCache'); Optional = $false }) }
)
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