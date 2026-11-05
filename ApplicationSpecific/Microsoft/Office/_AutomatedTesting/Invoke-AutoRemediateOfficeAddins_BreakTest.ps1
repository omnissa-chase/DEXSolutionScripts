<#
.SYNOPSIS
    Invoke-AutoRemediateOfficeAddins_BreakTest -- deliberately plants Office add-in and
    Resiliency faults, then verifies Invoke-AutoRemediateOfficeAddins.ps1 reports or
    repairs them as documented.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform JSON
    result to C:\Temp\FixReport\Invoke-AutoRemediateOfficeAddins\ for Invoke-FixReportAnalysis.ps1.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It writes an add-in key and a Resiliency entry
    into the logged-on user's Office hive for one of six apps. Run it only on a marked test
    host (Assert-DexTestHost in DEXTestFramework.psm1).

    HOW THE SCRIPT SEES THE USER
    Invoke-AutoRemediateOfficeAddins.ps1 resolves the logged-on user from
    Win32_ComputerSystem.UserName and reads HKEY_USERS\<SID>, so the harness does the same.
    Run elevated as the interactive user; the child powershell.exe runs in this same
    context, as Workspace ONE Hub would, with the script's inputs passed as environment
    variables (AllowDestructiveActions, ReenableDisabledItems, CrashWarnCount7d). Every
    planted artefact carries the DEXTest prefix; every break Captures what it changes and
    Restore writes it back.

    ONE APP PER BREAK, ONE ENVIRONMENT PER RUN
    Each break's Methods are the six apps the script covers (Word, Excel, PowerPoint,
    Access, OneNote, Publisher), filtered to the ones installed here, so a seeded draw picks
    an app per break. The script writes one pair of steps per app (Order 2i-1 and 2i for app
    index i), and Validate reads that app's Step<NN>_ value under DEXRecords\OfficeAddinsErrors.
    Each break declares the variables the child must see (Env); '' means "must be unset".
    The flag is one value for the whole child process, so a gated break (flag unset,
    ExpectReportedOnly) and its ungated twin (flag 'true', ExpectFixed) cannot share a run:
    the first drawn decides and conflicting draws are dropped. An ungated run is refused
    when real state would be acted on in ANY of the six apps: a real active third-party
    add-in (the script disables the first one per app) or a real Resiliency entry (the
    script clears every entry).

    EXPECTED OUTCOMES (derived from the script's own messages, 1.0.0)
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    Add-in   ThirdPartyAddinConflictGated  ReportedOnly. DEXTest.LabAddin, LoadBehavior 3, under
                                           HKU\<SID>\Software\Microsoft\Office\<App>\Addins.
             ThirdPartyAddinConflict       Fixed (AllowDestructiveActions). LoadBehavior becomes 0.
                                           Aborts when a real active third-party add-in exists.
    Disabled DisabledItemGated             ReportedOnly. REG_BINARY 'DEXTest' entry under
                                           <ver>\<App>\Resiliency\DisabledItems in Office's shape.
             DisabledItem                  Fixed (ReenableDisabledItems). The entry is cleared.
                                           Aborts when real Resiliency entries exist.

    NOT COVERED
      The Failed branch (crash module matches an add-in name) -- the only trigger is a real
      1000 event naming the app; the harness never writes to the Application log.
      The "<App> is not installed" branch -- an app missing here is simply never drawn.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateOfficeAddins.ps1 and validate. Without it: break and report.
.PARAMETER Environment
    Physical (default) restores when the run ends; Snapshot skips restore.
.PARAMETER Seed
    Replays an earlier run's random selection. Always recorded in the result.
.PARAMETER BreakName
    Force specific breaks instead of a random selection.
.PARAMETER BreakCount
    How many breaks to draw randomly. Default 2 (conflicting draws are dropped).
.PARAMETER IncludeRebootBreaks
    Kept for family parity; no break here needs a reboot.
.PARAMETER Restore
    Undo an in-flight run's breaks and exit.
.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot.
.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Invoke-AutoRemediateOfficeAddins_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated), run as the interactive user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateOfficeAddins\

    1.0.0  Initial: four breaks x six apps against script 1.0.0, assembled from the per-app
           Office harnesses' add-in and Resiliency breaks.

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

$ScriptUnderTest   = 'Invoke-AutoRemediateOfficeAddins'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateOfficeAddins.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\OfficeAddinsErrors'
$C2RConfigPath     = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "DEXTestFramework.psm1 not found at $modulePath" }
Import-Module $modulePath -Force
if (-not (Test-Path -LiteralPath $RemediationScript)) { throw "Script under test not found at $RemediationScript" }

