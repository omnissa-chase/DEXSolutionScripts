<#
.SYNOPSIS
    Invoke-AutoRemediateWord_BreakTest -- deliberately plants Word faults, then verifies
    Invoke-AutoRemediateWord.ps1 reports or repairs them as documented.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform JSON
    result to C:\Temp\FixReport\Invoke-AutoRemediateWord\ for Invoke-FixReportAnalysis.ps1.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It writes an AutoRecover path into the
    logged-on user's Office hive, replaces the user's
    Normal.dotm with an oversized fixture (the original is backed up and put back), bloats
    or creates the Office Document Cache folder, drops a file into the user's Word STARTUP
    folder, and can let the script rename the user's Word Data key. Run it only on a marked
    test host (Assert-DexTestHost in DEXTestFramework.psm1).

    HOW THE SCRIPT SEES THE USER
    Invoke-AutoRemediateWord.ps1 resolves the logged-on user from
    Win32_ComputerSystem.UserName and reads HKEY_USERS\<SID>, so the harness does the same.
    Run elevated as the interactive user; the child powershell.exe runs in this same
    context, as Workspace ONE Hub would, with the script's inputs passed as environment
    variables (AllowDestructiveActions, CacheSizeWarningMB, CrashWarnCount7d,
    TemplateWarnMB). Every planted artefact carries the DEXTest prefix; every break
    Captures what it changes and Restore writes it back.

    ONE ENVIRONMENT PER RUN
    Each break declares the variables the child must see (Env); '' means "must be unset".
    The flag is one value for the whole child process, so a gated break (flag unset,
    ExpectReportedOnly) and its ungated twin (flag 'true', ExpectFixed) cannot share a run:
    the first drawn decides and conflicting draws are dropped. Breaks whose detection would
    be masked by another break's blame (step 9 needs nothing blamed by step 2 -- third-party
    crash module or Resiliency entries -- or by step 6) carry an Excludes list and are kept
    exclusive the same way. An ungated run is refused when real state would be acted on: a
    real Normal.dotm at or over TemplateWarnMB, a real Document Cache at or over the
    threshold, or three or more real WINWORD crash events.

    EXPECTED OUTCOMES (derived from the script's own messages, 1.0.3)
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    Step 5  AutoRecoverPathMissing        Fixed (no gate). Options\AUTOSAVE-PATH points at a
                                          missing DEXTest_AutoRecover_Word folder; the script
                                          creates it. A Word launched between break and Restore
                                          uses that folder for the session.
    Step 6  NormalDotmOversizedGated      ReportedOnly. Normal.dotm is backed up to the result
                                          folder and replaced by a 9 MB zero-filled fixture
                                          (TemplateWarnMB default 8). Word must be closed (it
                                          holds the template open); a Word launched in the
                                          window would see a corrupt template until Restore.
            NormalDotmOversized           Fixed (AllowDestructiveActions, Word closed). Fixture
                                          renamed to Normal_<stamp>.dotm.bak; Restore deletes the
                                          new .bak and puts the user's Normal.dotm back.
    Step 7  DocumentCacheBloatGated       ReportedOnly. 64 MB DEXTest_bloat file inside
                                          OfficeFileCache (folder created if absent);
                                          CacheSizeWarningMB handed as real size + 16.
            DocumentCacheBloat            Fixed (AllowDestructiveActions, NO Office app open --
                                          Outlook counts). Whole folder renamed to
                                          OfficeFileCache_<stamp>.bak; Restore removes the fixture
                                          and renames the folder back (or deletes it when the
                                          harness created it).
    Step 9  WordDataKeyResetGated         ReportedOnly. Nothing is planted: the script's
                                          CrashWarnCount7d input is handed 0 so the step is
                                          indicated with the host's real (zero) crash count; the
                                          Data key must exist and nothing else may be blamed.
            WordDataKeyReset              Fixed (AllowDestructiveActions, Word closed). The user's
                                          REAL Data key is renamed Data_<stamp>; Restore renames it
                                          back (removing a Data key Word rebuilt meanwhile).
    Step 10 StartupFolderContent          ReportedOnly (the step has no fix). DEXTest_lab.txt in
                                          the user's Word STARTUP folder.

    NOT COVERED
      Step 2  Crash and Hang History -- the only trigger is a real WINWORD 1000/1002 event;
              the harness never writes to the Application log.
      Steps 3 and 4 (COM Add-in Conflict, Office-Disabled Items) -- moved to
              ApplicationSpecific\Microsoft\Office\Invoke-AutoRemediateOfficeAddins.ps1; its
              own harness carries the four add-in breaks that used to live here.
      Step 2  blame branches ('add-in' from a third-party crash module, 'disabled-items' from
              real Resiliency entries) -- need a crash event or an entry Office itself wrote.
      Step 6  wwlib.dll suspect branch -- needs three real wwlib.dll crashes.
      Step 7  corrupt-cache branch (CentralTable.accdb missing with content present) -- would
              require deleting the user's real CentralTable.accdb.
      Step 8  Office C2R Update Health -- UpdatesEnabled is False by policy on this host and the
              step already Warns; the harness does not flip policy-managed values. Validate
              blocks tolerate that pre-existing Warning.
      "App is open" skip branches of steps 6, 7 and 9 -- the harness refuses to start those
              ungated breaks with the app open rather than test the skip.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateWord.ps1 and validate. Without it: break and report.
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
    Script Name  : Invoke-AutoRemediateWord_BreakTest.ps1
    Version      : 1.0.1
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated), run as the interactive user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateWord\

    1.0.1  ThirdPartyAddinConflictGated, ThirdPartyAddinConflict, DisabledItemGated and
           DisabledItem moved to the Invoke-AutoRemediateOfficeAddins.ps1 harness with the
           script's steps 3 and 4; ReenableDisabledItems is no longer passed to the child.
           Eight breaks remain. Tracks script 1.0.3.
    1.0.0  Initial: twelve breaks against script 1.0.1 (steps 3, 4, 5, 6, 7, 9, 10).

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

