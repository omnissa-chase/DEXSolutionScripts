<#
.SYNOPSIS
    Invoke-AutoRemediateOneNote_BreakTest -- deliberately plants OneNote (desktop) faults,
    then verifies Invoke-AutoRemediateOneNote.ps1 reports or repairs them as documented.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateOneNote\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It writes an add-in key, a Resiliency
    DisabledItems entry and an OpenNotebooks subkey into the logged-on user's OneNote hive,
    drops a 64 MB fixture file into the user's notebook cache folder
    (%LOCALAPPDATA%\Microsoft\OneNote\16.0\cache, created if absent), lowers the script's
    cache threshold, and -- for NotebookCacheBloat only -- lets the script RENAME the
    user's cache folder to cache_<stamp>.bak; Restore renames it back. Run it only on a
    disposable VM or a marked test host. See Assert-DexTestHost in DEXTestFramework.psm1.

    WHAT IS BROKEN AND HOW IT COMES BACK
    The script resolves the user from Win32_ComputerSystem.UserName, the hive through
    HKEY_USERS\<SID> and the profile through C:\Users\<name>; so does this harness, so run
    it elevated as the interactive user. Every artefact carries the DEXTest prefix. Each
    break Captures what it is about to change (keys and folders it had to create, whether
    the cache folder existed, the cache_*.bak folders already present, real Resiliency
    entry names) and Restore removes only what was planted, deepest first, keys and folders
    only when empty afterwards. The user's cache content is never deleted: after the
    script renames the folder, Restore strips the DEXTest subfolder out of the .bak and
    renames it back to cache. If both cache and a new .bak exist at Restore (OneNote was
    launched mid-run) the harness refuses to guess and reports Dirty with the .bak name.

    GATES
    Steps 3 and 6 remediate only with $env:AllowDestructiveActions = true, step 4 only
    with $env:ReenableDisabledItems = true; each has a gated (ExpectReportedOnly) and an
    ungated (ExpectFixed) break. A flag is one variable for the whole child, so gated and
    ungated breaks of one flag cannot share a run: the first drawn decides, the rest are
    dropped. The script disables the FIRST third-party add-in, clears EVERY Resiliency
    entry and renames the WHOLE cache, so the ungated breaks refuse when a real add-in or
    entry exists, and AllowDestructiveActions is never set while a real third-party add-in
    is active or while (with no cache break drawn) the real cache already exceeds the
    script's default 4096 MB or has a zero-byte 0.onecache. The two cache breaks share one
    fixture (Group 'Cache') and are mutually exclusive.

    EXPECTED OUTCOMES (from the script's own messages, 1.0.1; the regexes sit in Validate)
    ThirdPartyAddinConflictGated  ExpectReportedOnly. DEXTest.Addin LoadBehavior 3 under
                                  HKU\<SID>\...\Office\16.0\OneNote\Addins; still 3 afterwards;
                                  Step03 "[Warning] 1 active third-party add-in(s): DEXTest.Addin
                                  [user]. Disabling the first one is the remediation -- set ...".
    ThirdPartyAddinConflict       ExpectFixed. Flag 'true'; LoadBehavior 0; Step03 "[Remediated]
                                  Add-in 'DEXTest.Addin' [user] set to LoadBehavior=0. ...".
    DisabledItemGated             ExpectReportedOnly. REG_BINARY DEXTest01 under
                                  ...\OneNote\Resiliency\DisabledItems decoding to DEXTest.Addin;
                                  still there; Step04 "[Warning] 1 disabled item(s), 0 disabled
                                  startup item(s): DEXTest.Addin. Set $ReenableDisabledItems...".
    DisabledItem                  ExpectFixed. ReenableDisabledItems 'true'; value gone; Step04
                                  "[Remediated] Cleared 1 Resiliency entry; items load at ...".
    NotebookCacheBloatGated       ExpectReportedOnly. cache\DEXTest\DEXTest_bloat.bin (64 MB,
                                  dated 30 days back), CacheSizeWarningMB = floor(real MB) + 64
                                  handed to the script; cache still present, no new .bak; Step06
                                  "[Warning] Notebook cache is <n>MB (threshold <n>MB). Rename to
                                  cache_<stamp>.bak; ... -- set $AllowDestructiveActions=...".
    NotebookCacheBloat            ExpectFixed. Flag 'true', ONENOTE.EXE closed (never killed);
                                  cache gone, exactly one new cache_<yyyyMMdd-HHmmss>.bak holding
                                  the fixture; Step06 "[Remediated] Notebook cache renamed to
                                  cache_<stamp>.bak; OneNote rebuilds it ...". Restore renames
                                  the backup back to cache.
    NotebookSyncError             ExpectReportedOnly. OpenNotebooks\DEXTest.Notebook with Path
                                  https://d.docs.live.net/DEXTest/DEXTest Lab Notebook and
                                  LastSyncError 0x80070005 (REG_DWORD); key intact; Step07
                                  "[Warning] 1 of 1 notebook(s) report a sync error: DEXTest Lab
                                  Notebook (LastSyncError=0x80070005). Report only: ...".

    NOT COVERED
      Step 2 Crash and Hang History -- planting real 1000/1002 events is out of bounds.
      Step 3 Failed branch (crash module matches an add-in name) -- needs a step 2 crash;
             note that branch remediates WITHOUT the AllowDestructiveActions gate.
      Step 6 corrupt branch (zero-byte 0.onecache with notebooks registered) -- would mean
             replacing the user's real 0.onecache; the bloat branch reaches the same path.
      Step 6 'OneNote is open' refusal -- Verify refuses instead of launching OneNote.
      Step 8 Office C2R Update Health -- Enabled = $false in this script (Word owns it).
      No-user branches ($_noUser) -- need a session with nobody logged on.

    REBOOTS
    No break in this catalog requires a reboot. The reboot plumbing is kept so the
    harness stays uniform with the rest of the family.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateOneNote.ps1 and validate the outcome.
.PARAMETER Environment
    Physical (default) restores the machine when the run ends. Snapshot skips restore.
.PARAMETER Seed
    Replays an earlier run's random break selection exactly.
.PARAMETER BreakName
    Force specific breaks instead of a random selection.
.PARAMETER BreakCount
    How many components to break when selecting randomly. Default 2.
.PARAMETER IncludeRebootBreaks
    Allow breaks that require a reboot to take effect. Default off.
.PARAMETER Restore
    Undo an in-flight run's breaks and exit. No remediation, no validation.
.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot.
.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Invoke-AutoRemediateOneNote_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated), run as the interactive user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateOneNote\

    1.0.0  Initial: add-in gated/ungated, Resiliency gated/ungated, NotebookCacheBloat
           gated/ungated, NotebookSyncError. Tracks script 1.0.1.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [switch]$RemediationTest,
    [ValidateSet('Snapshot', 'Physical')][string]$Environment = 'Physical',
    [int]$Seed = 0,
    [string[]]$BreakName,
    [int]$BreakCount = 2,
    [switch]$IncludeRebootBreaks,
    [switch]$Restore,
    [switch]$Resume,
    [switch]$Force,
    [string[]]$ProductionDomainDenyList = @()
)