# -- Fixture ------------------------------------------------------------------
$FixturePrefix         = 'DEXTest'
$FixtureAddinName      = 'DEXTest.LabAddin'          # must NOT match the script's $_msAddin matcher
$FixtureResiliencyName = 'DEXTest'                   # value name under Resiliency\DisabledItems
# Same order as the script's $_apps: app index i gives steps 2i-1 (add-in) and 2i (disabled items).
$AppCatalog = @(
    @{ App = 'Word';       Exe = 'WINWORD.EXE' },
    @{ App = 'Excel';      Exe = 'EXCEL.EXE' },
    @{ App = 'PowerPoint'; Exe = 'POWERPNT.EXE' },
    @{ App = 'Access';     Exe = 'MSACCESS.EXE' },
    @{ App = 'OneNote';    Exe = 'ONENOTE.EXE' },
    @{ App = 'Publisher';  Exe = 'MSPUB.EXE' }
)
$AppNames = @($AppCatalog | ForEach-Object { $_.App })
# Same matcher as the script, verbatim, so "third-party" means the same thing here.
$MicrosoftAddinMatcher = '^Microsoft\.|OfficeMicrosoftTeams|Microsoft Online|SharePoint|OneDrive|Skype|Lync|Grammarly\.Microsoft|CopilotAddin|PowerPivot|PowerMap|Inquire|NativeShim'

# -- Helpers: identity and paths ------------------------------------------------

