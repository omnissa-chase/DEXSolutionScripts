<#
.SYNOPSIS
    Test-ClearCacheScripts -- lab contract test for every Clear-<App>Cache.ps1 and its sensors.

.DESCRIPTION
    For each product: plants a fixture (a few MB of files in a folder the script's catalogue
    matches, plus a sentinel file in a folder the script must never touch), then
      1. runs the size sensor, when the product has one, and asserts it counts the fixture;
      2. runs the clear script with WhatIf=true and asserts the fixture is intact;
      3. runs it for real (AllowDestructiveActions=true for the products that need it) and
         asserts: fixture gone and sentinel intact when the gated app is not running, or
         fixture intact and a [Skipped] line when it is; the AppCache registry key written;
      4. removes what it created (only folders that did not exist before).
    Finally runs app_cache_health.ps1 and asserts one line of valid JSON under 1,000 bytes.

    The fixture lives in the console user's own profile, the same user the scripts resolve
    through Win32_ComputerSystem, so run this elevated from that user's session. Nothing of
    the user's real cache is touched by the test itself; the real run of a script clears the
    real cache of any product that is installed and not running, which is the point.

    Result: C:\Temp\FixReport\Test-ClearCacheScripts\<timestamp>.json. Exit 0 when every
    assertion passes, 1 otherwise.

.PARAMETER Only
    Product keys to test (default: all). Example: -Only Chrome,VSCode

.NOTES
    Script Name  : Test-ClearCacheScripts.ps1
    Version      : 1.1.0
    Context      : Administrator (elevated), signed in as the console user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
param([string[]]$Only = @(), [string]$ReportRoot = 'C:\Temp\FixReport\Test-ClearCacheScripts', [int]$FixtureMB = 3)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$app  = Join-Path $repo 'ApplicationSpecific'

