<#
.SYNOPSIS
    Invoke-AutoRemediatePowerPoint_BreakTest -- deliberately plants PowerPoint faults, then
    verifies Invoke-AutoRemediatePowerPoint.ps1 reports or repairs them as documented.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform JSON
    result to C:\Temp\FixReport\Invoke-AutoRemediatePowerPoint\ for Invoke-FixReportAnalysis.ps1.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It writes AutoRecover values and
    Common\Graphics\DisableHardwareAcceleration into the logged-on user's Office hive, and
    places an oversized Blank.potx in the user's Templates folder
    (any existing Blank.potx is backed up and put back). Run it only on a marked test host
    (Assert-DexTestHost in DEXTestFramework.psm1).

    HOW THE SCRIPT SEES THE USER
    Invoke-AutoRemediatePowerPoint.ps1 resolves the logged-on user from
    Win32_ComputerSystem.UserName and reads HKEY_USERS\<SID>, so the harness does the same.
    Run elevated as the interactive user; the child powershell.exe runs in this same
    context, as Workspace ONE Hub would, with the script's inputs passed as environment
    variables (AllowDestructiveActions, CacheSizeWarningMB, CrashWarnCount7d,
    TemplateWarnMB). Every planted artefact carries the DEXTest prefix; every break
    Captures what it changes and Restore writes it back.

    ONE ENVIRONMENT PER RUN
    Each break declares the variables the child must see (Env); '' means "must be unset".
    A gated break (flag unset, ExpectReportedOnly) and its ungated twin (flag 'true',
    ExpectFixed) cannot share a run: the first drawn decides and conflicting draws are
    dropped. The three GraphicsAccel* breaks share one registry value and exclude each
    other. A run is refused when the script would act on real state no break restores: a
    real oversized Blank.potx in an ungated run; real AutoRecoverEnabled=0 or a missing
    real AutoRecoverPath in any run (step 5 fixes those unconditionally) unless the
    matching break is in the run.

    THE PRE-EXISTING GRAPHICS CRASH
    Step 6 fires only when the newest POWERPNT.EXE crash in the last 7 days faulted in a
    display-driver module. This host has one (igd10iumd64.dll, 2026-11-03) and the harness
    never writes to the Application log, so the GraphicsAccel* breaks ride on that event
    and refuse to start once it ages out. Because step 6 writes DisableHardwareAcceleration=1
    in EVERY ungated run while that crash is present, the value is captured at run start and
    put back by Remove-Fixture regardless of which breaks were drawn. Steps 2 and 6 Warn on
    this host before any break is applied; Validate blocks tolerate that.

    EXPECTED OUTCOMES (derived from the script's own messages, 1.0.3)
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    Step 5  AutoRecoverPathMissing        Fixed (no gate). Options\AutoRecoverPath points at a
                                          missing DEXTest_AutoRecover_PowerPoint folder (the
                                          Options key is created if absent and removed again).
            AutoRecoverDisabled           Fixed (no gate, PowerPoint closed). AutoRecoverEnabled=0.
    Step 6  GraphicsAccelFaultGated       ReportedOnly. DisableHardwareAcceleration removed if set;
                                          needs the real graphics crash.
            GraphicsAccelFault            Fixed (AllowDestructiveActions). The script writes
                                          DisableHardwareAcceleration=1; Restore puts the original
                                          value (or its absence) back.
            GraphicsAccelAlreadyDisabled  ReportedOnly (any flag). DisableHardwareAcceleration=1
                                          planted; the script reports "already disabled".
    Step 10 BlankTemplateOversizedGated   ReportedOnly. 9 MB zero-filled Blank.potx (TemplateWarnMB
                                          default 8); a PowerPoint started meanwhile would see a
                                          corrupt template for new presentations until Restore.
            BlankTemplateOversized        Fixed (AllowDestructiveActions, PowerPoint closed).
                                          Renamed to Blank_<stamp>.potx.bak; Restore deletes the
                                          new .bak and puts any original Blank.potx back.

    NOT COVERED
      Step 2  Crash and Hang History -- the only trigger is a real POWERPNT 1000/1002 event.
      Steps 3 and 4 (COM Add-in Conflict, Office-Disabled Items) -- moved to
              ApplicationSpecific\Microsoft\Office\Invoke-AutoRemediateOfficeAddins.ps1; its
              own harness carries the four add-in breaks that used to live here.
      Step 6  Passed-with-note branch (no graphics crash, value already 1) -- only reachable once
              the real crash ages out.
      Steps 7 and 8 -- shipped Enabled = $false here (Word owns them).
      "PowerPoint is open" skip branches of steps 5 and 10 -- the harness refuses to start those
              breaks with PowerPoint open rather than test the skip.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediatePowerPoint.ps1 and validate. Without it: break and report.
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
    Script Name  : Invoke-AutoRemediatePowerPoint_BreakTest.ps1
    Version      : 1.0.1
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated), run as the interactive user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediatePowerPoint\

    1.0.1  ThirdPartyAddinConflictGated, ThirdPartyAddinConflict, DisabledItemGated and
           DisabledItem moved to the Invoke-AutoRemediateOfficeAddins.ps1 harness with the
           script's steps 3 and 4; ReenableDisabledItems is no longer passed to the child.
           Seven breaks remain. Tracks script 1.0.3.
    1.0.0  Initial: eleven breaks against script 1.0.1 (steps 3, 4, 5, 6, 10).

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