function Get-LoggedOnUser {
    $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not $u) { throw 'No interactive user is logged on; the script resolves its user from Win32_ComputerSystem.UserName.' }
    return $u
}
function Get-LoggedOnUserSid { ([Security.Principal.NTAccount](Get-LoggedOnUser)).Translate([Security.Principal.SecurityIdentifier]).Value }
function Get-C2RConfig { Get-ItemProperty -LiteralPath $C2RConfigPath -ErrorAction SilentlyContinue }
function Get-OfficeVersion {
    $cfg = Get-C2RConfig
    if ($cfg -and $cfg.VersionToReport) { $parts = "$($cfg.VersionToReport)".Split('.'); if ($parts.Count -ge 2) { return "$($parts[0]).$($parts[1])" } }
    return '16.0'
}
function Get-C2RRoot {
    foreach ($p in @("$env:ProgramFiles\Microsoft Office\root\Office16", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16")) {
        if (Test-Path -LiteralPath $p -PathType Container) { return $p }
    }
    return $null
}
function Get-AppExe { param([string]$App) $e = @($AppCatalog | Where-Object { $_.App -eq $App } | ForEach-Object { $_.Exe }); if ($e.Count -eq 0) { throw "Unknown app '$App'" }; return $e[0] }
function Test-AppInstalled {
    param([string]$App)
    $root = Get-C2RRoot
    if (-not $root) { return $false }
    return (Test-Path -LiteralPath (Join-Path $root (Get-AppExe $App)) -PathType Leaf)
}
function Get-InstalledApps { return ,[string[]]@($AppNames | Where-Object { Test-AppInstalled $_ }) }
function Get-AppIndex { param([string]$App) $i = [array]::IndexOf($AppNames, $App); if ($i -lt 0) { throw "Unknown app '$App'" }; return $i + 1 }
function Get-StepPrefix {
    # The DEXRecords value name prefix the script writes for one app's step: Step<NN>_<App>COMAddinConflict / <App>OfficeDisabledItems.
    param([string]$App, [ValidateSet('Addin', 'Disabled')][string]$Kind)
    $i = Get-AppIndex $App
    $order = if ($Kind -eq 'Addin') { 2 * $i - 1 } else { 2 * $i }
    $suffix = if ($Kind -eq 'Addin') { 'COMAddinConflict' } else { 'OfficeDisabledItems' }
    return ('Step{0:D2}_{1}{2}' -f $order, $App, $suffix)
}
function Get-UserHive          { "Registry::HKEY_USERS\$(Get-LoggedOnUserSid)" }
function Get-AppKeyPath        { param([string]$App) "$(Get-UserHive)\Software\Microsoft\Office\$(Get-OfficeVersion)\$App" }   # versioned key: Resiliency
function Get-UserAddinsKeyPath { param([string]$App) "$(Get-UserHive)\Software\Microsoft\Office\$App\Addins" }                  # first key the script enumerates
function Get-FixtureAddinKeyPath { param([string]$App) Join-Path (Get-UserAddinsKeyPath $App) $FixtureAddinName }
function Get-ResiliencyPath    { param([string]$App, [string]$Sub = '') $p = "$(Get-AppKeyPath $App)\Resiliency"; if ($Sub) { "$p\$Sub" } else { $p } }

# -- Helpers: registry ----------------------------------------------------------

function Get-RegValueInfo {
    # @{ Exists; Value; Kind } for one value, Kind as the RegistryValueKind name so Restore writes the same type.
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
    $r = @{ Exists = $false; Value = $null; Kind = 'String' }
    if (-not (Test-Path -LiteralPath $Path)) { return $r }
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $key -or (@($key.GetValueNames()) -notcontains $Name)) { return $r }
    $r.Exists = $true
    $r.Kind   = "$($key.GetValueKind($Name))"
    $r.Value  = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return $r
}
function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'String')
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
}
function Remove-EmptyRegKey {
    # Removes a key only when it has no values and no subkeys, so a key Office has since used is left alone.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($item -and $item.SubKeyCount -eq 0 -and $item.ValueCount -eq 0) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

# -- Helpers: DEXRecords and the run --------------------------------------------

function Get-DexRecordValue {
    # Text the script wrote for one step (value name Step<nn>_<name>), or $null.
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
    param([Parameter(Mandatory = $true)][string]$ValueNamePrefix, [Parameter(Mandatory = $true)][string]$Pattern)
    $text = Get-DexRecordValue -ValueNamePrefix $ValueNamePrefix
    if ($null -eq $text) { Write-Host "           no $ValueNamePrefix value under $DexRecordsPath"; return $false }
    if ($text -notmatch $Pattern) { Write-Host "           $ValueNamePrefix = '$text' did not match '$Pattern'"; return $false }
    return $true
}
function Test-DexRecordFresh {
    # True when LastScanTime under DEXRecords is from this run's remediation call (not a stale key). Host-stream diagnostics only.
    $text = Get-DexRecordValue -ValueNamePrefix 'LastScanTime'
    if ($null -eq $text) { Write-Host "           no LastScanTime under $DexRecordsPath"; return $false }
    $scan = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($text, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$scan)) { Write-Host "           LastScanTime '$text' is not in the script's format"; return $false }
    $start = [datetime]::ParseExact("$($state.RemediationStart)", 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    if ($scan -lt $start.AddSeconds(-1)) { Write-Host "           LastScanTime '$text' predates this run's remediation call ($($state.RemediationStart))"; return $false }
    return $true
}
function Get-RemediationVariables {
    # Every variable the child must see. '' means unset; the three inputs the script reads are always
    # made explicit so a stray value in the harness's own environment cannot leak into the child.
    $vars = @{}
    $runEnv = ConvertTo-DexHashtable -InputObject $state.RunEnv
    if ($runEnv) { foreach ($k in @($runEnv.Keys)) { $vars[$k] = "$($runEnv[$k])" } }
    foreach ($k in @('AllowDestructiveActions', 'ReenableDisabledItems', 'CrashWarnCount7d')) {
        if (-not $vars.ContainsKey($k)) { $vars[$k] = '' }
    }
    return $vars
}
function Invoke-RemediationScript {
    <#
        Runs the script under test once and returns @{ ExitCode; DurationSec; Variables; Output }.
        Writes nothing to the output stream. The child inherits this process's environment, so
        the values are set here and put back afterwards ('' removes the variable). Stderr is
        captured as text: under 'Stop' the first stderr line of a native command redirected
        with 2>&1 would otherwise become a terminating NativeCommandError.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Variables)
    $savedEnv = @{}
    foreach ($k in @($Variables.Keys)) { $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($k in @($Variables.Keys)) {
            $v = if ("$($Variables[$k])" -eq '') { $null } else { "$($Variables[$k])" }
            [Environment]::SetEnvironmentVariable($k, $v, 'Process')
        }
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1 | ForEach-Object { "$_" }
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
        foreach ($k in @($savedEnv.Keys)) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k], 'Process') }
    }
    $sw.Stop()
    return @{ ExitCode = $rc; DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Variables = $Variables; Output = ($output | Out-String).Trim() }
}

# -- Helpers: add-in fixture -----------------------------------------------------

