<#
.SYNOPSIS
    Invoke-AutoRemediateAccess_BreakTest -- deliberately plants Access faults, then
    verifies Invoke-AutoRemediateAccess.ps1 reports or repairs them as documented.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateAccess\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It writes an add-in key, a Resiliency
    DisabledItems entry and a File MRU item into the logged-on user's Access hive, drops
    a fixture .accdb (and .laccdb) under C:\Temp\DEXTest\Access, and lowers the script's
    database-size threshold. Run it only on a disposable VM or a marked test host. See
    Assert-DexTestHost in DEXTestFramework.psm1.

    WHAT IS BROKEN AND HOW IT COMES BACK
    The script resolves the user from Win32_ComputerSystem.UserName and reads the hive
    through HKEY_USERS\<SID>; so does this harness, so run it elevated as the interactive
    user. Every artefact carries the DEXTest prefix. Each break Captures what it is about
    to change (keys and folders it had to create, real Resiliency entry names, real MRU
    items) and Restore removes only what was planted, deepest first, keys and folders only
    when empty afterwards. MRU cleanup finds the fixture item by its value, not the name
    chosen at plant time, because Access renumbers the MRU on exit.

    GATES
    Step 3 remediates only with $env:AllowDestructiveActions = true, step 4 only with
    $env:ReenableDisabledItems = true; each has a gated (ExpectReportedOnly) and an ungated
    (ExpectFixed) break. A flag is one variable for the whole child, so gated and ungated
    breaks of one flag cannot share a run: the first drawn decides, the rest are dropped.
    The script disables the FIRST third-party add-in and clears EVERY Resiliency entry, so
    the ungated breaks refuse when a real add-in or entry exists, and AllowDestructiveActions
    is never set while a real third-party add-in is active. The three database breaks share
    one fixture (Group 'Database') and are mutually exclusive.

    EXPECTED OUTCOMES (from the script's own messages, 1.0.1; the regexes sit in Validate)
    ThirdPartyAddinConflictGated  ExpectReportedOnly. DEXTest.Addin LoadBehavior 3 under
                                  HKU\<SID>\...\Office\16.0\Access\Addins; still 3 afterwards;
                                  Step03 "[Warning] 1 active third-party add-in(s): DEXTest.Addin
                                  [user]. Disabling the first one is the remediation -- set ...".
    ThirdPartyAddinConflict       ExpectFixed. Flag 'true'; LoadBehavior 0; Step03 "[Remediated]
                                  Add-in 'DEXTest.Addin' [user] set to LoadBehavior=0. ...".
    DisabledItemGated             ExpectReportedOnly. REG_BINARY DEXTest01 under
                                  ...\Access\Resiliency\DisabledItems decoding to DEXTest.Addin;
                                  still there; Step04 "[Warning] 1 disabled item(s), 0 disabled
                                  startup item(s): DEXTest.Addin. Set $ReenableDisabledItems...".
    DisabledItem                  ExpectFixed. ReenableDisabledItems 'true'; value gone; Step04
                                  "[Remediated] Cleared 1 Resiliency entry; items load at ...".
    StaleLockFile                 ExpectReportedOnly. C:\Temp\DEXTest\Access\DEXTest_lab.accdb +
                                  .laccdb + File MRU item; MSACCESS.EXE must be closed (never
                                  killed). Lock still present; Step07 "[Warning] stale lock
                                  file(s) with no Access running: ...DEXTest_lab.laccdb -- ...".
    DatabaseNearLimit             ExpectReportedOnly. Fixture sized 64 MB, CacheSizeWarningMB=64
                                  handed to the script; file untouched; Step07 "[Warning] near
                                  the 2GB engine limit: DEXTest_lab.accdb (64MB) -- ...".
    UntrustedMruDatabase          ExpectReportedOnly, CONDITIONAL. Fixture + MRU item outside
                                  every trusted location. Step 6 evaluates the MRU only after
                                  step 2 counted a real MSACCESS.EXE 1000/1002 event in 7 days
                                  (the harness plants none), so the break is excluded from the
                                  random draw while no such event exists and Verify fails with
                                  that explanation when forced by -BreakName. Step06 "[Warning]
                                  1 of 1 recent database(s) open from outside the <n> trusted
                                  location(s): ...DEXTest_lab.accdb. ... Report only: ...".

    NOT COVERED
      Step 2 Crash and Hang History -- planting real 1000/1002 events is out of bounds.
      Step 3 Failed branch (crash module matches an add-in name) -- needs a step 2 crash
             naming a module; note that branch remediates WITHOUT the AllowDestructiveActions
             gate (the engine remediates every Failed status).
      Step 6 on a host with no Access crash in 7 days -- see UntrustedMruDatabase.
      Step 8 Office C2R Update Health -- Enabled = $false in this script (Word owns it).
      No-user branches ($_noUser) -- need a session with nobody logged on.

    REBOOTS
    No break in this catalog requires a reboot. The reboot plumbing is kept so the
    harness stays uniform with the rest of the family.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateAccess.ps1 and validate the outcome.
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
    Script Name  : Invoke-AutoRemediateAccess_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated), run as the interactive user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateAccess\

    1.0.0  Initial: add-in gated/ungated, Resiliency gated/ungated, StaleLockFile,
           DatabaseNearLimit, UntrustedMruDatabase (conditional). Tracks script 1.0.1.

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