$ErrorActionPreference = 'Stop'

$ScriptUnderTest   = 'Invoke-AutoRemediateOneNote'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateOneNote.ps1'
$AppName           = 'OneNote'
$AppExe            = 'ONENOTE.EXE'
$AppProcess        = 'ONENOTE'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\OneNoteErrors'
$C2RConfigPath     = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

if (-not (Test-Path -LiteralPath $RemediationScript)) {
    throw "Script under test not found at $RemediationScript"
}

# -- Fixture ------------------------------------------------------------------
$FixtureAddinName       = 'DEXTest.Addin'       # must NOT match the script's $_msAddin matcher
$FixtureResiliencyValue = 'DEXTest01'           # REG_BINARY value name under Resiliency\DisabledItems
$FixtureDisabledItem    = 'DEXTest.Addin'       # what _DecodeResiliency must read out of that value
$FixtureBloatSubdir     = 'DEXTest'             # subfolder inside the cache folder
$FixtureBloatFile       = 'DEXTest_bloat.bin'
$FixtureBloatMB         = 64                    # fixture size; threshold = floor(real cache MB) + this
$FixtureBloatAgeDays    = 30
$FixtureNotebookKey     = 'DEXTest.Notebook'    # OpenNotebooks subkey name
$FixtureNotebookUrl     = 'https://d.docs.live.net/DEXTest/DEXTest Lab Notebook'
$FixtureNotebookName    = 'DEXTest Lab Notebook' # Split-Path -Leaf of the URL, as the script names it
$FixtureSyncError       = [int]-2147024891       # 0x80070005 as the Int32 a REG_DWORD reads back as
$FixtureFreeSpaceMB     = 512
$ScriptDefaultCacheMB   = 4096                  # the script's default CacheSizeWarningMB

$MicrosoftAddinMatcher = '^Microsoft\.|OfficeMicrosoftTeams|Microsoft Online|SharePoint|OneDrive|Skype|Lync|Grammarly\.Microsoft|CopilotAddin'

function Initialize-Fixture {
    if (-not (Test-AppInstalled)) {
        throw "Click-to-Run $AppExe or the ClickToRun Configuration key is absent; the script would exit 0 as Skipped."
    }
    $user = Get-LoggedOnUser
    $sid  = Get-LoggedOnUserSid
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) {
        throw "Hive for $user ($sid) is not loaded under HKEY_USERS; the script's per-user steps would not see it."
    }
    Get-UserProfilePath | Out-Null
    $thirdParty = @(Get-ActiveThirdPartyAddins)
    $realRes    = @(Get-RealResiliencyEntries)
    $cache      = Get-CacheDir
    $cacheInfo  = if (Test-Path -LiteralPath $cache) { "$(Get-DirMB -Path $cache)MB, 0.onecache $(if (Test-Path -LiteralPath (Join-Path $cache '0.onecache')) { 'present' } else { 'absent' })" } else { 'absent' }
    Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Office $(Get-OfficeVersion) ($((Get-C2RConfig).VersionToReport)); user $user; real active third-party add-ins: $($thirdParty.Count); real Resiliency entries: $($realRes.Count); notebook cache: $cacheInfo; registered notebooks: $(@(Get-RegisteredNotebooks).Count); $AppExe running: $(Test-AppRunning)"
}