function Get-ActiveThirdPartyAddins {
    # Every add-in the script would count for one app, from the same six keys in the same order, minus our fixture. Plain string array.
    param([string]$App)
    $list = New-Object System.Collections.Generic.List[string]
    $ver = Get-OfficeVersion; $hku = Get-UserHive
    foreach ($s in @("Software\Microsoft\Office\$App\Addins", "Software\Microsoft\Office\$ver\$App\Addins")) {
        foreach ($root in @("$hku\$s", "HKLM:\$s", "HKLM:\SOFTWARE\WOW6432Node\$($s.Substring(9))")) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                if ($k.PSChildName -eq $FixtureAddinName -or $k.PSChildName -match $MicrosoftAddinMatcher) { continue }
                $lb = (Get-ItemProperty -LiteralPath $k.PSPath -Name 'LoadBehavior' -ErrorAction SilentlyContinue).LoadBehavior
                if ($lb -eq 3) { $list.Add("$root\$($k.PSChildName)") }
            }
        }
    }
    return ,[string[]]@($list.ToArray())
}
function Get-AllActiveThirdPartyAddins {
    # Across every app the script covers; an ungated run disables the first one in EACH app.
    $all = @()
    foreach ($a in $AppNames) { $all += (Get-ActiveThirdPartyAddins $a) }
    return ,[string[]]@($all)
}
function Get-FixtureAddinLoadBehavior {
    param([string]$App)
    $key = Get-FixtureAddinKeyPath $App
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    return (Get-ItemProperty -LiteralPath $key -Name 'LoadBehavior' -ErrorAction SilentlyContinue).LoadBehavior
}
function Add-FixtureAddin {
    param([string]$App)
    $key = Get-FixtureAddinKeyPath $App
    New-Item -Path $key -Force -ErrorAction Stop | Out-Null
    Set-ItemProperty -LiteralPath $key -Name 'LoadBehavior' -Value 3 -Type DWord -ErrorAction Stop
    Set-ItemProperty -LiteralPath $key -Name 'FriendlyName' -Value 'DEX Test Lab Add-in' -Type String -ErrorAction Stop
    Set-ItemProperty -LiteralPath $key -Name 'Description'  -Value 'Planted by Invoke-AutoRemediateOfficeAddins_BreakTest.ps1; safe to delete.' -Type String -ErrorAction Stop
}
function Get-FixtureAddinBaseline { param([string]$App) @{ App = $App; AddinsKeyExisted = (Test-Path -LiteralPath (Get-UserAddinsKeyPath $App)) } }
function Test-FixtureAddinPlanted {
    param([string]$App)
    $lb = Get-FixtureAddinLoadBehavior $App
    if ($lb -ne 3) { Write-Host "           $App $FixtureAddinName LoadBehavior is '$lb', expected 3"; return $false }
    return $true
}
function Restore-FixtureAddin {
    param($Original)
    $app = "$($Original.App)"
    $key = Get-FixtureAddinKeyPath $app
    if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
    if (-not [bool]$Original.AddinsKeyExisted) { Remove-EmptyRegKey (Get-UserAddinsKeyPath $app) }
}

# -- Helpers: Resiliency fixture ----------------------------------------------------