$ScriptUnderTest   = 'Invoke-AutoRemediatePowerPoint'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediatePowerPoint.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\PowerPointErrors'
$C2RConfigPath     = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "DEXTestFramework.psm1 not found at $modulePath" }
Import-Module $modulePath -Force
if (-not (Test-Path -LiteralPath $RemediationScript)) { throw "Script under test not found at $RemediationScript" }

# -- Fixture ------------------------------------------------------------------
$FixtureAutoRecoverDir = 'DEXTest_AutoRecover_PowerPoint'  # under AppData\Local\Microsoft\Office
$FixtureTemplateMB     = 9                                 # Blank.potx fixture; script default TemplateWarnMB is 8
$TemplateWarnMB        = 8
$GfxValueName          = 'DisableHardwareAcceleration'
# Same matcher as the script, verbatim, so "graphics stack" means the same thing here.
$GfxModuleMatcher      = '^(ig\w*|nv\w*|atidx\w*|amd\w*|d3d\w*|dxgi|oart\w*)\.dll$'

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
        if (Test-Path -LiteralPath (Join-Path $p 'POWERPNT.EXE')) { return $p }
    }
    return $null
}
function Get-UserHive          { "Registry::HKEY_USERS\$(Get-LoggedOnUserSid)" }
function Get-AppKeyPath        { "$(Get-UserHive)\Software\Microsoft\Office\$(Get-OfficeVersion)\PowerPoint" }   # versioned key: Options, Resiliency
function Get-OptionsPath       { "$(Get-AppKeyPath)\Options" }
function Get-GfxKeyPath        { "$(Get-UserHive)\Software\Microsoft\Office\$(Get-OfficeVersion)\Common\Graphics" }
function Get-TemplatesPath     { Join-Path (Get-UserProfilePath) 'AppData\Roaming\Microsoft\Templates' }
function Get-BlankPath         { Join-Path (Get-TemplatesPath) 'Blank.potx' }
function Get-AutoRecoverFixturePath { Join-Path (Get-UserProfilePath) "AppData\Local\Microsoft\Office\$FixtureAutoRecoverDir" }
function Get-TemplateBackupPath { Join-Path $state.ScriptDir "DEXTest_Blank.potx.$($state.TestId).bak" }

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
    # POWERPNT.EXE 1000/1002 records in the last 7 days, newest first, as step 2 reads them. Plain array.
    $ev = @()
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = @('Application Error', 'Application Hang'); Id = @(1000, 1002); StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue |
               Where-Object { $_.Properties.Count -gt 0 -and "$($_.Properties[0].Value)" -ieq 'POWERPNT.EXE' } | Sort-Object TimeCreated -Descending)
    } catch { }
    return $ev
}
function Get-LastCrashModule {
    # Faulting module of the newest 1000 event, the value step 6 tests against $_gfxModule; '' when none.
    $last = @(Get-AppCrashEvents | Where-Object { $_.Id -eq 1000 } | Select-Object -First 1)
    if ($last.Count -eq 0 -or $last[0].Properties.Count -le 3) { return '' }
    return "$($last[0].Properties[3].Value)"
}
function Test-GfxCrashPresent { ((Get-LastCrashModule) -match $GfxModuleMatcher) }
function New-ZeroFile {
    param([string]$Path, [int]$SizeMB)
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
    & fsutil.exe file createnew $Path ([int64]$SizeMB * 1MB) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "fsutil file createnew failed with exit code $LASTEXITCODE for $Path" }
    if (-not (Test-Path -LiteralPath $Path)) { throw "fsutil reported success but $Path does not exist" }
}
function Test-DirEmpty { param([string]$Dir) (@(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue).Count -eq 0) }
function Remove-MissingDirectories {
    # Deepest first; only an empty directory is removed.
    param($Paths)
    $list = @($Paths | Where-Object { $_ })
    [array]::Reverse($list)
    foreach ($p in $list) {
        if ((Test-Path -LiteralPath "$p" -PathType Container) -and (Test-DirEmpty "$p")) { Remove-Item -LiteralPath "$p" -Force -ErrorAction SilentlyContinue }
    }
}
function Assert-PowerPointClosed {
    param([string]$BreakName)
    if (Test-ProcessRunning 'POWERPNT') { throw "POWERPNT.EXE is running; the script skips this fix while PowerPoint is open and this harness does not close the user's PowerPoint. Close it and re-run -BreakName $BreakName." }
}
function Assert-GfxCrashPresent {
    $mod = Get-LastCrashModule
    if ($mod -notmatch $GfxModuleMatcher) { throw "The newest POWERPNT.EXE crash in the last 7 days faulted in '$mod', not a graphics-stack module; step 6 would Pass. The harness never writes Application log events, so this break cannot be injected until a real display-driver crash exists." }
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
function Get-RemediationVariables {
    # Every variable the child must see. '' means unset; the four inputs the script reads are always
    # made explicit so a stray value in the harness's own environment cannot leak into the child.
    $vars = @{}
    $runEnv = ConvertTo-DexHashtable -InputObject $state.RunEnv
    if ($runEnv) { foreach ($k in @($runEnv.Keys)) { $vars[$k] = "$($runEnv[$k])" } }
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

# -- Helpers: step 5 AutoRecover ---------------------------------------------------

function Get-AutoRecoverBaseline {
    @{
        OptionsExisted = (Test-Path -LiteralPath (Get-OptionsPath))
        Path           = (Get-RegValueInfo -Path (Get-OptionsPath) -Name 'AutoRecoverPath')
        Enabled        = (Get-RegValueInfo -Path (Get-OptionsPath) -Name 'AutoRecoverEnabled')
    }
}
function Get-RealAutoRecoverProblems {
    # What step 5 would fix on this host right now, ignoring our fixture. Plain string array.
    $out = @()
    $en = Get-RegValueInfo -Path (Get-OptionsPath) -Name 'AutoRecoverEnabled'
    if ($en.Exists -and [int]$en.Value -eq 0) { $out += 'AutoRecoverEnabled=0' }
    $p = Get-RegValueInfo -Path (Get-OptionsPath) -Name 'AutoRecoverPath'
    if ($p.Exists) {
        $path = [Environment]::ExpandEnvironmentVariables("$($p.Value)")
        if ($path -and $path -ne (Get-AutoRecoverFixturePath) -and -not (Test-Path -LiteralPath $path)) { $out += "AutoRecoverPath missing ($path)" }
    }
    return @($out)
}
function Restore-AutoRecoverBaseline {
    param($Original)
    Set-RegValueInfo -Path (Get-OptionsPath) -Name 'AutoRecoverPath'    -Info $Original.Path
    Set-RegValueInfo -Path (Get-OptionsPath) -Name 'AutoRecoverEnabled' -Info $Original.Enabled
    if (-not [bool]$Original.OptionsExisted) { Remove-EmptyRegKey (Get-OptionsPath) }
    if (Test-Path -LiteralPath (Get-AutoRecoverFixturePath)) { Remove-Item -LiteralPath (Get-AutoRecoverFixturePath) -Recurse -Force -ErrorAction SilentlyContinue }
}

# -- Helpers: step 6 graphics acceleration -------------------------------------------

function Get-GfxValue { (Get-RegValueInfo -Path (Get-GfxKeyPath) -Name $GfxValueName).Value }
function Get-GfxBaseline { @{ KeyExisted = (Test-Path -LiteralPath (Get-GfxKeyPath)); Value = (Get-RegValueInfo -Path (Get-GfxKeyPath) -Name $GfxValueName) } }
function Restore-GfxBaseline {
    param($Original)
    Set-RegValueInfo -Path (Get-GfxKeyPath) -Name $GfxValueName -Info $Original.Value
    if (-not [bool]$Original.KeyExisted) { Remove-EmptyRegKey (Get-GfxKeyPath) }
}
function Clear-GfxValue { Set-RegValueInfo -Path (Get-GfxKeyPath) -Name $GfxValueName -Info @{ Exists = $false } }
function Test-GfxFaultArmed {
    # Step 6 takes its Warning-with-fix branch: graphics crash present and the value not yet 1.
    if (-not (Test-GfxCrashPresent)) { Write-Host "           newest POWERPNT crash module '$(Get-LastCrashModule)' is not a graphics-stack module"; return $false }
    $v = Get-GfxValue
    if ("$v" -eq '1') { Write-Host "           $GfxValueName is already 1"; return $false }
    return $true
}

# -- Helpers: step 10 Blank.potx -----------------------------------------------------

function Get-BlankBakNames {
    $dir = Get-TemplatesPath
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter 'Blank_*.potx.bak' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}
function Get-NewBlankBaks { param($Original) @(Get-BlankBakNames | Where-Object { @($Original.ExistingBaks) -notcontains $_ }) }
function Get-TemplateBaseline {
    $tpl = Get-BlankPath
    @{
        TemplatesDirExisted = (Test-Path -LiteralPath (Get-TemplatesPath))
        BlankExisted        = (Test-Path -LiteralPath $tpl)
        BlankLength         = $(if (Test-Path -LiteralPath $tpl) { (Get-Item -LiteralPath $tpl).Length } else { 0 })
        BackupPath          = Get-TemplateBackupPath
        ExistingBaks        = @(Get-BlankBakNames)
    }
}
function Install-FixtureBlank {
    # Backs any user Blank.potx up to the result folder, then puts a 9 MB zero-filled file in its place.
    $tpl = Get-BlankPath; $bak = Get-TemplateBackupPath
    if (Test-Path -LiteralPath $tpl) {
        Copy-Item -LiteralPath $tpl -Destination $bak -Force -ErrorAction Stop
        if ((Get-Item -LiteralPath $bak).Length -ne (Get-Item -LiteralPath $tpl).Length) { throw "Backup of Blank.potx at $bak does not match the original; refusing to replace it." }
        Remove-Item -LiteralPath $tpl -Force -ErrorAction Stop
    }
    New-ZeroFile -Path $tpl -SizeMB $FixtureTemplateMB
}
function Test-FixtureBlankPlanted {
    param($Original)
    $tpl = Get-BlankPath
    if (-not (Test-Path -LiteralPath $tpl)) { Write-Host "           $tpl missing"; return $false }
    $len = (Get-Item -LiteralPath $tpl).Length
    if ($len -ne ($FixtureTemplateMB * 1MB)) { Write-Host "           Blank.potx is $len bytes, not the ${FixtureTemplateMB}MB fixture"; return $false }
    if ([bool]$Original.BlankExisted -and -not (Test-Path -LiteralPath "$($Original.BackupPath)")) { Write-Host "           backup $($Original.BackupPath) missing"; return $false }
    return $true
}
function Restore-TemplateBaseline {
    param($Original)
    $tpl = Get-BlankPath
    foreach ($n in @(Get-NewBlankBaks -Original $Original)) { Remove-Item -LiteralPath (Join-Path (Get-TemplatesPath) $n) -Force -ErrorAction SilentlyContinue }
    if ((Test-Path -LiteralPath $tpl) -and ((Get-Item -LiteralPath $tpl).Length -eq ($FixtureTemplateMB * 1MB))) { Remove-Item -LiteralPath $tpl -Force -ErrorAction Stop }
    $bak = "$($Original.BackupPath)"
    if ($bak -and (Test-Path -LiteralPath $bak)) {
        if (Test-Path -LiteralPath $tpl) {
            # PowerPoint saved a new Blank.potx in the window; the user's original wins.
            if (Test-ProcessRunning 'POWERPNT') { throw "PowerPoint is running with a new Blank.potx; the user's original is at $bak -- close PowerPoint and copy it back by hand." }
            Remove-Item -LiteralPath $tpl -Force -ErrorAction Stop
        }
        Move-Item -LiteralPath $bak -Destination $tpl -Force -ErrorAction Stop
    }
    if (-not [bool]$Original.TemplatesDirExisted) { Remove-MissingDirectories -Paths @(Get-TemplatesPath) }
}

# -- Fixture lifecycle ------------------------------------------------------------

function Initialize-Fixture {
    if (-not (Get-C2RConfig) -or -not (Get-C2RRoot)) { throw 'Click-to-Run configuration or POWERPNT.EXE is absent; Invoke-AutoRemediatePowerPoint.ps1 would exit 0 as Skipped.' }
    $user = Get-LoggedOnUser; $sid = Get-LoggedOnUserSid
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) { throw "Hive for $user ($sid) is not loaded under HKEY_USERS; the script's per-user steps would not see it." }
    # Step 6 writes DisableHardwareAcceleration=1 in every ungated run while the graphics crash is
    # present, whatever breaks were drawn; capture it once per run and put it back in Remove-Fixture.
    $state.GfxBaseline = Get-GfxBaseline
    $tpl = Get-BlankPath
    $tplMB = if (Test-Path -LiteralPath $tpl) { [math]::Round((Get-Item -LiteralPath $tpl).Length / 1MB, 2) } else { 0 }
    Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Office $(Get-OfficeVersion) ($((Get-C2RConfig).VersionToReport)); user $user; AutoRecover problems: $(@(Get-RealAutoRecoverProblems) -join ', '); $GfxValueName '$(Get-GfxValue)'; POWERPNT crash/hang 7d $(@(Get-AppCrashEvents).Count), newest crash module '$(Get-LastCrashModule)' (graphics: $(Test-GfxCrashPresent)); Blank.potx ${tplMB}MB; POWERPNT running: $(Test-ProcessRunning 'POWERPNT')"
}
function Assert-RunSafe {
    # Refuses a run whose variables would make the script act on real state no break restores.
    param([hashtable]$RunEnv, [string[]]$Names)
    if ($RunEnv['AllowDestructiveActions'] -eq 'true') {
        $tpl = Get-BlankPath
        if ($Names -notcontains 'BlankTemplateOversized' -and (Test-Path -LiteralPath $tpl) -and ([math]::Round((Get-Item -LiteralPath $tpl).Length / 1MB, 2) -ge $TemplateWarnMB)) { throw "The user's real Blank.potx is at or over ${TemplateWarnMB}MB; step 10 would rename it in an ungated run. Refusing." }
    }
    # Step 5 fixes unconditionally (with PowerPoint closed); real problems there are changed by every run.
    $ar = @(Get-RealAutoRecoverProblems)
    if ($ar.Count -gt 0 -and @($Names | Where-Object { $_ -like 'AutoRecover*' }).Count -eq 0) { throw "Real AutoRecover problem(s) exist ($($ar -join '; ')); step 5 would fix them and nothing would put them back. Refusing." }
}
function Remove-Fixture {
    # Sweep by prefix; per-break Restore normally did all of this. Catches what a half-finished run left behind.
    try {
        $info = Get-RegValueInfo -Path (Get-OptionsPath) -Name 'AutoRecoverPath'
        if ($info.Exists -and "$($info.Value)" -eq (Get-AutoRecoverFixturePath)) { Remove-ItemProperty -LiteralPath (Get-OptionsPath) -Name 'AutoRecoverPath' -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath (Get-AutoRecoverFixturePath)) { Remove-Item -LiteralPath (Get-AutoRecoverFixturePath) -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
    try { if ($state.GfxBaseline) { Restore-GfxBaseline -Original $state.GfxBaseline } } catch { }
    try {
        # A Blank.potx backup left in the result folder means a run died between Install and Restore.
        $tpl = Get-BlankPath
        $fixtureThere = (Test-Path -LiteralPath $tpl) -and ((Get-Item -LiteralPath $tpl).Length -eq ($FixtureTemplateMB * 1MB))
        foreach ($b in @(Get-ChildItem -LiteralPath $state.ScriptDir -Filter 'DEXTest_Blank.potx.*.bak' -File -ErrorAction SilentlyContinue)) {
            if ($fixtureThere) { Remove-Item -LiteralPath $tpl -Force -ErrorAction SilentlyContinue; $fixtureThere = $false }
            if (-not (Test-Path -LiteralPath $tpl)) { Move-Item -LiteralPath $b.FullName -Destination $tpl -Force -ErrorAction SilentlyContinue }
        }
        if ($fixtureThere -and -not [bool]$state.BlankExistedAtStart) { Remove-Item -LiteralPath $tpl -Force -ErrorAction SilentlyContinue }
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
        Methods  = @(@{ Name = 'PointAutoRecoverAtMissingFolder'; Apply = {
            $p = Get-AutoRecoverFixturePath
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop }
            Set-RegValue -Path (Get-OptionsPath) -Name 'AutoRecoverPath' -Value $p -Type String
        } })
        Capture  = { Get-AutoRecoverBaseline }
        Verify   = {
            $v = (Get-RegValueInfo -Path (Get-OptionsPath) -Name 'AutoRecoverPath').Value
            $ok = ("$v" -eq (Get-AutoRecoverFixturePath)) -and -not (Test-Path -LiteralPath (Get-AutoRecoverFixturePath))
            if (-not $ok) { Write-Host "           AutoRecoverPath is '$v'; fixture folder exists: $(Test-Path -LiteralPath (Get-AutoRecoverFixturePath))" }
            $ok
        }
        # Resolution: "AutoRecover: created <path>." (joined with "; set AutoRecoverEnabled=1" when AutoRecoverDisabled shares the run)
        Validate = {
            $created = Test-Path -LiteralPath (Get-AutoRecoverFixturePath) -PathType Container
            if (-not $created) { Write-Host "           $(Get-AutoRecoverFixturePath) was not created" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step05_' -Pattern "^\[Remediated\] AutoRecover: .*created $([regex]::Escape((Get-AutoRecoverFixturePath)))(; .*)?\.$"
            $created -and $reported
        }
        Restore  = { param($Original) Restore-AutoRecoverBaseline -Original $Original }
    },

    @{
        Name = 'AutoRecoverDisabled'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false
        Env = @{}; Excludes = @()
        Methods  = @(@{ Name = 'DisableAutoRecover'; Apply = {
            Assert-PowerPointClosed -BreakName 'AutoRecoverDisabled'
            Set-RegValue -Path (Get-OptionsPath) -Name 'AutoRecoverEnabled' -Value 0 -Type DWord
        } })
        Capture  = { Get-AutoRecoverBaseline }
        Verify   = {
            $v = (Get-RegValueInfo -Path (Get-OptionsPath) -Name 'AutoRecoverEnabled').Value
            if ("$v" -ne '0') { Write-Host "           AutoRecoverEnabled is '$v', expected 0" }
            ("$v" -eq '0') -and (-not (Test-ProcessRunning 'POWERPNT'))
        }
        # Resolution: "AutoRecover: set AutoRecoverEnabled=1."
        Validate = {
            $v = (Get-RegValueInfo -Path (Get-OptionsPath) -Name 'AutoRecoverEnabled').Value
            if ("$v" -ne '1') { Write-Host "           AutoRecoverEnabled is '$v', expected 1" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step05_' -Pattern '^\[Remediated\] AutoRecover: .*set AutoRecoverEnabled=1\.$'
            ("$v" -eq '1') -and $reported
        }
        Restore  = { param($Original) Restore-AutoRecoverBaseline -Original $Original }
    },

    @{
        Name = 'GraphicsAccelFaultGated'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false
        Env = @{ AllowDestructiveActions = '' }; Excludes = @('GraphicsAccel*')
        Methods  = @(@{ Name = 'ArmOnRealGraphicsCrash'; Apply = { Assert-GfxCrashPresent; Clear-GfxValue } })
        Capture  = { Get-GfxBaseline }
        Verify   = { Test-GfxFaultArmed }
        # Step 6: "Last crash faulted in <module> (graphics stack), <n> crash/hang event(s) in 7 days. Setting Common\Graphics\DisableHardwareAcceleration=1 -- this turns off GPU rendering for EVERY Office app for this user -- set ..."
        Validate = {
            $v = Get-GfxValue
            $untouched = ("$v" -ne '1')
            if (-not $untouched) { Write-Host "           $GfxValueName became 1 during a gated run" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step06_' -Pattern "^\[Warning\] Last crash faulted in \S+ \(graphics stack\), \d+ crash/hang event\(s\) in 7 days\. Setting Common\\Graphics\\$GfxValueName=1 -- this turns off GPU rendering for EVERY Office app for this user$GatedSuffix$"
            $untouched -and $reported
        }
        Restore  = { param($Original) Restore-GfxBaseline -Original $Original }
    },

    @{
        Name = 'GraphicsAccelFault'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false
        Env = @{ AllowDestructiveActions = 'true' }; Excludes = @('GraphicsAccel*')
        Methods  = @(@{ Name = 'ArmOnRealGraphicsCrash'; Apply = { Assert-GfxCrashPresent; Clear-GfxValue } })
        Capture  = { Get-GfxBaseline }
        Verify   = { Test-GfxFaultArmed }
        # Resolution: "DisableHardwareAcceleration=1 set under Common\Graphics; takes effect at the next launch of each Office app. Revert by deleting the value once the display driver is updated."
        Validate = {
            $v = Get-GfxValue
            if ("$v" -ne '1') { Write-Host "           $GfxValueName is '$v'; expected 1" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step06_' -Pattern "^\[Remediated\] $GfxValueName=1 set under Common\\Graphics; takes effect at the next launch of each Office app\. Revert by deleting the value once the display driver is updated\.$"
            ("$v" -eq '1') -and $reported
        }
        Restore  = { param($Original) Restore-GfxBaseline -Original $Original }
    },

    @{
        Name = 'GraphicsAccelAlreadyDisabled'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false
        Env = @{}; Excludes = @('GraphicsAccel*')
        Methods  = @(@{ Name = 'PlantDisableHardwareAcceleration'; Apply = { Assert-GfxCrashPresent; Set-RegValue -Path (Get-GfxKeyPath) -Name $GfxValueName -Value 1 -Type DWord } })
        Capture  = { Get-GfxBaseline }
        Verify   = {
            $v = Get-GfxValue
            if ("$v" -ne '1') { Write-Host "           $GfxValueName is '$v', expected 1" }
            ("$v" -eq '1') -and (Test-GfxCrashPresent)
        }
        # Step 6: "Last crash faulted in <module> with Office hardware acceleration already disabled. Nothing further to set locally; this points at the display driver itself."
        Validate = {
            $v = Get-GfxValue
            if ("$v" -ne '1') { Write-Host "           $GfxValueName changed to '$v' during a report-only step" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step06_' -Pattern '^\[Warning\] Last crash faulted in \S+ with Office hardware acceleration already disabled\. Nothing further to set locally; this points at the display driver itself\.$'
            ("$v" -eq '1') -and $reported
        }
        Restore  = { param($Original) Restore-GfxBaseline -Original $Original }
    },

    @{
        Name = 'BlankTemplateOversizedGated'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false
        Env = @{ AllowDestructiveActions = '' }; Excludes = @()
        Methods  = @(@{ Name = 'ReplaceBlankWithFixture'; Apply = { Install-FixtureBlank } })
        Capture  = { $state.BlankExistedAtStart = (Test-Path -LiteralPath (Get-BlankPath)); Get-TemplateBaseline }
        Verify   = { param($Original) Test-FixtureBlankPlanted -Original $Original }
        # Step 10: "Blank.potx is 9MB (threshold 8MB); every new presentation starts from it. Rename to Blank_<stamp>.potx.bak so PowerPoint falls back to the default theme; the user's theme stays in the backup -- set ..."
        Validate = {
            param($Original)
            $intact = Test-FixtureBlankPlanted -Original $Original
            $baks = @(Get-NewBlankBaks -Original $Original)
            if ($baks.Count -gt 0) { Write-Host "           a .bak was made during a gated run: $($baks -join ', ')" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step10_' -Pattern "^\[Warning\] Blank\.potx is \d+(\.\d+)?MB \(threshold ${TemplateWarnMB}MB\); every new presentation starts from it\. Rename to Blank_<stamp>\.potx\.bak so PowerPoint falls back to the default theme; the user's theme stays in the backup$GatedSuffix"
            $intact -and ($baks.Count -eq 0) -and $reported
        }
        Restore  = { param($Original) Restore-TemplateBaseline -Original $Original }
    },

    @{
        Name = 'BlankTemplateOversized'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false
        Env = @{ AllowDestructiveActions = 'true' }; Excludes = @()
        Methods  = @(@{ Name = 'ReplaceBlankWithFixture'; Apply = { Assert-PowerPointClosed -BreakName 'BlankTemplateOversized'; Install-FixtureBlank } })
        Capture  = { $state.BlankExistedAtStart = (Test-Path -LiteralPath (Get-BlankPath)); Get-TemplateBaseline }
        Verify   = { param($Original) (Test-FixtureBlankPlanted -Original $Original) -and (-not (Test-ProcessRunning 'POWERPNT')) }
        # Resolution: "Blank.potx renamed to Blank_<stamp>.potx.bak; PowerPoint uses the default theme until a new one is saved."
        Validate = {
            param($Original)
            $gone = -not (Test-Path -LiteralPath (Get-BlankPath))
            if (-not $gone) { Write-Host '           Blank.potx still present; it was not renamed' }
            $baks = @(Get-NewBlankBaks -Original $Original)
            $oneBak = ($baks.Count -eq 1) -and ($baks[0] -match '^Blank_\d{8}-\d{6}\.potx\.bak$') -and ((Get-Item -LiteralPath (Join-Path (Get-TemplatesPath) $baks[0])).Length -eq ($FixtureTemplateMB * 1MB))
            if (-not $oneBak) { Write-Host "           expected exactly one fixture-sized Blank_<stamp>.potx.bak, found: $(if ($baks.Count) { $baks -join ', ' } else { 'none' })" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step10_' -Pattern '^\[Remediated\] Blank\.potx renamed to Blank_\d{8}-\d{6}\.potx\.bak; PowerPoint uses the default theme until a new one is saved\.$'
            $gone -and $oneBak -and $reported
        }
        Restore  = { param($Original) Restore-TemplateBaseline -Original $Original }
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

Write-DexBanner -Title 'Invoke-AutoRemediatePowerPoint_BreakTest' -Detail "Environment: $Environment"

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