$cs = Get-CimInstance Win32_ComputerSystem
if (-not $cs.UserName) { throw 'No console user signed in' }
$sid = ([Security.Principal.NTAccount]([string]$cs.UserName)).Translate([Security.Principal.SecurityIdentifier]).Value
$profile = [string](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").ProfileImagePath
$L = "$profile\AppData\Local"; $R = "$profile\AppData\Roaming"; $PK = "$profile\AppData\Local\Packages"

# Fixture folder = a catalogue match; Sentinel = a never-touch location next to it.
$Products = @(
    @{ Key = 'Chrome';        Script = "$app\Chrome\Clear-ChromeCache.ps1";                      Sensor = "$app\Chrome\Sensors\chrome_cache_mb.ps1";             Procs = @('chrome');  Fixture = "$L\Google\Chrome\User Data\DEXTestProfile\Cache";                                                     Sentinel = "$L\Google\Chrome\User Data\DEXTestProfile\Cookies.dextest" }
    @{ Key = 'Edge';          Script = "$app\Microsoft\Edge\Clear-EdgeCache.ps1";                Sensor = "$app\Microsoft\Edge\Sensors\edge_cache_mb.ps1";       Procs = @('msedge');  Fixture = "$L\Microsoft\Edge\User Data\DEXTestProfile\Cache";                                                    Sentinel = "$L\Microsoft\Edge\User Data\DEXTestProfile\Cookies.dextest" }
    @{ Key = 'Teams';         Script = "$app\Microsoft\Teams\Clear-TeamsCache.ps1";              Sensor = "$app\Microsoft\Teams\Sensors\teams_cache_mb.ps1";     Procs = @('Teams', 'ms-teams', 'msteams'); Fixture = "$PK\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\DEXTest\Cache"; Sentinel = "$PK\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\DEXTest\Local Storage\dextest.sentinel" }
    @{ Key = 'Zoom';          Script = "$app\Zoom\Clear-ZoomCache.ps1";                          Sensor = '';                                                     Procs = @('Zoom');    Fixture = "$R\Zoom\data\cache";                                                                                   Sentinel = "$R\Zoom\data\dextest.sentinel.db" }
    @{ Key = 'Office';        Script = "$app\Microsoft\Office\Clear-OfficeCache.ps1";            Sensor = "$app\Microsoft\Office\Sensors\office_cache_mb.ps1";   Procs = @('WINWORD', 'EXCEL', 'POWERPNT', 'MSACCESS', 'ONENOTE', 'MSPUB', 'OUTLOOK', 'MSOSYNC'); Fixture = "$L\Microsoft\Office\16.0\OfficeFileCache"; Sentinel = "$L\Microsoft\Office\16.0\dextest.sentinel" }
    @{ Key = 'OneNote';       Script = "$app\Microsoft\OneNote\Clear-OneNoteCache.ps1";          Sensor = '';                                                     Procs = @('ONENOTE', 'ONENOTEM'); Fixture = "$L\Microsoft\OneNote\16.0\cache";                                                          Sentinel = "$L\Microsoft\OneNote\16.0\Backup\dextest.sentinel"; Destructive = $true }
    @{ Key = 'VSCode';        Script = "$app\Microsoft\VSCode\Clear-VSCodeCache.ps1";            Sensor = "$app\Microsoft\VSCode\Sensors\vscode_cache_mb.ps1";   Procs = @('Code', 'Code - Insiders'); Fixture = "$R\Code\Cache";                                                                        Sentinel = "$R\Code\User\dextest.sentinel" }
    @{ Key = 'Claude';        Script = "$app\Anthropic\Claude\Clear-ClaudeCache.ps1";            Sensor = '';                                                     Procs = @('Claude', 'claude'); Fixture = "$R\Claude\Cache";                                                                             Sentinel = "$R\Claude\Local Storage\dextest.sentinel" }
    @{ Key = 'GitHubDesktop'; Script = "$app\GitHub\Clear-GitHubDesktopCache.ps1";               Sensor = '';                                                     Procs = @('GitHubDesktop'); Fixture = "$R\GitHub Desktop\Cache";                                                                        Sentinel = "$R\GitHub Desktop\Local Storage\dextest.sentinel" }
    @{ Key = 'VisualStudio';  Script = "$app\Microsoft\VisualStudio\Clear-VisualStudioCache.ps1"; Sensor = '';                                                    Procs = @('devenv');  Fixture = "$L\Microsoft\VisualStudio\17.0_dextest\ComponentModelCache";                                          Sentinel = "$L\Microsoft\VisualStudio\17.0_dextest\Extensions\dextest.sentinel" }
    @{ Key = 'JetBrains';     Script = "$app\JetBrains\Clear-JetBrainsCache.ps1";                Sensor = "$app\JetBrains\Sensors\jetbrains_cache_mb.ps1";       Procs = @('idea64', 'pycharm64', 'webstorm64', 'rider64', 'clion64', 'goland64', 'phpstorm64', 'datagrip64', 'rubymine64', 'dataspell64', 'fleet'); Fixture = "$L\JetBrains\DEXTestIDE2026.1\caches"; Sentinel = "$L\JetBrains\Toolbox\caches\dextest.sentinel" }
    @{ Key = 'DevPackage';    Script = "$app\DeveloperTools\Clear-DevPackageCache.ps1";          Sensor = "$app\DeveloperTools\Sensors\devpackage_cache_mb.ps1"; Procs = @();          Fixture = "$L\npm-cache\_cacache\dextest";                                                                        Sentinel = "$L\npm-cache\dextest.sentinel"; SubFolder = $true }
    @{ Key = 'Slack';         Script = "$app\Slack\Clear-SlackCache.ps1";                        Sensor = "$app\Slack\Sensors\slack_cache_mb.ps1";               Procs = @('slack');   Fixture = "$R\Slack\Cache";                                                                                       Sentinel = "$R\Slack\Local Storage\dextest.sentinel" }
    @{ Key = 'Discord';       Script = "$app\Discord\Clear-DiscordCache.ps1";                    Sensor = '';                                                     Procs = @('Discord'); Fixture = "$R\discord\Cache";                                                                                     Sentinel = "$R\discord\Local Storage\dextest.sentinel" }
    @{ Key = 'Postman';       Script = "$app\Postman\Clear-PostmanCache.ps1";                    Sensor = '';                                                     Procs = @('Postman'); Fixture = "$R\Postman\Cache";                                                                                     Sentinel = "$R\Postman\Partitions\dextest.sentinel" }
    @{ Key = 'Notion';        Script = "$app\Notion\Clear-NotionCache.ps1";                      Sensor = '';                                                     Procs = @('Notion');  Fixture = "$R\Notion\Partitions\DEXTest\Cache";                                                                   Sentinel = "$R\Notion\Partitions\DEXTest\IndexedDB\dextest.sentinel" }
    @{ Key = 'Obsidian';      Script = "$app\Obsidian\Clear-ObsidianCache.ps1";                  Sensor = '';                                                     Procs = @('Obsidian'); Fixture = "$R\obsidian\Cache";                                                                                   Sentinel = "$R\obsidian\Local Storage\dextest.sentinel" }
    @{ Key = 'Webex';         Script = "$app\Cisco\Webex\Clear-WebexCache.ps1";                  Sensor = '';                                                     Procs = @('CiscoCollabHost', 'atmgr'); Fixture = "$L\WebEx\wbxcache";                                                                  Sentinel = "$L\WebEx\dextest.sentinel" }
    @{ Key = 'Firefox';       Script = "$app\Mozilla\Firefox\Clear-FirefoxCache.ps1";            Sensor = "$app\Mozilla\Firefox\Sensors\firefox_cache_mb.ps1";   Procs = @('firefox'); Fixture = "$L\Mozilla\Firefox\Profiles\dextest.default\cache2";                                                   Sentinel = "$R\Mozilla\Firefox\Profiles\dextest.default\dextest.sentinel" }
    @{ Key = 'Acrobat';       Script = "$app\Adobe\Acrobat\Clear-AcrobatCache.ps1";              Sensor = '';                                                     Procs = @('Acrobat', 'AcroRd32', 'AcroCEF', 'RdrCEF'); Fixture = "$L\Adobe\Acrobat\DC\Cache";                                          Sentinel = "$R\Adobe\Acrobat\DC\dextest.sentinel" }
    @{ Key = 'CitrixWorkspace'; Script = "$app\Citrix\Workspace\Clear-CitrixWorkspaceCache.ps1"; Sensor = '';                                                     Procs = @('wfica32', 'CDViewer'); Fixture = "$R\ICAClient\Cache";                                                                     Sentinel = "$R\ICAClient\dextest.sentinel" }
    @{ Key = 'Java';          Script = "$app\Oracle\Java\Clear-JavaCache.ps1";                   Sensor = '';                                                     Procs = @('javaws', 'jp2launcher'); Fixture = "$profile\AppData\LocalLow\Sun\Java\Deployment\cache";                                   Sentinel = "$profile\AppData\LocalLow\Sun\Java\Deployment\security\dextest.sentinel" }
    @{ Key = 'Outlook';       Script = "$app\Microsoft\Outlook\Clear-OutlookCache.ps1";          Sensor = "$app\Microsoft\Outlook\Sensors\outlook_cache_mb.ps1"; Procs = @('OUTLOOK', 'olk'); Fixture = "$L\Microsoft\Olk\EBWebView\DEXTest\Cache";                                                 Sentinel = "$L\Microsoft\Olk\EBWebView\DEXTest\dextest.sentinel"; Destructive = $true }
)
if ($Only.Count -gt 0) { $Products = @($Products | Where-Object { @($Only -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Key }) }

$results = @(); $pass = 0; $fail = 0
function Assert([string]$Test, [bool]$Ok, [string]$Detail = '') {
    $script:results += @{ Test = $Test; Pass = $Ok; Detail = $Detail }
    if ($Ok) { $script:pass++ } else { $script:fail++ }
    Write-Host ("  [{0}] {1}{2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Test, $(if ($Detail) { " -- $Detail" } else { '' })) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}
function New-Fixture([string]$Dir, [int]$MB) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $bytes = New-Object byte[] (1MB)
    for ($i = 0; $i -lt $MB; $i++) { [IO.File]::WriteAllBytes((Join-Path $Dir ("dextest_{0:D2}.bin" -f $i)), $bytes) }
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'sub') | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $Dir 'sub\dextest_sub.bin'), $bytes)
}
function Get-FixtureCount([string]$Dir) { if (-not (Test-Path -LiteralPath $Dir)) { return 0 }; return @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Filter 'dextest_*' -ErrorAction SilentlyContinue).Count }
function Invoke-Script([string]$Path, [hashtable]$Vars) {
    foreach ($k in 'WhatIf', 'AllowDestructiveActions', 'CloseApp', 'Users', 'IncludeOptional') { [Environment]::SetEnvironmentVariable($k, $(if ($Vars.ContainsKey($k)) { $Vars[$k] } else { $null }), 'Process') }
    try { $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path 2>&1 | ForEach-Object { [string]$_ }); return @{ Exit = $LASTEXITCODE; Output = ($out -join "`n") } }
    finally { foreach ($k in 'WhatIf', 'AllowDestructiveActions', 'CloseApp', 'Users', 'IncludeOptional') { [Environment]::SetEnvironmentVariable($k, $null, 'Process') } }
}
function Get-Created([string]$Path) {
    # Topmost folder of $Path that does not exist yet (so cleanup removes only what the test creates).
    $p = $Path; $top = ''
    while ($p -and -not (Test-Path -LiteralPath $p)) { $top = $p; $p = Split-Path $p -Parent }
    return $top
}