function New-ResiliencyBlob {
    # Office's REG_BINARY shape: three DWORD header fields, then two NUL-terminated UTF-16 strings
    # (path, then display name). The script prefers the segment that is not a file path, so the
    # message names DEXTest.LabAddin; both strings carry the DEXTest marker regardless.
    $p = [Text.Encoding]::Unicode.GetBytes("C:\$FixturePrefix\$FixtureAddinName.dll" + [char]0)
    $n = [Text.Encoding]::Unicode.GetBytes($FixtureAddinName + [char]0)
    $hdr = [BitConverter]::GetBytes([int]1) + [BitConverter]::GetBytes([int]$p.Length) + [BitConverter]::GetBytes([int]$n.Length)
    return [byte[]]($hdr + $p + $n)
}
function Get-RealResiliencyValueNames {
    # Value names under one app's DisabledItems and StartupItems that are not ours. Plain string array.
    param([string]$App)
    $names = @()
    foreach ($sub in @('DisabledItems', 'StartupItems')) {
        $k = Get-ResiliencyPath -App $App -Sub $sub
        if (Test-Path -LiteralPath $k) { $names += @((Get-Item -LiteralPath $k).GetValueNames() | Where-Object { $_ -ne $FixtureResiliencyName } | ForEach-Object { "$App\$sub\$_" }) }
    }
    return ,[string[]]@($names)
}
function Get-AllRealResiliencyValueNames {
    $all = @()
    foreach ($a in $AppNames) { $all += (Get-RealResiliencyValueNames $a) }
    return ,[string[]]@($all)
}
function Get-FixtureResiliencyBaseline {
    param([string]$App)
    @{
        App               = $App
        AppKeyExisted     = (Test-Path -LiteralPath (Get-AppKeyPath $App))
        ResiliencyExisted = (Test-Path -LiteralPath (Get-ResiliencyPath -App $App))
        DisabledExisted   = (Test-Path -LiteralPath (Get-ResiliencyPath -App $App -Sub 'DisabledItems'))
        RealEntries       = (Get-RealResiliencyValueNames $App)
    }
}
function Add-FixtureDisabledItem { param([string]$App) Set-RegValue -Path (Get-ResiliencyPath -App $App -Sub 'DisabledItems') -Name $FixtureResiliencyName -Value ([byte[]]@(New-ResiliencyBlob)) -Type Binary }
function Test-FixtureDisabledItemPresent { param([string]$App) (Get-RegValueInfo -Path (Get-ResiliencyPath -App $App -Sub 'DisabledItems') -Name $FixtureResiliencyName).Exists }
function Restore-FixtureDisabledItem {
    param($Original)
    $app = "$($Original.App)"
    $k = Get-ResiliencyPath -App $app -Sub 'DisabledItems'
    if (Test-Path -LiteralPath $k) { Remove-ItemProperty -LiteralPath $k -Name $FixtureResiliencyName -ErrorAction SilentlyContinue }
    if (-not [bool]$Original.DisabledExisted)   { Remove-EmptyRegKey $k }
    if (-not [bool]$Original.ResiliencyExisted) { Remove-EmptyRegKey (Get-ResiliencyPath -App $app) }
    if (-not [bool]$Original.AppKeyExisted)     { Remove-EmptyRegKey (Get-AppKeyPath $app) }
}

# -- Fixture lifecycle ------------------------------------------------------------