function Remove-Fixture {
    # Sweep by prefix; the per-break Restore blocks have normally done all of this already.
    try {
        $key = Get-FixtureAddinKeyPath
        if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
    try {
        $k = Get-DisabledItemsKeyPath
        if (Test-Path -LiteralPath $k) { Remove-ItemProperty -LiteralPath $k -Name $FixtureResiliencyValue -ErrorAction SilentlyContinue }
    } catch { }
    try {
        $nb = Get-FixtureNotebookKeyPath
        if (Test-Path -LiteralPath $nb) { Remove-Item -LiteralPath $nb -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
    try {
        # The fixture subfolder, wherever the rename left it (cache or any cache_*.bak).
        foreach ($d in @(Get-CacheCandidateDirs)) {
            $sub = Join-Path $d $FixtureBloatSubdir
            if (Test-Path -LiteralPath $sub) { Remove-Item -LiteralPath $sub -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
}

# -- Helpers: user, Office, registry ----------------------------------------------

function Get-LoggedOnUser {
    $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not $u) { throw "No interactive user is logged on; $ScriptUnderTest.ps1 resolves its user from Win32_ComputerSystem.UserName." }
    return $u
}

function Get-LoggedOnUserSid {
    $u = Get-LoggedOnUser
    return ([Security.Principal.NTAccount]$u).Translate([Security.Principal.SecurityIdentifier]).Value
}

function Get-UserProfilePath {
    # Mirrors the script: C:\Users\<short name>, never $env:USERPROFILE.
    $shortName = (Get-LoggedOnUser).Split('\')[-1]
    $p = "C:\Users\$shortName"
    if (-not (Test-Path -LiteralPath $p)) { throw "Profile folder '$p' for the logged-on user not found." }
    return $p
}

function Get-C2RConfig {
    Get-ItemProperty -LiteralPath $C2RConfigPath -ErrorAction SilentlyContinue
}

function Test-AppInstalled {
    if (-not (Get-C2RConfig)) { return $false }
    foreach ($p in @("$env:ProgramFiles\Microsoft Office\root\Office16", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16")) {
        if (Test-Path -LiteralPath (Join-Path $p $AppExe)) { return $true }
    }
    return $false
}

function Get-OfficeVersion {
    $cfg = Get-C2RConfig
    if ($cfg -and $cfg.VersionToReport) {
        $parts = "$($cfg.VersionToReport)".Split('.')
        if ($parts.Count -ge 2) { return "$($parts[0]).$($parts[1])" }
    }
    return '16.0'
}

function Get-UserHivePath         { "Registry::HKEY_USERS\$(Get-LoggedOnUserSid)" }
function Get-UserAppKeyPath       { "$(Get-UserHivePath)\Software\Microsoft\Office\$(Get-OfficeVersion)\$AppName" }
function Get-UserAddinsKeyPath    { "$(Get-UserAppKeyPath)\Addins" }
function Get-FixtureAddinKeyPath  { "$(Get-UserAddinsKeyPath)\$FixtureAddinName" }
function Get-ResiliencyKeyPath    { "$(Get-UserAppKeyPath)\Resiliency" }
function Get-DisabledItemsKeyPath { "$(Get-ResiliencyKeyPath)\DisabledItems" }
function Get-StartupItemsKeyPath  { "$(Get-ResiliencyKeyPath)\StartupItems" }
function Get-OpenNotebooksKeyPath { "$(Get-UserAppKeyPath)\OpenNotebooks" }
function Get-FixtureNotebookKeyPath { "$(Get-OpenNotebooksKeyPath)\$FixtureNotebookKey" }

function Test-AppRunning { [bool](Get-Process -Name $AppProcess -ErrorAction SilentlyContinue) }

function Get-MissingRegistryKeys {
    param([Parameter(Mandatory = $true)][string[]]$Paths)
    $missing = @()
    foreach ($p in $Paths) { if (-not (Test-Path -LiteralPath $p)) { $missing += $p } }
    return @($missing)
}

function Remove-MissingRegistryKeys {
    param([string[]]$Paths)
    $list = @($Paths | Where-Object { $_ })
    [array]::Reverse($list)
    foreach ($p in $list) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
        if ($item -and $item.SubKeyCount -eq 0 -and $item.ValueCount -eq 0) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-MissingDirectories {
    param([Parameter(Mandatory = $true)][string[]]$Paths)
    $missing = @()
    foreach ($p in $Paths) { if (-not (Test-Path -LiteralPath $p -PathType Container)) { $missing += $p } }
    return @($missing)
}

function Remove-MissingDirectories {
    param([string[]]$Paths)
    $list = @($Paths | Where-Object { $_ })
    [array]::Reverse($list)
    foreach ($p in $list) {
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue }
        if (@(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-RegistryKeyChain {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
}

# -- Helpers: DEXRecords ----------------------------------------------------------

function Get-DexRecordValue {
    param([Parameter(Mandatory = $true)][string]$ValueNamePrefix)
    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { return $null }
    $key = Get-Item -LiteralPath $DexRecordsPath -ErrorAction SilentlyContinue
    if (-not $key) { return $null }
    $name = @($key.GetValueNames() | Where-Object { $_ -like "$ValueNamePrefix*" } | Select-Object -First 1)
    if ($name.Count -eq 0) { return $null }
    return "$($key.GetValue($name[0]))"
}

function Test-DexRecordMatches {
    # Host-stream diagnostics only; callers are [bool]-cast.
    param(
        [Parameter(Mandatory = $true)][string]$ValueNamePrefix,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    $text = Get-DexRecordValue -ValueNamePrefix $ValueNamePrefix
    if ($null -eq $text) { Write-Host "           no $ValueNamePrefix value under $DexRecordsPath"; return $false }
    if ($text -notmatch $Pattern) { Write-Host "           $ValueNamePrefix = '$text' did not match '$Pattern'"; return $false }
    return $true
}

# -- Helpers: add-ins (step 3) ----------------------------------------------------

function Get-AddinSearchKeys {
    $ver = Get-OfficeVersion; $hku = Get-UserHivePath
    $out = @()
    foreach ($s in @("Software\Microsoft\Office\$AppName\Addins", "Software\Microsoft\Office\$ver\$AppName\Addins")) {
        $out += "$hku\$s"
        $out += "HKLM:\$s"
        $out += "HKLM:\SOFTWARE\WOW6432Node\$($s.Substring(9))"
    }
    return @($out | Where-Object { Test-Path -LiteralPath $_ })
}

function Get-ActiveThirdPartyAddins {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($root in @(Get-AddinSearchKeys)) {
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            if ($k.PSChildName -eq $FixtureAddinName) { continue }
            if ($k.PSChildName -match $MicrosoftAddinMatcher) { continue }
            $lb = (Get-ItemProperty -LiteralPath $k.PSPath -Name 'LoadBehavior' -ErrorAction SilentlyContinue).LoadBehavior
            if ($lb -eq 3) { $list.Add(($k.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')) }
        }
    }
    return $list.ToArray()
}

function Get-FixtureAddinLoadBehavior {
    $key = Get-FixtureAddinKeyPath
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    return (Get-ItemProperty -LiteralPath $key -Name 'LoadBehavior' -ErrorAction SilentlyContinue).LoadBehavior
}

function Get-FixtureAddinBaseline {
    @{ MissingKeys = @(Get-MissingRegistryKeys -Paths @((Get-UserAppKeyPath), (Get-UserAddinsKeyPath))) }
}

function Add-FixtureAddin {
    New-RegistryKeyChain -Path (Get-UserAddinsKeyPath)
    $key = Get-FixtureAddinKeyPath
    New-Item -Path $key -Force -ErrorAction Stop | Out-Null
    Set-ItemProperty -LiteralPath $key -Name 'LoadBehavior' -Value 3 -Type DWord -ErrorAction Stop
    Set-ItemProperty -LiteralPath $key -Name 'FriendlyName' -Value 'DEX Test Lab Add-in' -Type String -ErrorAction Stop
    Set-ItemProperty -LiteralPath $key -Name 'Description'  -Value "Planted by $ScriptUnderTest`_BreakTest.ps1; safe to delete." -Type String -ErrorAction Stop
}

function Test-FixtureAddinPlanted {
    $lb = Get-FixtureAddinLoadBehavior
    if ($lb -ne 3) { Write-Host "           $FixtureAddinName LoadBehavior is '$lb', expected 3"; return $false }
    if ($FixtureAddinName -match $MicrosoftAddinMatcher) { Write-Host '           fixture name matches the Microsoft matcher'; return $false }
    return $true
}

function Restore-FixtureAddin {
    param($Original)
    $key = Get-FixtureAddinKeyPath
    if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-MissingRegistryKeys -Paths @($Original.MissingKeys | Where-Object { $_ })
}

# -- Helpers: Resiliency (step 4) --------------------------------------------------

function ConvertFrom-ResiliencyValue {
    param([Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)][string]$Name)
    $item  = Get-Item -LiteralPath $Key -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    $bytes = $item.GetValue($Name)
    if ($bytes -is [byte[]]) {
        $text = [Text.Encoding]::Unicode.GetString($bytes)
        $segs = @($text -split "`0" | Where-Object { $_ -match '[A-Za-z]{3,}' })
        if ($segs.Count -gt 0) { return $segs[0].Trim() }
        return $Name
    }
    return $Name
}

function Get-RealResiliencyEntries {
    $out = @()
    foreach ($k in @((Get-DisabledItemsKeyPath), (Get-StartupItemsKeyPath))) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        $item = Get-Item -LiteralPath $k -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($v in @($item.GetValueNames())) {
            if ($v -ne $FixtureResiliencyValue) { $out += "$(Split-Path -Path $k -Leaf)\$v" }
        }
    }
    return @($out)
}

function Get-FixtureResiliencyBaseline {
    @{
        MissingKeys = @(Get-MissingRegistryKeys -Paths @((Get-UserAppKeyPath), (Get-ResiliencyKeyPath), (Get-DisabledItemsKeyPath)))
        RealEntries = @(Get-RealResiliencyEntries)
    }
}

function Add-FixtureDisabledItem {
    New-RegistryKeyChain -Path (Get-DisabledItemsKeyPath)
    $bytes = [Text.Encoding]::Unicode.GetBytes("$FixtureDisabledItem`0DEX Test Lab Add-in`0")
    Set-ItemProperty -LiteralPath (Get-DisabledItemsKeyPath) -Name $FixtureResiliencyValue -Value ([byte[]]$bytes) -Type Binary -ErrorAction Stop
}

function Test-FixtureDisabledItemPlanted {
    $k = Get-DisabledItemsKeyPath
    if (-not (Test-Path -LiteralPath $k)) { Write-Host "           $k missing"; return $false }
    if (@((Get-Item -LiteralPath $k).GetValueNames()) -notcontains $FixtureResiliencyValue) { Write-Host "           value $FixtureResiliencyValue missing"; return $false }
    $decoded = ConvertFrom-ResiliencyValue -Key $k -Name $FixtureResiliencyValue
    if ($decoded -ne $FixtureDisabledItem) { Write-Host "           value decodes to '$decoded', expected '$FixtureDisabledItem'"; return $false }
    return $true
}

function Test-FixtureDisabledItemPresent {
    $k = Get-DisabledItemsKeyPath
    if (-not (Test-Path -LiteralPath $k)) { return $false }
    return (@((Get-Item -LiteralPath $k).GetValueNames()) -contains $FixtureResiliencyValue)
}

function Restore-FixtureResiliency {
    param($Original)
    $k = Get-DisabledItemsKeyPath
    if (Test-Path -LiteralPath $k) { Remove-ItemProperty -LiteralPath $k -Name $FixtureResiliencyValue -ErrorAction SilentlyContinue }
    Remove-MissingRegistryKeys -Paths @($Original.MissingKeys | Where-Object { $_ })
}

# -- Helpers: notebook cache (step 6) ---------------------------------------------

function Get-CacheDir       { Join-Path (Get-UserProfilePath) "AppData\Local\Microsoft\OneNote\$(Get-OfficeVersion)\cache" }
function Get-CacheParentDir { Split-Path -Path (Get-CacheDir) -Parent }
function Get-FixtureBloatPath { Join-Path (Join-Path (Get-CacheDir) $FixtureBloatSubdir) $FixtureBloatFile }

function Get-DirMB {
    # Same arithmetic as the script's _DirMB.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    return [math]::Round(($(if ($sum) { $sum } else { 0 })) / 1MB, 1)
}

function Get-CacheBakNames {
    # cache_*.bak folder names beside the cache. Plain array; callers wrap in @().
    $parent = Get-CacheParentDir
    if (-not (Test-Path -LiteralPath $parent)) { return @() }
    return @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'cache_*.bak' } | ForEach-Object { $_.Name })
}

function Get-CacheCandidateDirs {
    # The cache folder and every cache_*.bak beside it, existing ones only. Plain array.
    $parent = Get-CacheParentDir
    $out = @()
    if (Test-Path -LiteralPath (Get-CacheDir)) { $out += (Get-CacheDir) }
    foreach ($n in @(Get-CacheBakNames)) { $out += (Join-Path $parent $n) }
    return @($out)
}

function Test-CacheCorrupt {
    # The script's corrupt test: notebooks registered and 0.onecache at zero bytes.
    $one = Get-Item -LiteralPath (Join-Path (Get-CacheDir) '0.onecache') -ErrorAction SilentlyContinue
    return ((@(Get-RegisteredNotebooks).Count -gt 0) -and $one -and ($one.Length -eq 0))
}

function Get-CacheBaseline {
    $prof  = Get-UserProfilePath
    $cache = Get-CacheDir
    @{
        CacheExisted = (Test-Path -LiteralPath $cache)
        MissingDirs  = @(Get-MissingDirectories -Paths @((Join-Path $prof 'AppData\Local\Microsoft\OneNote'), (Get-CacheParentDir), $cache))
        BakNames     = @(Get-CacheBakNames)
        RealMB       = (Get-DirMB -Path $cache)
    }
}

function New-FixtureBloat {
    # 64 MB zero-filled file via fsutil in cache\DEXTest, dated back; the threshold handed to
    # the script is floor(real MB) + fixture MB, which the script's Round(total, 1) always meets.
    $cache = Get-CacheDir
    $realMB = Get-DirMB -Path $cache
    $drive  = Get-PSDrive -Name ($cache.Substring(0, 1)) -ErrorAction Stop
    $freeMB = [math]::Floor($drive.Free / 1MB)
    if ($freeMB -lt ($FixtureBloatMB + $FixtureFreeSpaceMB)) { throw "Only ${freeMB}MB free on $($drive.Name):; a ${FixtureBloatMB}MB fixture would leave less than ${FixtureFreeSpaceMB}MB. Refusing." }
    $sub = Join-Path $cache $FixtureBloatSubdir
    if (-not (Test-Path -LiteralPath $sub)) { New-Item -ItemType Directory -Path $sub -Force -ErrorAction Stop | Out-Null }
    $path = Get-FixtureBloatPath
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    & fsutil.exe file createnew $path ([int64]$FixtureBloatMB * 1MB) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "fsutil file createnew failed with exit code $LASTEXITCODE for $path" }
    if (-not (Test-Path -LiteralPath $path)) { throw "fsutil reported success but $path does not exist" }
    (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-$FixtureBloatAgeDays)
    $state.CacheThresholdMB = [int][math]::Floor($realMB) + $FixtureBloatMB
}

function Test-FixtureBloatPlanted {
    $cache = Get-CacheDir
    if (-not (Test-Path -LiteralPath (Get-FixtureBloatPath))) { Write-Host "           $(Get-FixtureBloatPath) missing"; return $false }
    $mb  = Get-DirMB -Path $cache
    $thr = [int]$state.CacheThresholdMB
    if ($thr -le 0) { Write-Host '           CacheThresholdMB not set'; return $false }
    if ($mb -lt $thr) { Write-Host "           cache measures ${mb}MB, below the ${thr}MB threshold the script will be given"; return $false }
    return $true
}

function Get-NewCacheBakNames {
    param($Original)
    $before = @($Original.BakNames | Where-Object { $_ })
    return @(Get-CacheBakNames | Where-Object { $before -notcontains $_ })
}

function Restore-CacheBaseline {
    param($Original)
    $cache  = Get-CacheDir
    $parent = Get-CacheParentDir
    $newBaks = @(Get-NewCacheBakNames -Original $Original)
    # The fixture subfolder goes first, wherever the rename left it.
    foreach ($d in @($cache) + @($newBaks | ForEach-Object { Join-Path $parent $_ })) {
        $sub = Join-Path $d $FixtureBloatSubdir
        if (Test-Path -LiteralPath $sub) { Remove-Item -LiteralPath $sub -Recurse -Force -ErrorAction Stop }
    }
    if ([bool]$Original.CacheExisted) {
        # The user's real cache: put it back under its own name.
        if ($newBaks.Count -gt 1) { throw "More than one new cache backup ($($newBaks -join ', ')); cannot tell which is the user's cache. Rename it back to 'cache' by hand." }
        if ($newBaks.Count -eq 1) {
            if (Test-Path -LiteralPath $cache) { throw "Both $cache and $($newBaks[0]) exist ($AppName was launched mid-run?); leaving the backup in place. Merge or rename by hand." }
            Rename-Item -LiteralPath (Join-Path $parent $newBaks[0]) -NewName 'cache' -ErrorAction Stop
        }
        return
    }
    # The harness created the cache folder; remove it and any backup of it, but only when
    # nothing other than the fixture ever went in.
    foreach ($d in @($cache) + @($newBaks | ForEach-Object { Join-Path $parent $_ })) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $leftovers = @(Get-ChildItem -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue)
        if ($leftovers.Count -gt 0) { throw "$d holds $($leftovers.Count) item(s) the harness did not plant; not deleting it." }
        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
    }
    Remove-MissingDirectories -Paths @($Original.MissingDirs | Where-Object { $_ })
}

# -- Helpers: OpenNotebooks (step 7) -----------------------------------------------

function Get-RegisteredNotebooks {
    $k = Get-OpenNotebooksKeyPath
    if (-not (Test-Path -LiteralPath $k)) { return @() }
    return @(Get-ChildItem -LiteralPath $k -ErrorAction SilentlyContinue)
}

function Get-NotebookBaseline {
    @{ MissingKeys = @(Get-MissingRegistryKeys -Paths @((Get-UserAppKeyPath), (Get-OpenNotebooksKeyPath))) }
}

function Add-FixtureNotebook {
    New-RegistryKeyChain -Path (Get-OpenNotebooksKeyPath)
    $key = Get-FixtureNotebookKeyPath
    New-Item -Path $key -Force -ErrorAction Stop | Out-Null
    Set-ItemProperty -LiteralPath $key -Name 'Path' -Value $FixtureNotebookUrl -Type String -ErrorAction Stop
    Set-ItemProperty -LiteralPath $key -Name 'LastSyncError' -Value $FixtureSyncError -Type DWord -ErrorAction Stop
}

function Get-FixtureNotebookError {
    $key = Get-FixtureNotebookKeyPath
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    return (Get-Item -LiteralPath $key).GetValue('LastSyncError')
}

function Test-FixtureNotebookPlanted {
    $v = Get-FixtureNotebookError
    if ($null -eq $v) { Write-Host "           $(Get-FixtureNotebookKeyPath) or its LastSyncError missing"; return $false }
    if ([int64]$v -eq 0) { Write-Host '           LastSyncError is 0'; return $false }
    return $true
}

function Restore-FixtureNotebook {
    param($Original)
    $key = Get-FixtureNotebookKeyPath
    if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-MissingRegistryKeys -Paths @($Original.MissingKeys | Where-Object { $_ })
}

# -- Helpers: running the script under test --------------------------------------

function Get-RemediationVariables {
    $vars = @{
        AllowDestructiveActions = if ([bool]$state.DestructiveFlag) { 'true' } else { $null }
        ReenableDisabledItems   = if ([bool]$state.ReenableFlag)    { 'true' } else { $null }
        CacheSizeWarningMB      = if ($state.CacheThresholdMB) { "$([int]$state.CacheThresholdMB)" } else { $null }
    }
    return $vars
}

function Invoke-RemediationScript {
    # Returns @{ ExitCode; DurationSec; Variables; Output }; writes nothing to the output stream.
    # Stderr is captured as text: under 'Stop' the child's first stderr line would otherwise
    # become a terminating NativeCommandError.
    param([Parameter(Mandatory = $true)][hashtable]$Variables)

    $savedEnv = @{}
    foreach ($k in @($Variables.Keys)) { $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
    $sw      = [System.Diagnostics.Stopwatch]::StartNew()
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($k in @($Variables.Keys)) { [Environment]::SetEnvironmentVariable($k, $Variables[$k], 'Process') }
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1 |
                  ForEach-Object { "$_" }
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
        foreach ($k in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k], 'Process') }
    }
    $sw.Stop()

    return @{
        ExitCode    = $rc
        DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Variables   = $Variables
        Output      = ($output | Out-String).Trim()
    }
}

# -- Break definitions ---------------------------------------------------------
# DestructiveFlag / ReenableFlag: $true -- the run sets the variable to 'true'; $false -- unset; $null -- either.
# Group: breaks sharing a fixture; only the first drawn of a group runs.
$BreakCatalog = @(

    @{
        Name            = 'ThirdPartyAddinConflictGated'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        DestructiveFlag = $false
        ReenableFlag    = $null
        Group           = 'Addin'
        Methods         = @(@{ Name = 'PlantUserAddin'; Apply = { Add-FixtureAddin } })
        Capture  = { Get-FixtureAddinBaseline }
        Verify   = { Test-FixtureAddinPlanted }
        Validate = {
            $lb     = Get-FixtureAddinLoadBehavior
            $intact = ($lb -eq 3)
            if (-not $intact) { Write-Host "           $FixtureAddinName LoadBehavior is '$lb' after a gated run; expected 3" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step03_' -Pattern "^\[Warning\] \d+ active third-party add-in\(s\): .*$([regex]::Escape($FixtureAddinName)) \[user\].*\. Disabling the first one is the remediation -- set \`$AllowDestructiveActions=\`$true to apply\.$"
            return ($intact -and $reported)
        }
        Restore  = { param($Original) Restore-FixtureAddin -Original $Original }
    },

    @{
        Name            = 'ThirdPartyAddinConflict'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        DestructiveFlag = $true
        ReenableFlag    = $null
        Group           = 'Addin'
        Methods         = @(@{
            Name  = 'PlantUserAddin'
            Apply = {
                $real = @(Get-ActiveThirdPartyAddins)
                if ($real.Count -gt 0) { throw "A real active third-party add-in is registered ($($real -join '; ')); the ungated run could disable it instead of the fixture. Run ThirdPartyAddinConflictGated instead." }
                Add-FixtureAddin
            }
        })
        Capture  = { Get-FixtureAddinBaseline }
        Verify   = { Test-FixtureAddinPlanted }
        Validate = {
            $lb       = Get-FixtureAddinLoadBehavior
            $disabled = ($lb -eq 0)
            if (-not $disabled) { Write-Host "           $FixtureAddinName LoadBehavior is '$lb'; expected 0" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step03_' -Pattern "^\[Remediated\] Add-in '$([regex]::Escape($FixtureAddinName))' \[user\] set to LoadBehavior=0\. Restart $AppName to take effect\.$"
            return ($disabled -and $reported)
        }
        Restore  = { param($Original) Restore-FixtureAddin -Original $Original }
    },

    @{
        Name            = 'DisabledItemGated'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        DestructiveFlag = $null
        ReenableFlag    = $false
        Group           = 'Resiliency'
        Methods         = @(@{ Name = 'PlantDisabledItem'; Apply = { Add-FixtureDisabledItem } })
        Capture  = { Get-FixtureResiliencyBaseline }
        Verify   = { Test-FixtureDisabledItemPlanted }
        Validate = {
            $intact = Test-FixtureDisabledItemPresent
            if (-not $intact) { Write-Host "           $FixtureResiliencyValue is gone after a gated run" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step04_' -Pattern "^\[Warning\] \d+ disabled item\(s\), \d+ disabled startup item\(s\): .*$([regex]::Escape($FixtureDisabledItem)).*\. Set \`$ReenableDisabledItems=\`$true to clear them; Office disabled these after a failure, so confirm first\.$"
            return ($intact -and $reported)
        }
        Restore  = { param($Original) Restore-FixtureResiliency -Original $Original }
    },

    @{
        Name            = 'DisabledItem'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        DestructiveFlag = $null
        ReenableFlag    = $true
        Group           = 'Resiliency'
        Methods         = @(@{
            Name  = 'PlantDisabledItem'
            Apply = {
                $real = @(Get-RealResiliencyEntries)
                if ($real.Count -gt 0) { throw "Real Resiliency entries exist ($($real -join '; ')); the ungated run would clear them too. Run DisabledItemGated instead." }
                Add-FixtureDisabledItem
            }
        })
        Capture  = { Get-FixtureResiliencyBaseline }
        Verify   = { Test-FixtureDisabledItemPlanted }
        Validate = {
            $cleared = -not (Test-FixtureDisabledItemPresent)
            if (-not $cleared) { Write-Host "           $FixtureResiliencyValue still present after an ungated run" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step04_' -Pattern "^\[Remediated\] Cleared \d+ Resiliency entr(y|ies); items load at $AppName's next start\.$"
            return ($cleared -and $reported)
        }
        Restore  = { param($Original) Restore-FixtureResiliency -Original $Original }
    },

    @{
        Name            = 'NotebookCacheBloatGated'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        DestructiveFlag = $false
        ReenableFlag    = $null
        Group           = 'Cache'
        Methods         = @(@{ Name = 'PlantCacheBloat'; Apply = { New-FixtureBloat } })
        Capture  = { Get-CacheBaseline }
        Verify   = { Test-FixtureBloatPlanted }
        Validate = {
            param($Original)
            $still = Test-Path -LiteralPath (Get-CacheDir)
            if (-not $still) { Write-Host '           cache folder is gone after a gated run' }
            $newBaks = @(Get-NewCacheBakNames -Original $Original)
            if ($newBaks.Count -gt 0) { Write-Host "           a backup was made during a gated run: $($newBaks -join ', ')" }
            $thr = [int]$state.CacheThresholdMB
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step06_' -Pattern "^\[Warning\] Notebook cache is [\d.]+MB \(threshold ${thr}MB\)\. Rename to cache_<stamp>\.bak; $AppName re-syncs every open notebook from the service\. Unsynced local pages stay in the backup -- set \`$AllowDestructiveActions=\`$true to apply\."
            return ($still -and ($newBaks.Count -eq 0) -and $reported)
        }
        Restore  = { param($Original) Restore-CacheBaseline -Original $Original }
    },

    @{
        Name            = 'NotebookCacheBloat'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        DestructiveFlag = $true
        ReenableFlag    = $null
        Group           = 'Cache'
        Methods         = @(@{ Name = 'PlantCacheBloat'; Apply = { New-FixtureBloat } })
        Capture  = { Get-CacheBaseline }
        Verify   = {
            $planted = Test-FixtureBloatPlanted
            $closed  = -not (Test-AppRunning)
            if (-not $closed) { Write-Host "           $AppExe is running; the script refuses the rename while it is open. Close $AppName and re-run (the harness never kills it)." }
            return ($planted -and $closed)
        }
        Validate = {
            param($Original)
            $gone = -not (Test-Path -LiteralPath (Get-CacheDir))
            if (-not $gone) { Write-Host '           cache folder still present; it was not renamed' }
            $newBaks = @(Get-NewCacheBakNames -Original $Original)
            $oneBak  = ($newBaks.Count -eq 1) -and ($newBaks[0] -match '^cache_\d{8}-\d{6}\.bak$')
            if (-not $oneBak) { Write-Host "           expected exactly one new cache_<stamp>.bak, found: $(if ($newBaks.Count) { $newBaks -join ', ' } else { 'none' })" }
            $carried = $oneBak -and (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path (Get-CacheParentDir) $newBaks[0]) $FixtureBloatSubdir) $FixtureBloatFile))
            if ($oneBak -and -not $carried) { Write-Host '           the backup does not contain the fixture; something other than a rename happened' }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step06_' -Pattern "^\[Remediated\] Notebook cache renamed to cache_\d{8}-\d{6}\.bak; $AppName rebuilds it and re-syncs on next launch\."
            return ($gone -and $oneBak -and $carried -and $reported)
        }
        Restore  = { param($Original) Restore-CacheBaseline -Original $Original }
    },

    @{
        Name            = 'NotebookSyncError'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        DestructiveFlag = $null
        ReenableFlag    = $null
        Group           = 'Notebook'
        Methods         = @(@{ Name = 'PlantNotebookWithError'; Apply = { Add-FixtureNotebook } })
        Capture  = { Get-NotebookBaseline }
        Verify   = { Test-FixtureNotebookPlanted }
        Validate = {
            $v = Get-FixtureNotebookError
            $intact = ($null -ne $v) -and ([int64]$v -ne 0)
            if (-not $intact) { Write-Host "           fixture notebook LastSyncError is '$v' after a report-only run" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step07_' -Pattern "^\[Warning\] \d+ of \d+ notebook\(s\) report a sync error: .*$([regex]::Escape($FixtureNotebookName)) \(LastSyncError=0x80070005\).*\. Report only: sync errors are permission or service problems, not local state\.$"
            return ($intact -and $reported)
        }
        Restore  = { param($Original) Restore-FixtureNotebook -Original $Original }
    }
)

function Get-BreakDefinition {
    param([Parameter(Mandatory = $true)][string]$Name)
    $BreakCatalog | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Request-TestReboot {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    Save-DexTestState -State $State
    Register-DexTestResume -State $State -BreakTestPath $SelfPath
    Write-DexStep -Status 'Info' -Name 'Reboot' -Message 'Rebooting to apply pending state; run resumes automatically.'
    & shutdown.exe /r /t 15 /f | Out-Null
}

function Add-HarnessError {
    param([Parameter(Mandatory = $true)][hashtable]$State, [Parameter(Mandatory = $true)]$ErrorRecord, [string]$Context = '')
    $text = "$(if ($Context) { "$Context`: " })$($ErrorRecord.Exception.Message) (line $($ErrorRecord.InvocationInfo.ScriptLineNumber))"
    if ($State['HarnessError']) { $State['HarnessError'] = "$($State['HarnessError']); $text" } else { $State['HarnessError'] = $text }
}

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList

Write-DexBanner -Title "$ScriptUnderTest`_BreakTest" -Detail "Environment: $Environment"

# -- Restore-only mode ---------------------------------------------------------
if ($Restore) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    $toRestore = @($state.Breaks); [array]::Reverse($toRestore)
    foreach ($b in $toRestore) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
            Write-DexStep -Status 'Passed' -Name "Restore $($b.Name)"
        } catch {
            Add-HarnessError -State $state -ErrorRecord $_ -Context "Restore $($b.Name)"
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }
    Remove-Fixture
    Unregister-DexTestResume -State $state
    $state.Phase   = 'Restored'
    $state.Overall = 'Restored'
    Write-DexTestResult -State $state | Out-Null
    Clear-DexTestState -State $state
    exit 0
}

# -- Acquire context -----------------------------------------------------------
if ($Resume) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    if (Test-DexRebootOccurred -State $state) {
        $state.RebootCount = [int]$state.RebootCount + 1
        Write-DexStep -Status 'Info' -Name 'Resume' -Message "Reboot #$($state.RebootCount) confirmed; resuming at phase '$($state.Phase)'."
    } else {
        Write-DexStep -Status 'Warning' -Name 'Resume' -Message 'No reboot detected since the run started.'
    }
    $RemediationTest = [bool]$state.RemediationTest
} else {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Seed $Seed -Environment $Environment
    $state.RemediationTest = [bool]$RemediationTest
    Write-DexStep -Status 'Info' -Name 'Context' -Message "TestId $($state.TestId)  Seed $($state.Seed)"
}

$exitCode = 0

try {
    # -- Phase: apply breaks ---------------------------------------------------
    if ($state.Phase -eq 'Init') {

        Initialize-Fixture

        $candidates = if ($BreakName) {
            @($BreakCatalog | Where-Object { $BreakName -contains $_.Name })
        } else {
            @($BreakCatalog | Where-Object { $IncludeRebootBreaks -or -not $_.RequiresReboot })
        }
        if ($candidates.Count -eq 0) { throw 'No break definitions matched the requested selection.' }

        $selected = if ($BreakName) {
            $candidates
        } else {
            # Fresh copy: Get-DexRandomSubset shuffles the array it is handed in place.
            Get-DexRandomSubset -InputObject ([object[]]$candidates.Clone()) -Random $state.Random -Count $BreakCount
        }
        # Re-wrap in a second statement: the if-expression unrolls a one-element array.
        $selected = @($selected)

        # One environment variable per flag for the whole child process: gated and ungated
        # breaks of the same flag cannot share a run. The first drawn decides.
        foreach ($flag in @(@{ Field = 'DestructiveFlag'; Env = 'AllowDestructiveActions' }, @{ Field = 'ReenableFlag'; Env = 'ReenableDisabledItems' })) {
            $f = $flag.Field
            $flagged = @($selected | Where-Object { $null -ne $_[$f] })
            if ($flagged.Count -gt 0) {
                $runFlag = [bool]$flagged[0][$f]
                $dropped = @($selected | Where-Object { ($null -ne $_[$f]) -and ([bool]$_[$f] -ne $runFlag) })
                if ($dropped.Count -gt 0) {
                    $selected = @($selected | Where-Object { ($null -eq $_[$f]) -or ([bool]$_[$f] -eq $runFlag) })
                    Write-DexStep -Status 'Info' -Name 'Selection' -Message "gated and ungated breaks cannot share one `$env:$($flag.Env); kept flag=$runFlag, dropped $($dropped.Name -join ', ')"
                }
                $state[$f] = $runFlag
            } else {
                $state[$f] = $false
            }
        }
        # Breaks in the same Group share a fixture; keep the first drawn of each group.
        foreach ($g in @($selected | ForEach-Object { $_.Group } | Where-Object { $_ } | Select-Object -Unique)) {
            $inGroup = @($selected | Where-Object { $_.Group -eq $g })
            if ($inGroup.Count -gt 1) {
                $keep = $inGroup[0].Name
                $selected = @($selected | Where-Object { ($_.Group -ne $g) -or ($_.Name -eq $keep) })
                Write-DexStep -Status 'Info' -Name 'Selection' -Message "$g breaks share a fixture; kept '$keep', dropped $(($inGroup | Select-Object -Skip 1).Name -join ', ')"
            }
        }
        $state.CacheThresholdMB = $null

        # Never hand the script AllowDestructiveActions while step 3 could disable a real
        # add-in or step 6 could rename the user's real cache on its own merits.
        if ($state.DestructiveFlag) {
            $real = @(Get-ActiveThirdPartyAddins)
            if ($real.Count -gt 0) { throw "AllowDestructiveActions would be set while a real active third-party add-in is registered ($($real -join '; ')); step 3 could disable it. Refusing." }
            if (@($selected | Where-Object { $_.Group -eq 'Cache' }).Count -eq 0) {
                $realMB = Get-DirMB -Path (Get-CacheDir)
                if ($realMB -ge $ScriptDefaultCacheMB) { throw "The real notebook cache is ${realMB}MB, at or over the script's default ${ScriptDefaultCacheMB}MB; an ungated run would rename it. Refusing." }
                if (Test-CacheCorrupt) { throw "The real notebook cache has a zero-byte 0.onecache with notebooks registered; an ungated run would rename it. Refusing." }
            }
        }

        $applied = @()
        foreach ($def in $selected) {
            $method = (Get-DexRandomSubset -InputObject ([object[]]@($def.Methods).Clone()) -Random $state.Random -Count 1)[0]

            $original = & $def.Capture
            & $method.Apply

            if ($def.RequiresReboot) { $state.RequiresReboot = $true }

            $applied += @{
                Name            = $def.Name
                Method          = $method.Name
                ExpectedOutcome = $def.ExpectedOutcome
                RequiresReboot  = [bool]$def.RequiresReboot
                Applied         = $true
                BreakVerified   = $false
                OriginalState   = $original
            }
            Write-DexStep -Status 'Info' -Name "Break $($def.Name)" -Message "method '$($method.Name)' applied"
            $state.Breaks = $applied
            Save-DexTestState -State $state
        }

        $state.Breaks = $applied
        $state.Phase  = 'Broken'
        Save-DexTestState -State $state

        if ($state.RequiresReboot) { Request-TestReboot -State $state; exit 0 }
    }

    # -- Phase: verify the break -----------------------------------------------
    if ($state.Phase -eq 'Broken') {
        $allVerified = $true
        foreach ($b in $state.Breaks) {
            $def = Get-BreakDefinition -Name $b.Name
            $ok  = [bool](& $def.Verify)
            $b.BreakVerified = $ok
            if ($ok) {
                Write-DexStep -Status 'Passed' -Name "Verify $($b.Name)" -Message 'component is genuinely broken'
            } else {
                $allVerified = $false
                Write-DexStep -Status 'Failed' -Name "Verify $($b.Name)" -Message 'break did not land; remediation would be a false green'
            }
        }
        if (-not $allVerified) {
            $state.Phase   = 'BreakFailed'
            $state.Overall = 'BreakFailed'
            Save-DexTestState -State $state
            throw 'One or more breaks could not be verified; refusing to run remediation.'
        }
        $state.Phase = 'BreakVerified'
        Save-DexTestState -State $state
    }

    # -- Phase: remediate ------------------------------------------------------
    if ($state.Phase -eq 'BreakVerified') {
        if (-not $RemediationTest) {
            $state.Overall = 'BreakOnly'
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message 'skipped (-RemediationTest not supplied)'
        } else {
            $vars = Get-RemediationVariables
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message ("invoking $([System.IO.Path]::GetFileName($RemediationScript)) with " + (($vars.Keys | Sort-Object | ForEach-Object { "$_='$($vars[$_])'" }) -join ' '))
            $state.Remediation = Invoke-RemediationScript -Variables $vars
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "exit $($state.Remediation.ExitCode) in $($state.Remediation.DurationSec) s"
            $state.Phase = 'Remediated'
            Save-DexTestState -State $state
            if ($state.RequiresReboot) { Request-TestReboot -State $state; exit 0 }
        }
    }

    # -- Phase: validate -------------------------------------------------------
    if ($state.Phase -eq 'Remediated') {
        $validation = @()
        foreach ($b in $state.Breaks) {
            $def    = Get-BreakDefinition -Name $b.Name
            $passed = [bool](& $def.Validate ([PSCustomObject]$b.OriginalState))
            $expected = if ($b.ExpectedOutcome -eq 'ExpectFixed') { 'component repaired by remediation' } else { 'component detected and reported, left unmodified' }
            $validation += @{
                Name     = $b.Name
                Expected = $expected
                Actual   = if ($passed) { 'as expected' } else { 'NOT as expected' }
                Result   = if ($passed) { 'Pass' } else { 'Fail' }
            }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) -Name "Validate $($b.Name)" -Message $expected
        }
        $state.Validation = $validation
        $state.Phase      = 'Validated'
        $failedCount = @($validation | Where-Object { $_.Result -eq 'Fail' }).Count
        $state.Overall = if ($failedCount -eq 0) { 'Passed' }
                         elseif ($state.Remediation -and [int]$state.Remediation.ExitCode -eq 0) { 'FalsePass' }
                         else { 'Failed' }
        Save-DexTestState -State $state
    }

} catch {
    Write-DexStep -Status 'Failed' -Name 'Harness' -Message $_.Exception.Message
    Add-HarnessError -State $state -ErrorRecord $_
    if ($state.Overall -eq 'Incomplete') { $state.Overall = 'Failed' }
    $exitCode = 1
}

# -- Restore -------------------------------------------------------------------
if ($Environment -eq 'Physical') {
    $restoreFailed = $false
    $toRestore = @($state.Breaks); [array]::Reverse($toRestore)
    foreach ($b in $toRestore) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
        } catch {
            $restoreFailed = $true
            Add-HarnessError -State $state -ErrorRecord $_ -Context "Restore $($b.Name)"
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }
    try { Remove-Fixture } catch { $restoreFailed = $true; Add-HarnessError -State $state -ErrorRecord $_ -Context 'Remove-Fixture' }

    if ($restoreFailed) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'machine left modified -- manual cleanup required'
    } else {
        $state.Phase = 'Restored'
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'machine returned to baseline'
    }
}

Unregister-DexTestResume -State $state

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) -Name 'Overall' -Message $state.Overall

Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state

exit $exitCode