$ScriptUnderTest   = 'Invoke-AutoRemediateAccess'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateAccess.ps1'
$AppName           = 'Access'
$AppExe            = 'MSACCESS.EXE'
$AppProcess        = 'MSACCESS'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\AccessErrors'
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
# Everything planted on disk or in the registry carries this prefix and is the only
# thing the sweep in Remove-Fixture will touch.
$FixturePrefix          = 'DEXTest'
$FixtureAddinName       = 'DEXTest.Addin'      # must NOT match the script's $_msAddin matcher
$FixtureResiliencyValue = 'DEXTest01'          # REG_BINARY value name under Resiliency\DisabledItems
$FixtureDisabledItem    = 'DEXTest.Addin'      # what _DecodeResiliency must read out of that value
$FixtureDbDir           = 'C:\Temp\DEXTest\Access'
$FixtureDbName          = 'DEXTest_lab.accdb'
$FixtureLockName        = 'DEXTest_lab.laccdb' # the script derives .laccdb from .accd*
$FixtureDbBigMB         = 64                   # fixture size and the threshold handed to the script
$FixtureMruPrefix       = '[F00000000][T01DB0000][O00000000]*'   # the bracket prefix _MruDatabases strips
$FixtureFreeSpaceMB     = 512

# Same matcher as the script, verbatim, so "third-party" means the same thing here.
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
    $thirdParty = @(Get-ActiveThirdPartyAddins)
    $realRes    = @(Get-RealResiliencyEntries)
    Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Office $(Get-OfficeVersion) ($((Get-C2RConfig).VersionToReport)); user $user; real active third-party add-ins: $($thirdParty.Count); real Resiliency entries: $($realRes.Count); File MRU items: $(@(Get-MruItems).Count); $AppExe crash/hang in 7 days: $(Test-AppCrashInWindow); $AppExe running: $(Test-AppRunning)"
}