function Initialize-Fixture {
    if (-not (Get-C2RConfig) -or -not (Get-C2RRoot)) { throw 'Click-to-Run configuration or root is absent; Invoke-AutoRemediateOfficeAddins.ps1 would exit 0 as Skipped.' }
    $installed = (Get-InstalledApps)
    if ($installed.Count -eq 0) { throw 'None of the six Office apps is installed under the Click-to-Run root; every step would Pass as "not installed".' }
    $user = Get-LoggedOnUser; $sid = Get-LoggedOnUserSid
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) { throw "Hive for $user ($sid) is not loaded under HKEY_USERS; the script's per-user steps would not see it." }
    $perApp = @($installed | ForEach-Object { "$_ (add-ins $((Get-ActiveThirdPartyAddins $_).Count), Resiliency $((Get-RealResiliencyValueNames $_).Count))" })
    Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Office $(Get-OfficeVersion) ($((Get-C2RConfig).VersionToReport)); user $user; installed: $($perApp -join '; ')"
}
function Assert-RunSafe {
    # Refuses a run whose variables would make the script act on real state no break restores.
    param([hashtable]$RunEnv, [string[]]$Names)
    if ($RunEnv['AllowDestructiveActions'] -eq 'true') {
        $real = (Get-AllActiveThirdPartyAddins)
        if ($real.Count -gt 0) { throw "Real active third-party add-in(s) registered ($($real -join '; ')); the add-in step could disable one in an ungated run. Refusing." }
    }
    if ($RunEnv['ReenableDisabledItems'] -eq 'true') {
        $real = (Get-AllRealResiliencyValueNames)
        if ($real.Count -gt 0) { throw "Real Resiliency entries exist ($($real -join ', ')); the disabled-items step would clear them. Refusing." }
    }
}
function Remove-Fixture {
    # Sweep by prefix across all six apps; per-break Restore normally did all of this. Catches what a half-finished run left behind.
    foreach ($a in $AppNames) {
        try { $k = Get-FixtureAddinKeyPath $a; if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
        try { $k = Get-ResiliencyPath -App $a -Sub 'DisabledItems'; if (Test-Path -LiteralPath $k) { Remove-ItemProperty -LiteralPath $k -Name $FixtureResiliencyName -ErrorAction SilentlyContinue } } catch { }
    }
}

# -- Break definitions ---------------------------------------------------------
# Env: variables the child must see ('' = must be unset). Excludes: break-name patterns that
# cannot share a run with this one. Methods: the apps; the drawn one is passed to Capture, whose
# result (with .App) reaches Verify, Validate and Restore. Verify proves the break landed.
# Validate decides whether remediation did its job.
$GatedSuffix = ' -- set \$AllowDestructiveActions=\$true to apply\.'

function New-AppMethods {
    # One method per app; Apply receives the app name as its argument.
    param([scriptblock]$Apply)
    return ,[object[]]@($AppNames | ForEach-Object { @{ Name = $_; Apply = $Apply } })
}

$BreakCatalog = @(

    @{
        Name = 'ThirdPartyAddinConflictGated'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false
        Env = @{ AllowDestructiveActions = '' }; Excludes = @()
        Methods  = New-AppMethods -Apply { param($App) Add-FixtureAddin $App }
        Capture  = { param($App) Get-FixtureAddinBaseline $App }
        Verify   = { param($Original) Test-FixtureAddinPlanted "$($Original.App)" }
        # Add-in step: "<n> active third-party add-in(s): DEXTest.LabAddin [user]. Disabling the first one is the remediation -- set ..."
        Validate = {
            param($Original)
            $app = "$($Original.App)"
            $lb = Get-FixtureAddinLoadBehavior $app
            if ($lb -ne 3) { Write-Host "           $app $FixtureAddinName LoadBehavior is '$lb' after a gated run; expected 3" }
            $fresh    = Test-DexRecordFresh
            $reported = Test-DexRecordMatches -ValueNamePrefix (Get-StepPrefix -App $app -Kind 'Addin') -Pattern "^\[Warning\] \d+ active third-party add-in\(s\): .*$([regex]::Escape($FixtureAddinName)) \[user\].*Disabling the first one is the remediation$GatedSuffix$"
            ($lb -eq 3) -and $fresh -and $reported
        }
        Restore  = { param($Original) Restore-FixtureAddin -Original $Original }
    },

    @{
        Name = 'ThirdPartyAddinConflict'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false
        Env = @{ AllowDestructiveActions = 'true' }; Excludes = @()
        Methods  = New-AppMethods -Apply {
            param($App)
            # The script disables the FIRST active third-party add-in it finds per app; with no real one the fixture is the only candidate.
            $real = (Get-ActiveThirdPartyAddins $App)
            if ($real.Count -gt 0) { throw "A real active third-party $App add-in is registered ($($real -join '; ')); the ungated run could disable it instead of the fixture. Run ThirdPartyAddinConflictGated instead." }
            Add-FixtureAddin $App
        }
        Capture  = { param($App) Get-FixtureAddinBaseline $App }
        Verify   = { param($Original) Test-FixtureAddinPlanted "$($Original.App)" }
        # Resolution: "Add-in 'DEXTest.LabAddin' [user] set to LoadBehavior=0. Restart <App> to take effect."
        Validate = {
            param($Original)
            $app = "$($Original.App)"
            $lb = Get-FixtureAddinLoadBehavior $app
            if ($lb -ne 0) { Write-Host "           $app $FixtureAddinName LoadBehavior is '$lb'; expected 0" }
            $fresh    = Test-DexRecordFresh
            $reported = Test-DexRecordMatches -ValueNamePrefix (Get-StepPrefix -App $app -Kind 'Addin') -Pattern "^\[Remediated\] Add-in '$([regex]::Escape($FixtureAddinName))' \[user\] set to LoadBehavior=0\. Restart $app to take effect\.$"
            ($lb -eq 0) -and $fresh -and $reported
        }
        Restore  = { param($Original) Restore-FixtureAddin -Original $Original }
    },

    @{
        Name = 'DisabledItemGated'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false
        Env = @{ ReenableDisabledItems = '' }; Excludes = @()
        Methods  = New-AppMethods -Apply { param($App) Add-FixtureDisabledItem $App }
        Capture  = { param($App) Get-FixtureResiliencyBaseline $App }
        Verify   = { param($Original) $ok = Test-FixtureDisabledItemPresent "$($Original.App)"; if (-not $ok) { Write-Host '           fixture Resiliency value missing' }; $ok }
        # Disabled-items step: "<n> disabled item(s), <n> disabled startup item(s): DEXTest... Set $ReenableDisabledItems=$true to clear them; ..."
        Validate = {
            param($Original)
            $app = "$($Original.App)"
            $still = Test-FixtureDisabledItemPresent $app
            if (-not $still) { Write-Host '           fixture Resiliency value was cleared during a gated run' }
            $fresh    = Test-DexRecordFresh
            $reported = Test-DexRecordMatches -ValueNamePrefix (Get-StepPrefix -App $app -Kind 'Disabled') -Pattern "^\[Warning\] \d+ disabled item\(s\), \d+ disabled startup item\(s\): .*$FixturePrefix.*\. Set \`$ReenableDisabledItems=\`$true to clear them; Office disabled these after a failure, so confirm first\.$"
            $still -and $fresh -and $reported
        }
        Restore  = { param($Original) Restore-FixtureDisabledItem -Original $Original }
    },

    @{
        Name = 'DisabledItem'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false
        Env = @{ ReenableDisabledItems = 'true' }; Excludes = @()
        Methods  = New-AppMethods -Apply {
            param($App)
            $real = (Get-RealResiliencyValueNames $App)
            if ($real.Count -gt 0) { throw "Real $App Resiliency entries exist ($($real -join ', ')); the script clears every entry, so an ungated run would re-enable items Office disabled. Run DisabledItemGated instead." }
            Add-FixtureDisabledItem $App
        }
        Capture  = { param($App) Get-FixtureResiliencyBaseline $App }
        Verify   = { param($Original) $ok = Test-FixtureDisabledItemPresent "$($Original.App)"; if (-not $ok) { Write-Host '           fixture Resiliency value missing' }; $ok }
        # Resolution: "Cleared 1 Resiliency entry; items load at <App>'s next start."
        Validate = {
            param($Original)
            $app = "$($Original.App)"
            $gone = -not (Test-FixtureDisabledItemPresent $app)
            if (-not $gone) { Write-Host '           fixture Resiliency value still present' }
            $fresh    = Test-DexRecordFresh
            $reported = Test-DexRecordMatches -ValueNamePrefix (Get-StepPrefix -App $app -Kind 'Disabled') -Pattern "^\[Remediated\] Cleared 1 Resiliency entry; items load at $app's next start\.$"
            $gone -and $fresh -and $reported
        }
        Restore  = { param($Original) Restore-FixtureDisabledItem -Original $Original }
    }
)

function Get-BreakDefinition { param([Parameter(Mandatory = $true)][string]$Name) $BreakCatalog | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }
function Test-BreakConflict {
    param($A, $B)
    foreach ($p in @($A.Excludes)) { if ($B.Name -like $p) { return $true } }
    foreach ($p in @($B.Excludes)) { if ($A.Name -like $p) { return $true } }
    return $false
}
function Request-TestReboot {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    Save-DexTestState -State $State
    Register-DexTestResume -State $State -BreakTestPath $SelfPath
    Write-DexStep -Status 'Info' -Name 'Reboot' -Message 'Rebooting to apply pending state; run resumes automatically.'
    & shutdown.exe /r /t 15 /f | Out-Null
}

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList

Write-DexBanner -Title 'Invoke-AutoRemediateOfficeAddins_BreakTest' -Detail "Environment: $Environment"

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
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
        }
    }
    Remove-Fixture
    Unregister-DexTestResume -State $state
    $state.Phase = 'Restored'; $state.Overall = 'Restored'
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
        $installedApps = (Get-InstalledApps)

        $candidates = if ($BreakName) {
            @($BreakCatalog | Where-Object { $BreakName -contains $_.Name })
        } else {
            @($BreakCatalog | Where-Object { $IncludeRebootBreaks -or -not $_.RequiresReboot })
        }
        if ($candidates.Count -eq 0) { throw 'No break definitions matched the requested selection.' }

        $selected = if ($BreakName) { $candidates } else { Get-DexRandomSubset -InputObject ([object[]]$candidates.Clone()) -Random $state.Random -Count $BreakCount }
        # Fresh copies go to Get-DexRandomSubset: it shuffles the array it is handed in place.
        # Re-wrap in a second statement: the if-expression unrolls a one-element array.
        $selected = @($selected)

        # One environment per child process: a break whose Env conflicts with what earlier draws
        # fixed, or which an earlier draw excludes, is dropped. The first drawn decides.
        $kept = @(); $runEnv = @{}
        foreach ($def in $selected) {
            $why = $null
            foreach ($k in @($def.Env.Keys)) {
                if ($runEnv.ContainsKey($k) -and $runEnv[$k] -ne "$($def.Env[$k])") { $why = "needs $k='$($def.Env[$k])' but the run already has '$($runEnv[$k])'" }
            }
            if (-not $why) { foreach ($k in $kept) { if (Test-BreakConflict -A $k -B $def) { $why = "cannot share a run with $($k.Name)" } } }
            if ($why) { Write-DexStep -Status 'Info' -Name 'Selection' -Message "dropped $($def.Name): $why"; continue }
            foreach ($k in @($def.Env.Keys)) { $runEnv[$k] = "$($def.Env[$k])" }
            $kept += $def
        }
        $selected = @($kept)
        if ($selected.Count -eq 0) { throw 'Every selected break was dropped by the environment conflict rules.' }
        $state.RunEnv = $runEnv

        Assert-RunSafe -RunEnv $runEnv -Names @($selected | ForEach-Object { $_.Name })

        $applied = @()
        foreach ($def in $selected) {
            # Only apps installed here can be drawn; the script Passes a missing app as "not installed".
            $methods  = @($def.Methods | Where-Object { $installedApps -contains $_.Name })
            if ($methods.Count -eq 0) { throw "No installed app available for $($def.Name)." }
            $method   = (Get-DexRandomSubset -InputObject ([object[]]$methods.Clone()) -Random $state.Random -Count 1)[0]
            $original = & $def.Capture $method.Name
            & $method.Apply $method.Name
            if ($def.RequiresReboot) { $state.RequiresReboot = $true }
            $applied += @{
                Name = $def.Name; Method = $method.Name; ExpectedOutcome = $def.ExpectedOutcome
                RequiresReboot = [bool]$def.RequiresReboot; Applied = $true; BreakVerified = $false; OriginalState = $original
            }
            Write-DexStep -Status 'Info' -Name "Break $($def.Name)" -Message "method '$($method.Name)' applied (validates $(Get-StepPrefix -App $method.Name -Kind $(if ($def.Name -like 'ThirdPartyAddin*') { 'Addin' } else { 'Disabled' })))"
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
            $ok  = [bool](& $def.Verify ([PSCustomObject]$b.OriginalState))
            $b.BreakVerified = $ok
            if ($ok) {
                Write-DexStep -Status 'Passed' -Name "Verify $($b.Name)" -Message "component is genuinely broken ($($b.Method))"
            } else {
                $allVerified = $false
                Write-DexStep -Status 'Failed' -Name "Verify $($b.Name)" -Message 'break did not land; remediation would be a false green'
            }
        }
        if (-not $allVerified) {
            $state.Phase = 'BreakFailed'; $state.Overall = 'BreakFailed'
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
            $shown = @($vars.Keys | Sort-Object | Where-Object { "$($vars[$_])" -ne '' } | ForEach-Object { "$_='$($vars[$_])'" })
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "invoking $([System.IO.Path]::GetFileName($RemediationScript)) with $(if ($shown.Count) { $shown -join ' ' } else { 'no variables set' })"
            # Validate requires the script's LastScanTime to be at or after this stamp (whole seconds, the script's own format).
            $state.RemediationStart = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
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
                Name = $b.Name; Method = $b.Method; Expected = $expected
                Actual = $(if ($passed) { 'as expected' } else { 'NOT as expected' })
                Result = $(if ($passed) { 'Pass' } else { 'Fail' })
            }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) -Name "Validate $($b.Name)" -Message "$expected ($($b.Method))"
        }
        $state.Validation = $validation
        $state.Phase      = 'Validated'
        $failedCount = @($validation | Where-Object { $_.Result -eq 'Fail' }).Count
        $state.Overall = if ($failedCount -eq 0) { 'Passed' }
                         elseif ($state.Remediation -and [int]$state.Remediation.ExitCode -eq 0) { 'FalsePass' }   # script claimed success, component still broken
                         else { 'Failed' }
        Save-DexTestState -State $state
    }

} catch {
    Write-DexStep -Status 'Failed' -Name 'Harness' -Message $_.Exception.Message
    $state.HarnessError = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    if ($state.Overall -eq 'Incomplete') { $state.Overall = 'Failed' }
    $exitCode = 1
}

# -- Restore -------------------------------------------------------------------
if ($Environment -eq 'Physical') {
    $restoreFailed = $false
    # Newest first: the oldest Capture is the true baseline and must win.
    $toRestore = @($state.Breaks); [array]::Reverse($toRestore)
    foreach ($b in $toRestore) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
        } catch {
            $restoreFailed = $true
            $msg = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $msg
            $state.HarnessError = if ($state.HarnessError) { "$($state.HarnessError); restore $($b.Name): $msg" } else { "restore $($b.Name): $msg" }
        }
    }
    try { Remove-Fixture } catch { $restoreFailed = $true; $state.HarnessError = "$($state.HarnessError); sweep: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" }
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