Write-Host "`nTest-ClearCacheScripts on $env:COMPUTERNAME  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  user $($cs.UserName)`n"
foreach ($p in $Products) {
    Write-Host "== $($p.Key)"
    if (-not (Test-Path -LiteralPath $p.Script)) { Assert "$($p.Key): script present" $false $p.Script; continue }
    $createdFixture = Get-Created $p.Fixture
    $createdSentinel = Get-Created (Split-Path $p.Sentinel -Parent)
    $running = ($p.Procs.Count -gt 0 -and @(Get-Process -Name $p.Procs -ErrorAction SilentlyContinue).Count -gt 0)
    try {
        New-Fixture $p.Fixture $FixtureMB
        New-Item -ItemType Directory -Force -Path (Split-Path $p.Sentinel -Parent) | Out-Null
        Set-Content -LiteralPath $p.Sentinel -Value 'never touch' -Encoding ASCII
        $planted = Get-FixtureCount $p.Fixture
        Assert "$($p.Key): fixture planted" ($planted -eq ($FixtureMB + 1)) "$planted files in $($p.Fixture)"

        if ($p.Sensor -and (Test-Path -LiteralPath $p.Sensor)) {
            $sv = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p.Sensor 2>&1 | Select-Object -Last 1)
            $n = -99; [void][int]::TryParse([string]$sv, [ref]$n)
            Assert "$($p.Key): size sensor counts the fixture" ($n -ge $FixtureMB) "sensor=$sv"
        }

        $w = Invoke-Script $p.Script @{ WhatIf = 'true' }
        Assert "$($p.Key): WhatIf exit 0" ($w.Exit -eq 0) "exit $($w.Exit)"
        Assert "$($p.Key): WhatIf reports" ($w.Output -match '\[WhatIf \]') ''
        Assert "$($p.Key): WhatIf deletes nothing" ((Get-FixtureCount $p.Fixture) -eq $planted) ''

        $vars = @{}; if ($p.Destructive) { $vars['AllowDestructiveActions'] = 'true' }
        $r = Invoke-Script $p.Script $vars
        Assert "$($p.Key): real run exit 0" ($r.Exit -eq 0) "exit $($r.Exit)"
        $left = Get-FixtureCount $p.Fixture
        if ($running) {
            Assert "$($p.Key): app running -> skipped and fixture intact" (($r.Output -match '\[Skipped\]') -and ($left -eq $planted)) "left=$left"
        } else {
            Assert "$($p.Key): cleared the fixture" (($r.Output -match '\[Cleared\]') -and ($left -eq 0)) "left=$left"
            if ($p.SubFolder) {
                # The fixture is a sub-folder inside a catalogue folder (npm's _cacache), so the engine removes it with the rest of the contents.
                Assert "$($p.Key): fixture sub-folder removed with the cache contents" (-not (Test-Path -LiteralPath $p.Fixture)) ''
            } else {
                Assert "$($p.Key): fixture folder itself kept" (Test-Path -LiteralPath $p.Fixture) ''
            }
        }
        Assert "$($p.Key): sentinel untouched" (Test-Path -LiteralPath $p.Sentinel) $p.Sentinel
        $reg = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\AppCache\$($p.Key)" -ErrorAction SilentlyContinue
        Assert "$($p.Key): AppCache key written" ([bool]$reg -and $reg.Status -in @('Cleared', 'Partial', 'Skipped')) "Status=$($reg.Status) MBFreed=$($reg.MBFreed)"
    } catch {
        Assert "$($p.Key): harness" $false $_.Exception.Message
    } finally {
        if ($createdFixture) { Remove-Item -LiteralPath $createdFixture -Recurse -Force -ErrorAction SilentlyContinue } else { Get-ChildItem -LiteralPath $p.Fixture -Recurse -Filter 'dextest_*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath (Join-Path $p.Fixture 'sub') -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $p.Sentinel -Force -ErrorAction SilentlyContinue
        if ($createdSentinel) { Remove-Item -LiteralPath $createdSentinel -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host '== app_cache_health'
$h = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'OneTimeSensor\app_cache_health.ps1') 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_ })
Assert 'health: one line' ($h.Count -eq 1) "lines $($h.Count)"
$json = $null; try { $json = $h[-1] | ConvertFrom-Json } catch { }
Assert 'health: valid JSON with Schema 1' ($null -ne $json -and $json.Schema -eq 1) ''
Assert 'health: under 1,000 bytes' ([Text.Encoding]::UTF8.GetByteCount([string]$h[-1]) -le 1000) "$([Text.Encoding]::UTF8.GetByteCount([string]$h[-1])) bytes"
Assert 'health: not timed out' ($json -and -not $json.TO) "Ms=$($json.Ms)"

Write-Host "`n  Passed: $pass   Failed: $fail`n"
New-Item -ItemType Directory -Force -Path $ReportRoot | Out-Null
$file = Join-Path $ReportRoot "$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
[ordered]@{ Machine = $env:COMPUTERNAME; User = [string]$cs.UserName; RanAt = (Get-Date -Format 'o'); Passed = $pass; Failed = $fail; Results = $results } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $file -Encoding UTF8
Write-Host "  [Result] $file"
exit $(if ($fail -eq 0) { 0 } else { 1 })