$ScriptUnderTest   = 'Invoke-AutoRemediateWord'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateWord.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\WordErrors'
$C2RConfigPath     = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "DEXTestFramework.psm1 not found at $modulePath" }
Import-Module $modulePath -Force
if (-not (Test-Path -LiteralPath $RemediationScript)) { throw "Script under test not found at $RemediationScript" }

# -- Fixture ------------------------------------------------------------------
$FixtureAutoRecoverDir = 'DEXTest_AutoRecover_Word'  # under AppData\Local\Microsoft\Office
$FixtureTemplateMB     = 9                           # Normal.dotm fixture; script default TemplateWarnMB is 8
$TemplateWarnMB        = 8
$FixtureCacheDirName   = 'DEXTest_bloat'             # subfolder inside OfficeFileCache
$FixtureCacheMB        = 64
$FixtureCacheMarginMB  = 16                          # threshold = real cache MB + this; must stay under FixtureCacheMB
$FixtureStartupFile    = 'DEXTest_lab.txt'
$CrashWarnDefault      = 3
$OfficeProcs           = @('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'ONENOTE', 'MSACCESS', 'MSPUB', 'MSOSYNC', 'msouc')

# -- Helpers: identity and paths ------------------------------------------------

function Get-LoggedOnUser {
    $u = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not $u) { throw 'No interactive user is logged on; the script resolves its user from Win32_ComputerSystem.UserName.' }
    return $u
}
function Get-LoggedOnUserSid { ([Security.Principal.NTAccount](Get-LoggedOnUser)).Translate([Security.Principal.SecurityIdentifier]).Value }
function Get-UserProfilePath {
    $p = "C:\Users\$((Get-LoggedOnUser).Split('\')[-1])"
    if (-not (Test-Path -LiteralPath $p)) { throw "Profile folder '$p' for the logged-on user not found." }
    return $p
}
function Get-C2RConfig { Get-ItemProperty -LiteralPath $C2RConfigPath -ErrorAction SilentlyContinue }
function Get-OfficeVersion {
    $cfg = Get-C2RConfig
    if ($cfg -and $cfg.VersionToReport) { $parts = "$($cfg.VersionToReport)".Split('.'); if ($parts.Count -ge 2) { return "$($parts[0]).$($parts[1])" } }
    return '16.0'
}
function Get-C2RRoot {
    foreach ($p in @("$env:ProgramFiles\Microsoft Office\root\Office16", "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16")) {
        if (Test-Path -LiteralPath (Join-Path $p 'WINWORD.EXE')) { return $p }
    }
    return $null
}
function Get-UserHive          { "Registry::HKEY_USERS\$(Get-LoggedOnUserSid)" }
function Get-AppKeyPath        { "$(Get-UserHive)\Software\Microsoft\Office\$(Get-OfficeVersion)\Word" }   # versioned key: Options, Resiliency, Data
function Get-OptionsPath       { "$(Get-AppKeyPath)\Options" }
function Get-ResiliencyPath    { param([string]$Sub = '') $p = "$(Get-AppKeyPath)\Resiliency"; if ($Sub) { "$p\$Sub" } else { $p } }
function Get-DataKeyPath       { "$(Get-AppKeyPath)\Data" }
function Get-TemplatesPath     { Join-Path (Get-UserProfilePath) 'AppData\Roaming\Microsoft\Templates' }
function Get-NormalPath        { Join-Path (Get-TemplatesPath) 'Normal.dotm' }
function Get-CachePath         { Join-Path (Get-UserProfilePath) "AppData\Local\Microsoft\Office\$(Get-OfficeVersion)\OfficeFileCache" }
function Get-CacheFixtureDir   { Join-Path (Get-CachePath) $FixtureCacheDirName }
function Get-StartupPath       { Join-Path (Get-UserProfilePath) 'AppData\Roaming\Microsoft\Word\STARTUP' }
function Get-AutoRecoverFixturePath { Join-Path (Get-UserProfilePath) "AppData\Local\Microsoft\Office\$FixtureAutoRecoverDir" }
function Get-TemplateBackupPath { Join-Path $state.ScriptDir "DEXTest_Normal.dotm.$($state.TestId).bak" }