function Remove-Fixture {
    # Sweep by prefix. The per-break Restore blocks have normally done all of this already;
    # this catches anything a half-finished run left behind.
    try {
        $key = Get-FixtureAddinKeyPath
        if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
    try {
        $k = Get-DisabledItemsKeyPath
        if (Test-Path -LiteralPath $k) { Remove-ItemProperty -LiteralPath $k -Name $FixtureResiliencyValue -ErrorAction SilentlyContinue }
    } catch { }
    try { Remove-FixtureMruItems } catch { }
    try {
        if (Test-Path -LiteralPath $FixtureDbDir) {
            foreach ($f in @(Get-ChildItem -LiteralPath $FixtureDbDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$FixturePrefix*" })) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            }
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
    $shortName = (Get-LoggedOnUser).Split('\')[-1]
    $p = "C:\Users\$shortName"
    if (-not (Test-Path -LiteralPath $p)) { throw "Profile folder '$p' for the logged-on user not found." }
    return $p
}

function Get-C2RConfig {
    Get-ItemProperty -LiteralPath $C2RConfigPath -ErrorAction SilentlyContinue
}

function Test-AppInstalled {
    # Mirrors the script's pre-flight: the Configuration key AND the exe under a C2R root.
    if (-not (Get-C2RConfig)) { return $false }
    foreach ($p in @("$env:ProgramFiles\Microsoft Office\root\Office16", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16")) {
        if (Test-Path -LiteralPath (Join-Path $p $AppExe)) { return $true }
    }
    return $false
}

function Get-OfficeVersion {
    # Same resolution as the script: VersionToReport major.minor, else 16.0.
    $cfg = Get-C2RConfig
    if ($cfg -and $cfg.VersionToReport) {
        $parts = "$($cfg.VersionToReport)".Split('.')
        if ($parts.Count -ge 2) { return "$($parts[0]).$($parts[1])" }
    }
    return '16.0'
}

function Get-UserHivePath       { "Registry::HKEY_USERS\$(Get-LoggedOnUserSid)" }
function Get-UserAppKeyPath     { "$(Get-UserHivePath)\Software\Microsoft\Office\$(Get-OfficeVersion)\$AppName" }
function Get-UserAddinsKeyPath  { "$(Get-UserAppKeyPath)\Addins" }
function Get-FixtureAddinKeyPath { "$(Get-UserAddinsKeyPath)\$FixtureAddinName" }
function Get-ResiliencyKeyPath  { "$(Get-UserAppKeyPath)\Resiliency" }
function Get-DisabledItemsKeyPath { "$(Get-ResiliencyKeyPath)\DisabledItems" }
function Get-StartupItemsKeyPath  { "$(Get-ResiliencyKeyPath)\StartupItems" }
function Get-MruKeyPath         { "$(Get-UserAppKeyPath)\File MRU" }

function Test-AppRunning { [bool](Get-Process -Name $AppProcess -ErrorAction SilentlyContinue) }

function Test-AppCrashInWindow {
    # Mirrors step 2: Application Error 1000 / Application Hang 1002 naming the exe in 7 days.
    # Read-only; the harness never plants events. Get-WinEvent is fine on the 5.1 x64 harness engine.
    $since = (Get-Date).AddDays(-7)
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = @('Application Error', 'Application Hang'); Id = @(1000, 1002); StartTime = $since } -ErrorAction SilentlyContinue |
            Where-Object { $_.Properties.Count -gt 0 -and "$($_.Properties[0].Value)" -ieq $AppExe })
    return ($ev.Count -gt 0)
}

function Get-MissingRegistryKeys {
    # Parent-first list of the keys that do not exist yet. Capture records this so Restore
    # removes exactly the keys the break had to create. Plain array; callers wrap in @().
    param([Parameter(Mandatory = $true)][string[]]$Paths)
    $missing = @()
    foreach ($p in $Paths) { if (-not (Test-Path -LiteralPath $p)) { $missing += $p } }
    return @($missing)
}

function Remove-MissingRegistryKeys {
    # Deepest first; a key is removed only if it is now empty, so one Office has since
    # started using is left alone.
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
    # The text the script wrote to DEXRecords for one step, or $null. Value names are
    # Step<nn>_<name without punctuation>; the text starts with [Warning], [Failed] or [Remediated].
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
    # The same six roots as the script's _AddinKeys, existing ones only. Plain array.
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
    # Every add-in the script would count as active third-party, excluding our fixture. Plain array.
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
    # The script's _DecodeResiliency for one value: first null-separated Unicode segment
    # with three letters, else the value name.
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
    # Value names under DisabledItems and StartupItems that are not ours. Plain array.
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
    # Office stores REG_BINARY blobs of null-separated Unicode strings; the script reads
    # the first segment with letters, so the payload leads with the item name.
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

# -- Helpers: database fixture and File MRU (step 7) -------------------------------

function Get-FixtureDbPath   { Join-Path $FixtureDbDir $FixtureDbName }
function Get-FixtureLockPath { Join-Path $FixtureDbDir $FixtureLockName }

function Get-MruItems {
    # @{ Name; Value } for every "Item N" under File MRU. Plain array.
    $k = Get-MruKeyPath
    if (-not (Test-Path -LiteralPath $k)) { return @() }
    $p = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
    if (-not $p) { return @() }
    return @($p.PSObject.Properties | Where-Object { $_.Name -match '^Item \d+$' } | ForEach-Object { @{ Name = $_.Name; Value = "$($_.Value)" } })
}

function Get-FixtureMruItemNames {
    # Items whose value points at our fixture database, by content rather than by the name
    # we chose: Access renumbers the MRU on exit and a stale name could hit a real entry.
    $path = Get-FixtureDbPath
    return @(Get-MruItems | Where-Object { $_.Value -like "*$path" } | ForEach-Object { $_.Name })
}

function Add-FixtureMruItem {
    New-RegistryKeyChain -Path (Get-MruKeyPath)
    $max = 0
    foreach ($i in @(Get-MruItems)) { $n = [int]($i.Name -replace '^Item ', ''); if ($n -gt $max) { $max = $n } }
    $name = "Item $($max + 1)"
    Set-ItemProperty -LiteralPath (Get-MruKeyPath) -Name $name -Value "$FixtureMruPrefix$(Get-FixtureDbPath)" -Type String -ErrorAction Stop
}

function Remove-FixtureMruItems {
    $k = Get-MruKeyPath
    if (-not (Test-Path -LiteralPath $k)) { return }
    foreach ($n in @(Get-FixtureMruItemNames)) { Remove-ItemProperty -LiteralPath $k -Name $n -ErrorAction SilentlyContinue }
}

function Test-FixtureMruResolves {
    # Parses our item the way _MruDatabases does and checks it lands on the fixture.
    $path = Get-FixtureDbPath
    foreach ($i in @(Get-MruItems)) {
        $p = (($i.Value -replace '^(\[[^\]]*\])*\*', '').Trim())
        if ($p -ieq $path -and $p -match '\.(accd[a-z]|md[a-z])$') { return $true }
    }
    Write-Host "           no File MRU item resolves to $path"
    return $false
}

function Test-FixtureOutsideTrustedLocations {
    # The script's step 6 test, inverted: true when no trusted location (user hive or policy)
    # covers the fixture database. Host-stream diagnostics only.
    $db  = Get-FixtureDbPath
    $dir = (Split-Path -Path $db -Parent).TrimEnd('\') + '\'
    foreach ($root in @("$(Get-UserAppKeyPath)\Security\Trusted Locations", "$(Get-UserHivePath)\Software\Policies\Microsoft\Office\$(Get-OfficeVersion)\$AppName\Security\Trusted Locations")) {
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.Path) { continue }
            $tp  = ([Environment]::ExpandEnvironmentVariables("$($p.Path)")).TrimEnd('\') + '\'
            $sub = ([int]$p.AllowSubfolders -eq 1)
            if (($sub -and $db.StartsWith($tp, 'OrdinalIgnoreCase')) -or ($dir -ieq $tp)) { Write-Host "           $db falls under trusted location $tp"; return $false }
        }
    }
    return $true
}

function New-FixtureDatabase {
    # SizeMB 0 writes a small placeholder (step 7 only needs the file to exist); otherwise
    # fsutil makes a zero-filled file of that size, as the lab runbook does.
    param([int]$SizeMB = 0)
    if (-not (Test-Path -LiteralPath $FixtureDbDir)) { New-Item -ItemType Directory -Path $FixtureDbDir -Force -ErrorAction Stop | Out-Null }
    $path = Get-FixtureDbPath
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    if ($SizeMB -le 0) {
        Set-Content -LiteralPath $path -Value "Planted by $ScriptUnderTest`_BreakTest.ps1; not a real database; safe to delete." -Encoding ASCII -ErrorAction Stop
        return
    }
    $drive  = Get-PSDrive -Name ($FixtureDbDir.Substring(0, 1)) -ErrorAction Stop
    $freeMB = [math]::Floor($drive.Free / 1MB)
    if ($freeMB -lt ($SizeMB + $FixtureFreeSpaceMB)) { throw "Only ${freeMB}MB free on $($drive.Name):; a ${SizeMB}MB fixture would leave less than ${FixtureFreeSpaceMB}MB. Refusing." }
    & fsutil.exe file createnew $path ([int64]$SizeMB * 1MB) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "fsutil file createnew failed with exit code $LASTEXITCODE for $path" }
    if (-not (Test-Path -LiteralPath $path)) { throw "fsutil reported success but $path does not exist" }
}

function New-FixtureLockFile {
    Set-Content -LiteralPath (Get-FixtureLockPath) -Value 'DEXTest stale lock' -Encoding ASCII -ErrorAction Stop
}

function Get-DatabaseFixtureBaseline {
    @{
        MissingKeys = @(Get-MissingRegistryKeys -Paths @((Get-UserAppKeyPath), (Get-MruKeyPath)))
        MissingDirs = @(Get-MissingDirectories -Paths @('C:\Temp', 'C:\Temp\DEXTest', $FixtureDbDir))
        RealMruCount = @(Get-MruItems).Count
    }
}

function Restore-DatabaseFixture {
    param($Original)
    Remove-FixtureMruItems
    Remove-MissingRegistryKeys -Paths @($Original.MissingKeys | Where-Object { $_ })
    foreach ($p in @((Get-FixtureDbPath), (Get-FixtureLockPath))) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
    Remove-MissingDirectories -Paths @($Original.MissingDirs | Where-Object { $_ })
}

# -- Helpers: running the script under test --------------------------------------

function Get-RemediationVariables {
    # Every variable the child must see for this run. A $null value removes the variable.
    $vars = @{
        AllowDestructiveActions = if ([bool]$state.DestructiveFlag) { 'true' } else { $null }
        ReenableDisabledItems   = if ([bool]$state.ReenableFlag)    { 'true' } else { $null }
        CacheSizeWarningMB      = if ($state.CacheThresholdMB) { "$([int]$state.CacheThresholdMB)" } else { $null }
    }
    return $vars
}

function Invoke-RemediationScript {
    <#
        Runs the script under test once with the given variables and returns
        @{ ExitCode; DurationSec; Variables; Output }. Writes nothing to the output stream.
        Stderr from the child is captured as text: under the harness's
        $ErrorActionPreference = 'Stop' the first stderr line of a native command redirected
        with 2>&1 would otherwise become a terminating NativeCommandError.
    #>
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
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
# DestructiveFlag / ReenableFlag: $true -- the run must set the variable to 'true'
#                                 $false -- the run must leave it unset
#                                 $null  -- either
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
                # The script disables the FIRST active third-party add-in it finds; a real one
                # could be the one disabled. Refuse rather than risk it.
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
                # The script clears EVERY entry under DisabledItems and StartupItems; never let
                # it clear the user's real ones.
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
        Name            = 'StaleLockFile'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        DestructiveFlag = $null
        ReenableFlag    = $null
        Group           = 'Database'
        Methods         = @(@{
            Name  = 'PlantLockedMruDatabase'
            Apply = { New-FixtureDatabase -SizeMB 0; New-FixtureLockFile; Add-FixtureMruItem }
        })
        Capture  = { Get-DatabaseFixtureBaseline }
        Verify   = {
            $db   = Test-Path -LiteralPath (Get-FixtureDbPath)
            $lock = Test-Path -LiteralPath (Get-FixtureLockPath)
            if (-not $db)   { Write-Host "           $(Get-FixtureDbPath) missing" }
            if (-not $lock) { Write-Host "           $(Get-FixtureLockPath) missing" }
            $mru  = Test-FixtureMruResolves
            $closed = -not (Test-AppRunning)
            if (-not $closed) { Write-Host "           $AppExe is running; step 7 only reports locks while no $AppName runs. Close $AppName and re-run (the harness never kills it)." }
            return ($db -and $lock -and $mru -and $closed)
        }
        Validate = {
            $still = Test-Path -LiteralPath (Get-FixtureLockPath)
            if (-not $still) { Write-Host '           lock file is gone; the report-only step must not remove it' }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step07_' -Pattern "^\[Warning\] .*stale lock file\(s\) with no $AppName running: .*$([regex]::Escape($FixtureLockName)).* -- another user or a crashed session holds them; expect 'file already in use'\. Report only; the database owner acts on this\.$"
            return ($still -and $reported)
        }
        Restore  = { param($Original) Restore-DatabaseFixture -Original $Original }
    },

    @{
        Name            = 'DatabaseNearLimit'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        DestructiveFlag = $null
        ReenableFlag    = $null
        Group           = 'Database'
        Methods         = @(@{
            Name  = 'PlantLargeMruDatabase'
            Apply = {
                New-FixtureDatabase -SizeMB $FixtureDbBigMB
                Add-FixtureMruItem
                # Hand the script a threshold the fixture meets; the default 1536 MB is out of reach.
                $state.CacheThresholdMB = $FixtureDbBigMB
            }
        })
        Capture  = { Get-DatabaseFixtureBaseline }
        Verify   = {
            $path = Get-FixtureDbPath
            if (-not (Test-Path -LiteralPath $path)) { Write-Host "           $path missing"; return $false }
            $mb = [math]::Round((Get-Item -LiteralPath $path).Length / 1MB)
            $big = ($mb -ge $FixtureDbBigMB)
            if (-not $big) { Write-Host "           fixture is ${mb}MB, below ${FixtureDbBigMB}MB" }
            $thr = ([int]$state.CacheThresholdMB -eq $FixtureDbBigMB)
            if (-not $thr) { Write-Host "           CacheThresholdMB is '$($state.CacheThresholdMB)', expected $FixtureDbBigMB" }
            $mru = Test-FixtureMruResolves
            return ($big -and $thr -and $mru)
        }
        Validate = {
            $path = Get-FixtureDbPath
            $untouched = (Test-Path -LiteralPath $path) -and ([math]::Round((Get-Item -LiteralPath $path).Length / 1MB) -eq $FixtureDbBigMB)
            if (-not $untouched) { Write-Host '           fixture database changed or vanished; the report-only step must not touch it' }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step07_' -Pattern "^\[Warning\] near the 2GB engine limit: .*$([regex]::Escape($FixtureDbName)) \(${FixtureDbBigMB}MB\).* -- the owner should compact and repair.*\. Report only; the database owner acts on this\.$"
            return ($untouched -and $reported)
        }
        Restore  = { param($Original) Restore-DatabaseFixture -Original $Original }
    },

    @{
        Name            = 'UntrustedMruDatabase'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        DestructiveFlag = $null
        ReenableFlag    = $null
        Group           = 'Database'
        # Step 6 reads the MRU only after step 2 counted a crash. The harness plants no events,
        # so the break leaves the random draw while no real MSACCESS.EXE 1000/1002 exists.
        Precondition    = { Test-AppCrashInWindow }
        Methods         = @(@{ Name = 'PlantUntrustedMruDatabase'; Apply = { New-FixtureDatabase -SizeMB 0; Add-FixtureMruItem } })
        Capture  = { Get-DatabaseFixtureBaseline }
        Verify   = {
            $crash = Test-AppCrashInWindow
            if (-not $crash) { Write-Host "           no $AppExe crash or hang event in the last 7 days; step 6 reports 'Not indicated' and never reads the MRU. Coverable only after a real $AppName crash." }
            $mru       = Test-FixtureMruResolves
            $untrusted = Test-FixtureOutsideTrustedLocations
            return ($crash -and $mru -and $untrusted)
        }
        Validate = {
            $still = (Test-Path -LiteralPath (Get-FixtureDbPath)) -and (Test-FixtureMruResolves)
            if (-not $still) { Write-Host '           fixture database or its MRU item is gone; the report-only step must not touch them' }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step06_' -Pattern "^\[Warning\] \d+ of \d+ recent database\(s\) open from outside the \d+ trusted location\(s\): .*$([regex]::Escape($FixtureDbName)).*\. Macros and VBA run disabled there and some solutions fail or crash as a result\. Report only: trust decisions are policy\.$"
            return ($still -and $reported)
        }
        Restore  = { param($Original) Restore-DatabaseFixture -Original $Original }
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

        # A break whose Precondition is not met on this host leaves the random draw; -BreakName
        # still forces it, and its Verify then explains why it cannot land.
        if (-not $BreakName) {
            $unmet = @($candidates | Where-Object { $_.Precondition -and -not [bool](& $_.Precondition) })
            if ($unmet.Count -gt 0) {
                $candidates = @($candidates | Where-Object { $unmet.Name -notcontains $_.Name })
                Write-DexStep -Status 'Info' -Name 'Selection' -Message "precondition not met on this host; excluded from the draw: $($unmet.Name -join ', ')"
            }
            if ($candidates.Count -eq 0) { throw 'No break definitions remain after precondition filtering.' }
        }

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

        # Never hand the script AllowDestructiveActions while a real third-party add-in is
        # active: step 3 disables the first one it finds.
        if ($state.DestructiveFlag) {
            $real = @(Get-ActiveThirdPartyAddins)
            if ($real.Count -gt 0) { throw "AllowDestructiveActions would be set while a real active third-party add-in is registered ($($real -join '; ')); step 3 could disable it. Refusing." }
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
            # Commit at once so Restore can undo this break even if a later Capture/Apply throws.
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
    # Newest first so the oldest Capture, the true baseline, wins.
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