# -- Helpers: registry, files, processes ------------------------------------------

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
function Set-RegValueInfo {
    # Puts a value back exactly as Get-RegValueInfo saw it; Exists=false removes it. Info may be a PSCustomObject after a JSON round-trip.
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name, $Info)
    if (-not $Info -or -not [bool]$Info.Exists) {
        if (Test-Path -LiteralPath $Path) { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue }
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    $kind = "$($Info.Kind)"
    if ($kind -notin @('String', 'ExpandString', 'Binary', 'DWord', 'QWord', 'MultiString')) { $kind = 'String' }
    $v = switch ($kind) {
        'Binary'      { [byte[]]@($Info.Value | ForEach-Object { [byte]$_ }) }
        'DWord'       { [int]$Info.Value }
        'QWord'       { [long]$Info.Value }
        'MultiString' { [string[]]@($Info.Value) }
        default       { "$($Info.Value)" }
    }
    Set-ItemProperty -LiteralPath $Path -Name $Name -Value $v -Type $kind -ErrorAction Stop
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
function Test-ProcessRunning { param([string[]]$Name) [bool](Get-Process -Name $Name -ErrorAction SilentlyContinue) }
function Get-AppCrashEvents {
    # WINWORD.EXE 1000/1002 records in the last 7 days, counted the way step 2 counts them. Plain array.
    $ev = @()
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = @('Application Error', 'Application Hang'); Id = @(1000, 1002); StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue |
               Where-Object { $_.Properties.Count -gt 0 -and "$($_.Properties[0].Value)" -ieq 'WINWORD.EXE' })
    } catch { }
    return $ev
}
function New-ZeroFile {
    param([string]$Path, [int]$SizeMB)
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
    & fsutil.exe file createnew $Path ([int64]$SizeMB * 1MB) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "fsutil file createnew failed with exit code $LASTEXITCODE for $Path" }
    if (-not (Test-Path -LiteralPath $Path)) { throw "fsutil reported success but $Path does not exist" }
}
function Get-DirMB {
    # Same arithmetic as the script's _DirMB.
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    return [math]::Round(($(if ($sum) { $sum } else { 0 })) / 1MB, 1)
}
function Test-DirEmpty { param([string]$Dir) (@(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue).Count -eq 0) }
function Get-MissingDirectories {
    # Parent-first list of the directories that do not exist yet; Restore removes exactly these. Plain array.
    param([string[]]$Paths)
    $missing = @()
    foreach ($p in $Paths) { if (-not (Test-Path -LiteralPath $p -PathType Container)) { $missing += $p } }
    return @($missing)
}
function Remove-MissingDirectories {
    # Deepest first; only an empty directory is removed.
    param($Paths)
    $list = @($Paths | Where-Object { $_ })
    [array]::Reverse($list)
    foreach ($p in $list) {
        if ((Test-Path -LiteralPath "$p" -PathType Container) -and (Test-DirEmpty "$p")) { Remove-Item -LiteralPath "$p" -Force -ErrorAction SilentlyContinue }
    }
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
function Test-DexRecordAbsent {
    # True when the step wrote nothing (it Passed). Host-stream diagnostics only.
    param([Parameter(Mandatory = $true)][string]$ValueNamePrefix)
    $text = Get-DexRecordValue -ValueNamePrefix $ValueNamePrefix
    if ($null -ne $text) { Write-Host "           $ValueNamePrefix unexpectedly present: '$text'"; return $false }
    return $true
}
function Get-RemediationVariables {
    # Every variable the child must see. '' means unset; the four inputs the script reads are always
    # made explicit so a stray value in the harness's own environment cannot leak into the child.
    $vars = @{}
    $runEnv = ConvertTo-DexHashtable -InputObject $state.RunEnv
    if ($runEnv) {
        foreach ($k in @($runEnv.Keys)) {
            $v = "$($runEnv[$k])"
            if ($v -eq '{CacheThresholdMB}') { $v = "$([int]$state.CacheThresholdMB)" }
            $vars[$k] = $v
        }
    }
    foreach ($k in @('AllowDestructiveActions', 'CacheSizeWarningMB', 'CrashWarnCount7d', 'TemplateWarnMB')) {
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

# -- Helpers: Resiliency entries (step 2 blame) ------------------------------------

function Get-RealResiliencyValueNames {
    # Value names under DisabledItems and StartupItems. Step 2 blames 'disabled-items' when any
    # exist, which keeps step 9 from being indicated. Plain array.
    $names = @()
    foreach ($sub in @('DisabledItems', 'StartupItems')) {
        $k = Get-ResiliencyPath $sub
        if (Test-Path -LiteralPath $k) { $names += @((Get-Item -LiteralPath $k).GetValueNames() | ForEach-Object { "$sub\$_" }) }
    }
    return @($names)
}

# -- Helpers: step 6 Normal.dotm ----------------------------------------------------

function Get-NormalBakNames {
    $dir = Get-TemplatesPath
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter 'Normal_*.dotm.bak' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}
function Get-NewNormalBaks { param($Original) @(Get-NormalBakNames | Where-Object { @($Original.ExistingBaks) -notcontains $_ }) }
function Get-TemplateBaseline {
    $tpl = Get-NormalPath
    @{
        TemplatesDirExisted = (Test-Path -LiteralPath (Get-TemplatesPath))
        NormalExisted       = (Test-Path -LiteralPath $tpl)
        NormalLength        = $(if (Test-Path -LiteralPath $tpl) { (Get-Item -LiteralPath $tpl).Length } else { 0 })
        BackupPath          = Get-TemplateBackupPath
        ExistingBaks        = @(Get-NormalBakNames)
        WordRunning         = (Test-ProcessRunning 'WINWORD')
    }
}
function Install-FixtureNormal {
    # Backs the user's Normal.dotm up to the result folder, then puts a 9 MB zero-filled file in its place.
    if (Test-ProcessRunning 'WINWORD') { throw 'WINWORD.EXE is running and holds Normal.dotm open; close Word and re-run this break.' }
    $tpl = Get-NormalPath; $bak = Get-TemplateBackupPath
    if (Test-Path -LiteralPath $tpl) {
        Copy-Item -LiteralPath $tpl -Destination $bak -Force -ErrorAction Stop
        if ((Get-Item -LiteralPath $bak).Length -ne (Get-Item -LiteralPath $tpl).Length) { throw "Backup of Normal.dotm at $bak does not match the original; refusing to replace it." }
        Remove-Item -LiteralPath $tpl -Force -ErrorAction Stop
    }
    New-ZeroFile -Path $tpl -SizeMB $FixtureTemplateMB
}
function Test-FixtureNormalPlanted {
    param($Original)
    $tpl = Get-NormalPath
    if (-not (Test-Path -LiteralPath $tpl)) { Write-Host "           $tpl missing"; return $false }
    $len = (Get-Item -LiteralPath $tpl).Length
    if ($len -ne ($FixtureTemplateMB * 1MB)) { Write-Host "           Normal.dotm is $len bytes, not the ${FixtureTemplateMB}MB fixture"; return $false }
    if ([bool]$Original.NormalExisted -and -not (Test-Path -LiteralPath "$($Original.BackupPath)")) { Write-Host "           backup $($Original.BackupPath) missing"; return $false }
    return $true
}
function Restore-TemplateBaseline {
    param($Original)
    $tpl = Get-NormalPath
    foreach ($n in @(Get-NewNormalBaks -Original $Original)) { Remove-Item -LiteralPath (Join-Path (Get-TemplatesPath) $n) -Force -ErrorAction SilentlyContinue }
    if ((Test-Path -LiteralPath $tpl) -and ((Get-Item -LiteralPath $tpl).Length -eq ($FixtureTemplateMB * 1MB))) { Remove-Item -LiteralPath $tpl -Force -ErrorAction Stop }
    $bak = "$($Original.BackupPath)"
    if ($bak -and (Test-Path -LiteralPath $bak)) {
        if (Test-Path -LiteralPath $tpl) {
            # Word rebuilt a Normal.dotm in the window; the user's original wins.
            if (Test-ProcessRunning 'WINWORD') { throw "Word is running with a rebuilt Normal.dotm; the user's original is at $bak -- close Word and copy it back by hand." }
            Remove-Item -LiteralPath $tpl -Force -ErrorAction Stop
        }
        Move-Item -LiteralPath $bak -Destination $tpl -Force -ErrorAction Stop
    }
    if (-not [bool]$Original.TemplatesDirExisted) { Remove-MissingDirectories -Paths @(Get-TemplatesPath) }
}

# -- Helpers: step 7 Office Document Cache -----------------------------------------

function Get-CacheBakDirs {
    $parent = Split-Path -Path (Get-CachePath) -Parent
    if (-not (Test-Path -LiteralPath $parent)) { return @() }
    return @(Get-ChildItem -LiteralPath $parent -Directory -Filter 'OfficeFileCache_*.bak' -ErrorAction SilentlyContinue)
}
function Get-NewCacheBakDirs { param($Original) @(Get-CacheBakDirs | Where-Object { @($Original.ExistingBaks) -notcontains $_.Name }) }
function Test-CacheCorrupt {
    # The script's corrupt test: top-level files present but CentralTable.accdb missing or empty.
    $dir = Get-CachePath
    if (-not (Test-Path -LiteralPath $dir)) { return $false }
    $files = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)
    $table = Get-Item -LiteralPath (Join-Path $dir 'CentralTable.accdb') -ErrorAction SilentlyContinue
    return ($files.Count -gt 0 -and (-not $table -or $table.Length -eq 0))
}
function Get-CacheBaseline {
    $dir = Get-CachePath
    @{
        MissingDirs   = @(Get-MissingDirectories -Paths @((Split-Path -Path $dir -Parent), $dir))
        FolderExisted = (Test-Path -LiteralPath $dir)
        RealMB        = (Get-DirMB $dir)
        ExistingBaks  = @(Get-CacheBakDirs | ForEach-Object { $_.Name })
        ThresholdMB   = [int]$state.CacheThresholdMB
    }
}
function Install-CacheFixture {
    if (Test-CacheCorrupt) { throw 'The real Office Document Cache already trips the corrupt-cache branch (CentralTable.accdb missing or empty); the size message under test would not be produced.' }
    New-ZeroFile -Path (Join-Path (Get-CacheFixtureDir) 'DEXTest_bloat.bin') -SizeMB $FixtureCacheMB
}
function Test-CacheFixturePlanted {
    $f = Join-Path (Get-CacheFixtureDir) 'DEXTest_bloat.bin'
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "           $f missing"; return $false }
    $mb = Get-DirMB (Get-CachePath); $t = [int]$state.CacheThresholdMB
    if ($mb -lt $t) { Write-Host "           cache is ${mb}MB, below the ${t}MB threshold handed to the script"; return $false }
    if (Test-CacheCorrupt) { Write-Host '           cache reads as corrupt; the size branch would not fire'; return $false }
    return $true
}
function Restore-CacheBaseline {
    param($Original)
    $dir = Get-CachePath
    $fx = Get-CacheFixtureDir
    if (Test-Path -LiteralPath $fx) { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction Stop }
    foreach ($bak in @(Get-NewCacheBakDirs -Original $Original)) {
        $bakFx = Join-Path $bak.FullName $FixtureCacheDirName
        if (Test-Path -LiteralPath $bakFx) { Remove-Item -LiteralPath $bakFx -Recurse -Force -ErrorAction Stop }
        if ([bool]$Original.FolderExisted) {
            if (Test-Path -LiteralPath $dir) {
                if (Test-DirEmpty $dir) { Remove-Item -LiteralPath $dir -Force -ErrorAction Stop }
                else { throw "Office recreated $dir after the rename; the user's original cache is at $($bak.FullName) -- merge by hand." }
            }
            Rename-Item -LiteralPath $bak.FullName -NewName 'OfficeFileCache' -ErrorAction Stop
        } elseif (Test-DirEmpty $bak.FullName) {
            Remove-Item -LiteralPath $bak.FullName -Force -ErrorAction Stop
        } else {
            throw "$($bak.FullName) holds content the harness did not plant; left in place."
        }
    }
    if (-not [bool]$Original.FolderExisted -and (Test-Path -LiteralPath $dir) -and (Test-DirEmpty $dir)) { Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue }
    Remove-MissingDirectories -Paths @($Original.MissingDirs)
}

# -- Helpers: step 9 Word Data key ---------------------------------------------------

function Get-DataBakNames {
    $app = Get-AppKeyPath
    if (-not (Test-Path -LiteralPath $app)) { return @() }
    return @(Get-ChildItem -LiteralPath $app -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Data_*' } | ForEach-Object { $_.PSChildName })
}
function Get-NewDataBaks { param($Original) @(Get-DataBakNames | Where-Object { @($Original.ExistingBaks) -notcontains $_ }) }
function Get-DataKeyBaseline { @{ DataExisted = (Test-Path -LiteralPath (Get-DataKeyPath)); ExistingBaks = @(Get-DataBakNames) } }
function Assert-DataKeyIndicated {
    # Step 9 fires only with the Data key present and nothing blamed by step 2 (third-party crash module, Resiliency entries) or 6.
    if (-not (Test-Path -LiteralPath (Get-DataKeyPath))) { throw "Word Data key $(Get-DataKeyPath) is absent; launch and close Word once so the step has something to reset." }
    $real = @(Get-RealResiliencyValueNames)
    if ($real.Count -gt 0) { throw 'Resiliency entries exist; step 2 would blame them and step 9 would not be indicated.' }
    $tpl = Get-NormalPath
    if ((Test-Path -LiteralPath $tpl) -and ([math]::Round((Get-Item -LiteralPath $tpl).Length / 1MB, 2) -ge $TemplateWarnMB)) { throw 'Normal.dotm is at or over TemplateWarnMB; step 6 would blame it and step 9 would not be indicated.' }
}
function Test-DataKeyIndicated {
    try { Assert-DataKeyIndicated; return $true } catch { Write-Host "           $($_.Exception.Message)"; return $false }
}
function Restore-DataKeyBaseline {
    param($Original)
    $data = Get-DataKeyPath
    $new  = @(Get-NewDataBaks -Original $Original)
    if ($new.Count -eq 0) { return }
    if (Test-Path -LiteralPath $data) {
        if (Test-ProcessRunning 'WINWORD') { throw "Word is running with a rebuilt Data key; the user's original is at $(Get-AppKeyPath)\$($new[0]) -- close Word and rename it back by hand." }
        Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction Stop
    }
    Rename-Item -LiteralPath "$(Get-AppKeyPath)\$($new[0])" -NewName 'Data' -ErrorAction Stop
    foreach ($n in @($new | Select-Object -Skip 1)) { Remove-Item -LiteralPath "$(Get-AppKeyPath)\$n" -Recurse -Force -ErrorAction SilentlyContinue }
}

# -- Fixture lifecycle ------------------------------------------------------------

function Initialize-Fixture {
    if (-not (Get-C2RConfig) -or -not (Get-C2RRoot)) { throw 'Click-to-Run configuration or WINWORD.EXE is absent; Invoke-AutoRemediateWord.ps1 would exit 0 as Skipped.' }
    $user = Get-LoggedOnUser; $sid = Get-LoggedOnUserSid
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) { throw "Hive for $user ($sid) is not loaded under HKEY_USERS; the script's per-user steps would not see it." }
    $realMB = Get-DirMB (Get-CachePath)
    $state.CacheThresholdMB = [int]([math]::Ceiling($realMB) + $FixtureCacheMarginMB)
    $tpl = Get-NormalPath
    $tplMB = if (Test-Path -LiteralPath $tpl) { [math]::Round((Get-Item -LiteralPath $tpl).Length / 1MB, 2) } else { 0 }
    Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Office $(Get-OfficeVersion) ($((Get-C2RConfig).VersionToReport)); user $user; Resiliency entries $(@(Get-RealResiliencyValueNames).Count); Normal.dotm ${tplMB}MB; cache ${realMB}MB (fixture threshold $($state.CacheThresholdMB)MB); WINWORD crash/hang 7d $(@(Get-AppCrashEvents).Count); Office running: $(Test-ProcessRunning $OfficeProcs)"
}
function Assert-RunSafe {
    # Refuses a run whose variables would make the script act on real state no break restores.
    param([hashtable]$RunEnv, [string[]]$Names)
    if ($RunEnv['AllowDestructiveActions'] -eq 'true') {
        $tpl = Get-NormalPath
        if ($Names -notcontains 'NormalDotmOversized' -and (Test-Path -LiteralPath $tpl) -and ([math]::Round((Get-Item -LiteralPath $tpl).Length / 1MB, 2) -ge $TemplateWarnMB)) { throw "The user's real Normal.dotm is at or over ${TemplateWarnMB}MB; step 6 would rename it in an ungated run. Refusing." }
        if (@($Names | Where-Object { $_ -like 'DocumentCache*' }).Count -eq 0 -and ((Get-DirMB (Get-CachePath)) -ge 2048 -or (Test-CacheCorrupt))) { throw 'The real Office Document Cache already trips step 7; an ungated run would rename it. Refusing.' }
        if ($Names -notcontains 'WordDataKeyReset' -and @(Get-AppCrashEvents).Count -ge $CrashWarnDefault) { throw "WINWORD has $(@(Get-AppCrashEvents).Count) crash/hang event(s) in 7 days; step 9 could rename the real Word Data key in an ungated run. Refusing." }
    }
}
function Remove-Fixture {
    # Sweep by prefix; per-break Restore normally did all of this. Catches what a half-finished run left behind.
    try {
        $info = Get-RegValueInfo -Path (Get-OptionsPath) -Name 'AUTOSAVE-PATH'
        if ($info.Exists -and "$($info.Value)" -eq (Get-AutoRecoverFixturePath)) { Remove-ItemProperty -LiteralPath (Get-OptionsPath) -Name 'AUTOSAVE-PATH' -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath (Get-AutoRecoverFixturePath)) { Remove-Item -LiteralPath (Get-AutoRecoverFixturePath) -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
    try { $f = Join-Path (Get-StartupPath) $FixtureStartupFile; if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } } catch { }
    try { $d = Get-CacheFixtureDir; if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
    try {
        # A Normal.dotm backup left in the result folder means a run died between Install and Restore.
        $tpl = Get-NormalPath
        foreach ($b in @(Get-ChildItem -LiteralPath $state.ScriptDir -Filter 'DEXTest_Normal.dotm.*.bak' -File -ErrorAction SilentlyContinue)) {
            $fixtureThere = (Test-Path -LiteralPath $tpl) -and ((Get-Item -LiteralPath $tpl).Length -eq ($FixtureTemplateMB * 1MB))
            if ($fixtureThere) { Remove-Item -LiteralPath $tpl -Force -ErrorAction SilentlyContinue }
            if (-not (Test-Path -LiteralPath $tpl)) { Move-Item -LiteralPath $b.FullName -Destination $tpl -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
}

# -- Break definitions ---------------------------------------------------------
# Env: variables the child must see ('' = must be unset). Excludes: break-name patterns that
# cannot share a run with this one. Capture runs before Apply; Restore consumes its result.
# Verify proves the break landed. Validate decides whether remediation did its job.
$GatedSuffix = ' -- set \$AllowDestructiveActions=\$true to apply\.'

$BreakCatalog = @(

    @{
        Name = 'AutoRecoverPathMissing'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false
        Env = @{}; Excludes = @()
        Methods  = @(@{ Name = 'PointAutoSaveAtMissingFolder'; Apply = {
            $p = Get-AutoRecoverFixturePath
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop }
            Set-RegValue -Path (Get-OptionsPath) -Name 'AUTOSAVE-PATH' -Value $p -Type String
        } })
        Capture  = { @{ OptionsExisted = (Test-Path -LiteralPath (Get-OptionsPath)); AutoSave = (Get-RegValueInfo -Path (Get-OptionsPath) -Name 'AUTOSAVE-PATH') } }
        Verify   = {
            $v = (Get-RegValueInfo -Path (Get-OptionsPath) -Name 'AUTOSAVE-PATH').Value
            $ok = ("$v" -eq (Get-AutoRecoverFixturePath)) -and -not (Test-Path -LiteralPath (Get-AutoRecoverFixturePath))
            if (-not $ok) { Write-Host "           AUTOSAVE-PATH is '$v'; fixture folder exists: $(Test-Path -LiteralPath (Get-AutoRecoverFixturePath))" }
            $ok
        }
        # Resolution: "Created AutoRecover folder <path>."
        Validate = {
            $created = Test-Path -LiteralPath (Get-AutoRecoverFixturePath) -PathType Container
            if (-not $created) { Write-Host "           $(Get-AutoRecoverFixturePath) was not created" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step05_' -Pattern "^\[Remediated\] Created AutoRecover folder $([regex]::Escape((Get-AutoRecoverFixturePath)))\.$"
            $created -and $reported
        }
        Restore  = {
            param($Original)
            Set-RegValueInfo -Path (Get-OptionsPath) -Name 'AUTOSAVE-PATH' -Info $Original.AutoSave
            if (-not [bool]$Original.OptionsExisted) { Remove-EmptyRegKey (Get-OptionsPath) }
            if (Test-Path -LiteralPath (Get-AutoRecoverFixturePath)) { Remove-Item -LiteralPath (Get-AutoRecoverFixturePath) -Recurse -Force -ErrorAction SilentlyContinue }
        }
    },

    @{
        Name = 'NormalDotmOversizedGated'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false
        Env = @{ AllowDestructiveActions = '' }; Excludes = @('WordDataKeyReset*')
        Methods  = @(@{ Name = 'ReplaceNormalWithFixture'; Apply = { Install-FixtureNormal } })
        Capture  = { Get-TemplateBaseline }
        Verify   = { param($Original) Test-FixtureNormalPlanted -Original $Original }
        # Step 6: "Normal.dotm is 9MB (threshold 8MB). Rename to Normal_<stamp>.dotm.bak so Word rebuilds it; user macros and styles stay in the backup -- set ..."
        Validate = {
            param($Original)
            $intact = Test-FixtureNormalPlanted -Original $Original
            $baks = @(Get-NewNormalBaks -Original $Original)
            if ($baks.Count -gt 0) { Write-Host "           a .bak was made during a gated run: $($baks -join ', ')" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step06_' -Pattern "^\[Warning\] Normal\.dotm is \d+(\.\d+)?MB \(threshold ${TemplateWarnMB}MB\)\. Rename to Normal_<stamp>\.dotm\.bak so Word rebuilds it; user macros and styles stay in the backup$GatedSuffix"
            $intact -and ($baks.Count -eq 0) -and $reported
        }
        Restore  = { param($Original) Restore-TemplateBaseline -Original $Original }
    },

    @{
        Name = 'NormalDotmOversized'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false
        Env = @{ AllowDestructiveActions = 'true' }; Excludes = @('WordDataKeyReset*')
        Methods  = @(@{ Name = 'ReplaceNormalWithFixture'; Apply = { Install-FixtureNormal } })
        Capture  = { Get-TemplateBaseline }
        Verify   = { param($Original) (Test-FixtureNormalPlanted -Original $Original) -and (-not (Test-ProcessRunning 'WINWORD')) }
        # Resolution: "Normal.dotm renamed to Normal_<stamp>.dotm.bak; Word rebuilds a clean template on next launch."
        Validate = {
            param($Original)
            $gone = -not (Test-Path -LiteralPath (Get-NormalPath))
            if (-not $gone) { Write-Host '           Normal.dotm still present; it was not renamed' }
            $baks = @(Get-NewNormalBaks -Original $Original)
            $oneBak = ($baks.Count -eq 1) -and ($baks[0] -match '^Normal_\d{8}-\d{6}\.dotm\.bak$') -and ((Get-Item -LiteralPath (Join-Path (Get-TemplatesPath) $baks[0])).Length -eq ($FixtureTemplateMB * 1MB))
            if (-not $oneBak) { Write-Host "           expected exactly one fixture-sized Normal_<stamp>.dotm.bak, found: $(if ($baks.Count) { $baks -join ', ' } else { 'none' })" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step06_' -Pattern '^\[Remediated\] Normal\.dotm renamed to Normal_\d{8}-\d{6}\.dotm\.bak; Word rebuilds a clean template on next launch\.$'
            $gone -and $oneBak -and $reported
        }
        Restore  = { param($Original) Restore-TemplateBaseline -Original $Original }
    },

    @{
        Name = 'DocumentCacheBloatGated'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false
        Env = @{ AllowDestructiveActions = ''; CacheSizeWarningMB = '{CacheThresholdMB}' }; Excludes = @()
        Methods  = @(@{ Name = 'BloatCache'; Apply = { Install-CacheFixture } })
        Capture  = { Get-CacheBaseline }
        Verify   = { Test-CacheFixturePlanted }
        # Step 7: "Office Document Cache is <n>MB (threshold <t>MB). Rename to OfficeFileCache_<stamp>.bak; Office rebuilds it -- set ..."
        Validate = {
            param($Original)
            $intact = Test-CacheFixturePlanted
            $baks = @(Get-NewCacheBakDirs -Original $Original)
            if ($baks.Count -gt 0) { Write-Host "           the cache was renamed during a gated run: $($baks.Name -join ', ')" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step07_' -Pattern "^\[Warning\] Office Document Cache is \d+(\.\d+)?MB \(threshold $([int]$state.CacheThresholdMB)MB\)\. Rename to OfficeFileCache_<stamp>\.bak; Office rebuilds it$GatedSuffix"
            $intact -and ($baks.Count -eq 0) -and $reported
        }
        Restore  = { param($Original) Restore-CacheBaseline -Original $Original }
    },

    @{
        Name = 'DocumentCacheBloat'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false
        Env = @{ AllowDestructiveActions = 'true'; CacheSizeWarningMB = '{CacheThresholdMB}' }; Excludes = @()
        Methods  = @(@{ Name = 'BloatCache'; Apply = {
            $open = @(Get-Process -Name $OfficeProcs -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object -Unique)
            if ($open.Count -gt 0) { throw "Office process(es) running ($($open -join ', ')); the script skips the cache rename while any Office app is open and this harness does not close the user's apps. Close them (Outlook counts) and re-run -BreakName DocumentCacheBloat." }
            Install-CacheFixture
        } })
        Capture  = { Get-CacheBaseline }
        Verify   = { (Test-CacheFixturePlanted) -and (-not (Test-ProcessRunning $OfficeProcs)) }
        # Resolution: "Office Document Cache renamed to OfficeFileCache_<stamp>.bak; Office rebuilds it on next launch."
        Validate = {
            param($Original)
            $gone = -not (Test-Path -LiteralPath (Get-CachePath))
            if (-not $gone) { Write-Host '           OfficeFileCache still present; it was not renamed' }
            $baks = @(Get-NewCacheBakDirs -Original $Original)
            $oneBak = ($baks.Count -eq 1) -and ($baks[0].Name -match '^OfficeFileCache_\d{8}-\d{6}\.bak$') -and (Test-Path -LiteralPath (Join-Path $baks[0].FullName "$FixtureCacheDirName\DEXTest_bloat.bin"))
            if (-not $oneBak) { Write-Host "           expected exactly one OfficeFileCache_<stamp>.bak holding the fixture, found: $(if ($baks.Count) { $baks.Name -join ', ' } else { 'none' })" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step07_' -Pattern '^\[Remediated\] Office Document Cache renamed to OfficeFileCache_\d{8}-\d{6}\.bak; Office rebuilds it on next launch\.$'
            $gone -and $oneBak -and $reported
        }
        Restore  = { param($Original) Restore-CacheBaseline -Original $Original }
    },

    @{
        Name = 'WordDataKeyResetGated'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false
        Env = @{ AllowDestructiveActions = ''; CrashWarnCount7d = '0' }; Excludes = @('NormalDotm*')
        Methods  = @(@{ Name = 'ZeroCrashThreshold'; Apply = { Assert-DataKeyIndicated } })
        Capture  = { Get-DataKeyBaseline }
        Verify   = { Test-DataKeyIndicated }
        # Step 9: "Repeated crashes with no add-in, disabled item or template to blame. Resetting the Word Data key (rename to Data_<stamp>) clears corrupted option state; recent-file list is lost -- set ..."
        Validate = {
            param($Original)
            $still = Test-Path -LiteralPath (Get-DataKeyPath)
            if (-not $still) { Write-Host '           Data key is gone after a gated run' }
            $baks = @(Get-NewDataBaks -Original $Original)
            if ($baks.Count -gt 0) { Write-Host "           Data key was renamed during a gated run: $($baks -join ', ')" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step09_' -Pattern "^\[Warning\] Repeated crashes with no add-in, disabled item or template to blame\. Resetting the Word Data key \(rename to Data_<stamp>\) clears corrupted option state; recent-file list is lost$GatedSuffix"
            $still -and ($baks.Count -eq 0) -and $reported
        }
        Restore  = { param($Original) Restore-DataKeyBaseline -Original $Original }
    },

    @{
        Name = 'WordDataKeyReset'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false
        Env = @{ AllowDestructiveActions = 'true'; CrashWarnCount7d = '0' }; Excludes = @('NormalDotm*')
        Methods  = @(@{ Name = 'ZeroCrashThreshold'; Apply = {
            if (Test-ProcessRunning 'WINWORD') { throw 'WINWORD.EXE is running; the script skips the Data key reset while Word is open and this harness does not close the user''s Word. Close it and re-run -BreakName WordDataKeyReset.' }
            Assert-DataKeyIndicated
        } })
        Capture  = { Get-DataKeyBaseline }
        Verify   = { (Test-DataKeyIndicated) -and (-not (Test-ProcessRunning 'WINWORD')) }
        # Resolution: "Word Data key renamed to Data_<stamp>; Word rebuilds it on next launch."
        Validate = {
            param($Original)
            $gone = -not (Test-Path -LiteralPath (Get-DataKeyPath))
            if (-not $gone) { Write-Host '           Data key still present; it was not renamed' }
            $baks = @(Get-NewDataBaks -Original $Original)
            $oneBak = ($baks.Count -eq 1) -and ($baks[0] -match '^Data_\d{8}-\d{6}$')
            if (-not $oneBak) { Write-Host "           expected exactly one Data_<stamp> key, found: $(if ($baks.Count) { $baks -join ', ' } else { 'none' })" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step09_' -Pattern '^\[Remediated\] Word Data key renamed to Data_\d{8}-\d{6}; Word rebuilds it on next launch\.$'
            $gone -and $oneBak -and $reported
        }
        Restore  = { param($Original) Restore-DataKeyBaseline -Original $Original }
    },

    @{
        Name = 'StartupFolderContent'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false
        Env = @{}; Excludes = @()
        Methods  = @(@{ Name = 'PlantStartupFile'; Apply = {
            $dir = Get-StartupPath
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            Set-Content -LiteralPath (Join-Path $dir $FixtureStartupFile) -Value 'Planted by Invoke-AutoRemediateWord_BreakTest.ps1; safe to delete.' -Encoding ASCII -Force -ErrorAction Stop
        } })
        Capture  = {
            $dir = Get-StartupPath
            @{
                MissingDirs = @(Get-MissingDirectories -Paths @((Split-Path -Path $dir -Parent), $dir))
                RealFiles   = @($(if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } }))
                MachineFiles = @($(if (Get-C2RRoot) { Get-ChildItem -LiteralPath (Join-Path (Get-C2RRoot) 'STARTUP') -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } }))
            }
        }
        Verify   = { $ok = Test-Path -LiteralPath (Join-Path (Get-StartupPath) $FixtureStartupFile); if (-not $ok) { Write-Host '           startup fixture missing' }; $ok }
        # Step 10: "<n> file(s) load at every Word start: <first five>. Report only; ..."  The fixture is named only when five or fewer files exist in total.
        Validate = {
            param($Original)
            $still = Test-Path -LiteralPath (Join-Path (Get-StartupPath) $FixtureStartupFile)
            if (-not $still) { Write-Host '           startup fixture was removed by a report-only step' }
            $total = @($Original.RealFiles).Count + @($Original.MachineFiles).Count + 1
            $namePart = if ($total -le 5) { ".*$([regex]::Escape($FixtureStartupFile)) \(\d+KB\)" } else { '' }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step10_' -Pattern "^\[Warning\] \d+ file\(s\) load at every Word start:$namePart.*Report only; startup add-ins are deployed on purpose, but a corrupt one crashes Word at launch\.$"
            $still -and $reported
        }
        Restore  = {
            param($Original)
            $f = Join-Path (Get-StartupPath) $FixtureStartupFile
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
            Remove-MissingDirectories -Paths @($Original.MissingDirs)
        }
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

Write-DexBanner -Title 'Invoke-AutoRemediateWord_BreakTest' -Detail "Environment: $Environment"

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

        $candidates = if ($BreakName) {
            @($BreakCatalog | Where-Object { @($BreakName -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Name })
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
            $method   = (Get-DexRandomSubset -InputObject ([object[]]@($def.Methods).Clone()) -Random $state.Random -Count 1)[0]
            $original = & $def.Capture
            & $method.Apply
            if ($def.RequiresReboot) { $state.RequiresReboot = $true }
            $applied += @{
                Name = $def.Name; Method = $method.Name; ExpectedOutcome = $def.ExpectedOutcome
                RequiresReboot = [bool]$def.RequiresReboot; Applied = $true; BreakVerified = $false; OriginalState = $original
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
            $ok  = [bool](& $def.Verify ([PSCustomObject]$b.OriginalState))
            $b.BreakVerified = $ok
            if ($ok) {
                Write-DexStep -Status 'Passed' -Name "Verify $($b.Name)" -Message 'component is genuinely broken'
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
                Name = $b.Name; Expected = $expected
                Actual = $(if ($passed) { 'as expected' } else { 'NOT as expected' })
                Result = $(if ($passed) { 'Pass' } else { 'Fail' })
            }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) -Name "Validate $($b.Name)" -Message $expected
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
    try { Remove-Fixture } catch { $restoreFailed = $true }
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
