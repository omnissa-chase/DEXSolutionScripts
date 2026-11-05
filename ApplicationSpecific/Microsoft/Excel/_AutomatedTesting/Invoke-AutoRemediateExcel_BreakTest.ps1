<#
.SYNOPSIS
    Invoke-AutoRemediateExcel_BreakTest -- deliberately plants Excel faults, then verifies
    Invoke-AutoRemediateExcel.ps1 reports or repairs them as documented.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform JSON
    result to C:\Temp\FixReport\Invoke-AutoRemediateExcel\ for Invoke-FixReportAnalysis.ps1.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It writes AutoRecover values, an OPENn add-in
    registration and a calculation-mode override into the logged-on user's Excel hive, and
    drops a file into the user's XLSTART folder. Run it only on a marked test host
    (Assert-DexTestHost in DEXTestFramework.psm1).

    HOW THE SCRIPT SEES THE USER
    Invoke-AutoRemediateExcel.ps1 resolves the logged-on user from
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
    dropped. A run is refused when the script would act on real state no break restores:
    real XLSTART content (step 6 quarantines everything but PERSONAL.XLSB) in an ungated
    run; a real dangling OPENn registration, AutoRecoverEnabled=0 or missing AutoRecoverPath
    in any run (steps 5 and 9 fix those unconditionally) unless the matching break is in
    the run.

    EXCEL REWRITES OPTIONS ON EXIT
    Steps 5 (re-enable), 6 and 9 only act with Excel closed, and an Excel that exits after
    a break overwrites the planted Options values with its own. The breaks that need the
    fix refuse to start while EXCEL.EXE is running; the harness never closes the user's
    Excel. Plant-and-report breaks tolerate a running Excel.

    EXPECTED OUTCOMES (derived from the script's own messages, 1.0.3)
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    Step 5  AutoRecoverPathMissing        Fixed (no gate). Options\AutoRecoverPath points at a
                                          missing DEXTest_AutoRecover_Excel folder; the script
                                          creates it.
            AutoRecoverDisabled           Fixed (no gate, Excel closed). AutoRecoverEnabled=0; the
                                          script sets it back to 1.
    Step 6  XlStartContentGated           ReportedOnly. DEXTest_lab.csv in the user's XLSTART
                                          folder (a CSV opens harmlessly if Excel starts meanwhile).
            XlStartContent                Fixed (AllowDestructiveActions, Excel closed, no real
                                          startup content). Moved to XLSTART_quarantine_<stamp>
                                          beside the folder; Restore deletes it and the folder.
    Step 9  XlamDanglingRegistration      Fixed (no gate, Excel closed). A new OPENn value points
                                          at a missing DEXTest_lab.xlam; the script drops it and
                                          renumbers the user's real OPENn values, which Restore
                                          writes back exactly as captured.
    Step 10 CalcModeManual                ReportedOnly (the step has no fix). Options\
                                          DefaultCalcMode=2.

    NOT COVERED
      Step 2  Crash and Hang History -- the only trigger is a real EXCEL 1000/1002 event; the
              harness never writes to the Application log.
      Steps 3 and 4 (COM Add-in Conflict, Office-Disabled Items) -- moved to
              ApplicationSpecific\Microsoft\Office\Invoke-AutoRemediateOfficeAddins.ps1; its
              own harness carries the four add-in breaks that used to live here.
      Step 6  Failed branch ("Repeated crashes and ...") -- needs real crash events.
      Step 6  AltStartup and machine XLSTART scopes -- the fixture goes in the user folder only;
              the machine folder is Program Files and AltStartup would need a real Options write
              Excel may discard.
      Steps 7 and 8 -- shipped Enabled = $false here (Word owns them).
      "Excel is open" skip branches of steps 5, 6 and 9 -- the harness refuses to start those
              breaks with Excel open rather than test the skip.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateExcel.ps1 and validate. Without it: break and report.
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
    Script Name  : Invoke-AutoRemediateExcel_BreakTest.ps1
    Version      : 1.0.1
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated), run as the interactive user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateExcel\

    1.0.1  ThirdPartyAddinConflictGated, ThirdPartyAddinConflict, DisabledItemGated and
           DisabledItem moved to the Invoke-AutoRemediateOfficeAddins.ps1 harness with the
           script's steps 3 and 4; ReenableDisabledItems is no longer passed to the child.
           Six breaks remain. Tracks script 1.0.3.
    1.0.0  Initial: ten breaks against script 1.0.1 (steps 3, 4, 5, 6, 9, 10).

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

$ScriptUnderTest   = 'Invoke-AutoRemediateExcel'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateExcel.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\ExcelErrors'
$C2RConfigPath     = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "DEXTestFramework.psm1 not found at $modulePath" }
Import-Module $modulePath -Force
if (-not (Test-Path -LiteralPath $RemediationScript)) { throw "Script under test not found at $RemediationScript" }

# -- Fixture ------------------------------------------------------------------
$FixtureAutoRecoverDir = 'DEXTest_AutoRecover_Excel'  # under AppData\Local\Microsoft\Office
$FixtureXlStartFile    = 'DEXTest_lab.csv'            # a CSV opens harmlessly if Excel starts while it is planted
$FixtureXlamName       = 'DEXTest_lab.xlam'           # never created: the OPENn registration must dangle
$FixtureCalcMode       = 2                            # anything but 1 or -4105

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
        if (Test-Path -LiteralPath (Join-Path $p 'EXCEL.EXE')) { return $p }
    }
    return $null
}
function Get-UserHive          { "Registry::HKEY_USERS\$(Get-LoggedOnUserSid)" }
function Get-AppKeyPath        { "$(Get-UserHive)\Software\Microsoft\Office\$(Get-OfficeVersion)\Excel" }   # versioned key: Options, Resiliency
function Get-OptionsPath       { "$(Get-AppKeyPath)\Options" }
function Get-XlStartPath       { Join-Path (Get-UserProfilePath) 'AppData\Roaming\Microsoft\Excel\XLSTART' }
function Get-FixtureXlamPath   { Join-Path (Get-UserProfilePath) "AppData\Roaming\Microsoft\AddIns\$FixtureXlamName" }
function Get-AutoRecoverFixturePath { Join-Path (Get-UserProfilePath) "AppData\Local\Microsoft\Office\$FixtureAutoRecoverDir" }

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
    # EXCEL.EXE 1000/1002 records in the last 7 days, counted the way step 2 counts them. Plain array.
    $ev = @()
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = @('Application Error', 'Application Hang'); Id = @(1000, 1002); StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue |
               Where-Object { $_.Properties.Count -gt 0 -and "$($_.Properties[0].Value)" -ieq 'EXCEL.EXE' })
    } catch { }
    return $ev
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
function Assert-ExcelClosed {
    param([string]$BreakName)
    if (Test-ProcessRunning 'EXCEL') { throw "EXCEL.EXE is running; the script skips this fix while Excel is open (it rewrites Options on exit) and this harness does not close the user's Excel. Close it and re-run -BreakName $BreakName." }
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

# -- Helpers: step 6 XLSTART ---------------------------------------------------------

function Get-RealXlStartFiles {
    # Everything step 6 would act on besides our fixture: user and machine XLSTART plus AltStartup, minus PERSONAL.XLSB. Plain string array.
    $dirs = @(Get-XlStartPath)
    $root = Get-C2RRoot
    if ($root) { $dirs += Join-Path $root 'XLSTART' }
    $alt = (Get-RegValueInfo -Path (Get-OptionsPath) -Name 'AltStartup').Value
    if ($alt) { $dirs += [Environment]::ExpandEnvironmentVariables("$alt") }
    $out = @()
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $out += @(Get-ChildItem -LiteralPath $d -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ine 'PERSONAL.XLSB' -and $_.Name -ne $FixtureXlStartFile } | ForEach-Object { $_.FullName })
    }
    return @($out)
}
function Get-QuarantineDirNames {
    $parent = Split-Path -Path (Get-XlStartPath) -Parent
    if (-not (Test-Path -LiteralPath $parent)) { return @() }
    return @(Get-ChildItem -LiteralPath $parent -Directory -Filter 'XLSTART_quarantine_*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}
function Get-NewQuarantineDirs { param($Original) @(Get-QuarantineDirNames | Where-Object { @($Original.ExistingQuarantine) -notcontains $_ } | ForEach-Object { Join-Path (Split-Path -Path (Get-XlStartPath) -Parent) $_ }) }
function Get-XlStartBaseline {
    $dir = Get-XlStartPath
    @{
        MissingDirs        = @(Get-MissingDirectories -Paths @((Split-Path -Path $dir -Parent), $dir))
        RealFiles          = @(Get-RealXlStartFiles)
        ExistingQuarantine = @(Get-QuarantineDirNames)
    }
}
function Install-XlStartFixture {
    $dir = Get-XlStartPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    Set-Content -LiteralPath (Join-Path $dir $FixtureXlStartFile) -Value 'DEXTest,planted by Invoke-AutoRemediateExcel_BreakTest.ps1,safe to delete' -Encoding ASCII -Force -ErrorAction Stop
}
function Test-XlStartFixturePlanted {
    $f = Join-Path (Get-XlStartPath) $FixtureXlStartFile
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "           $f missing"; return $false }
    return $true
}
function Restore-XlStartBaseline {
    param($Original)
    $f = Join-Path (Get-XlStartPath) $FixtureXlStartFile
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    foreach ($q in @(Get-NewQuarantineDirs -Original $Original)) {
        $qf = Join-Path $q $FixtureXlStartFile
        if (Test-Path -LiteralPath $qf) { Remove-Item -LiteralPath $qf -Force -ErrorAction Stop }
        if (Test-DirEmpty $q) { Remove-Item -LiteralPath $q -Force -ErrorAction Stop }
        else { throw "$q holds files the harness did not plant; left in place." }
    }
    Remove-MissingDirectories -Paths @($Original.MissingDirs)
}

# -- Helpers: step 9 OPENn registrations ------------------------------------------

function Get-OpenValues {
    # Every OPENn value in Options in the script's order: @{ Name; Value; Kind; Path; Exists }. Plain array.
    $opt = Get-OptionsPath
    if (-not (Test-Path -LiteralPath $opt)) { return @() }
    $key = Get-Item -LiteralPath $opt -ErrorAction SilentlyContinue
    $list = @()
    foreach ($n in @($key.GetValueNames() | Where-Object { $_ -match '^OPEN\d*$' } | Sort-Object { [int]('0' + ($_ -replace '^OPEN', '')) })) {
        $info = Get-RegValueInfo -Path $opt -Name $n
        $raw  = "$($info.Value)"
        $path = [Environment]::ExpandEnvironmentVariables((($raw -replace '^(\s*/\w+\s+)+', '').Trim().Trim('"')))
        $list += @{ Name = $n; Value = $raw; Kind = $info.Kind; Path = $path; Exists = [bool]($path -and (Test-Path -LiteralPath $path)) }
    }
    return @($list)
}
function Get-RealDanglingOpenValues { @(Get-OpenValues | Where-Object { -not $_.Exists -and $_.Path -ne (Get-FixtureXlamPath) }) }
function Get-FixtureOpenValues     { @(Get-OpenValues | Where-Object { $_.Path -eq (Get-FixtureXlamPath) }) }
function Get-NextOpenName {
    $names = @(Get-OpenValues | ForEach-Object { $_.Name })
    if ($names -notcontains 'OPEN') { return 'OPEN' }
    $i = 1; while ($names -contains "OPEN$i") { $i++ }
    return "OPEN$i"
}
function Get-OpenBaseline {
    @{
        OptionsExisted = (Test-Path -LiteralPath (Get-OptionsPath))
        OpenValues     = @(Get-OpenValues | ForEach-Object { @{ Name = $_.Name; Value = $_.Value; Kind = $_.Kind } })
    }
}
function Install-FixtureXlamRegistration {
    if (Test-Path -LiteralPath (Get-FixtureXlamPath)) { Remove-Item -LiteralPath (Get-FixtureXlamPath) -Force -ErrorAction Stop }
    Set-RegValue -Path (Get-OptionsPath) -Name (Get-NextOpenName) -Value "`"$(Get-FixtureXlamPath)`"" -Type String
}
function Test-FixtureXlamDangling {
    $fx = @(Get-FixtureOpenValues)
    if ($fx.Count -ne 1) { Write-Host "           expected one OPENn value pointing at $(Get-FixtureXlamPath), found $($fx.Count)"; return $false }
    if ($fx[0].Exists) { Write-Host "           $(Get-FixtureXlamPath) exists; the registration does not dangle"; return $false }
    return $true
}
function Restore-OpenBaseline {
    param($Original)
    $opt = Get-OptionsPath
    if (Test-Path -LiteralPath $opt) {
        foreach ($n in @((Get-Item -LiteralPath $opt).GetValueNames() | Where-Object { $_ -match '^OPEN\d*$' })) { Remove-ItemProperty -LiteralPath $opt -Name $n -ErrorAction SilentlyContinue }
    }
    foreach ($v in @($Original.OpenValues)) { Set-RegValueInfo -Path $opt -Name "$($v.Name)" -Info @{ Exists = $true; Value = $v.Value; Kind = $v.Kind } }
    if (-not [bool]$Original.OptionsExisted) { Remove-EmptyRegKey $opt }
}

# -- Fixture lifecycle ------------------------------------------------------------

function Initialize-Fixture {
    if (-not (Get-C2RConfig) -or -not (Get-C2RRoot)) { throw 'Click-to-Run configuration or EXCEL.EXE is absent; Invoke-AutoRemediateExcel.ps1 would exit 0 as Skipped.' }
    $user = Get-LoggedOnUser; $sid = Get-LoggedOnUserSid
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) { throw "Hive for $user ($sid) is not loaded under HKEY_USERS; the script's per-user steps would not see it." }
    Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Office $(Get-OfficeVersion) ($((Get-C2RConfig).VersionToReport)); user $user; real XLSTART files $(@(Get-RealXlStartFiles).Count); OPENn values $(@(Get-OpenValues).Count) (dangling $(@(Get-RealDanglingOpenValues).Count)); AutoRecover problems: $(@(Get-RealAutoRecoverProblems) -join ', '); EXCEL crash/hang 7d $(@(Get-AppCrashEvents).Count); EXCEL running: $(Test-ProcessRunning 'EXCEL')"
}
function Assert-RunSafe {
    # Refuses a run whose variables would make the script act on real state no break restores.
    param([hashtable]$RunEnv, [string[]]$Names)
    if ($RunEnv['AllowDestructiveActions'] -eq 'true') {
        $xl = @(Get-RealXlStartFiles)
        if ($xl.Count -gt 0) { throw "Real XLSTART content exists ($($xl -join '; ')); step 6 would quarantine it in an ungated run. Refusing." }
    }
    # Steps 5 and 9 fix unconditionally (with Excel closed); real problems there are changed by every run.
    if ($Names -notcontains 'XlamDanglingRegistration' -and @(Get-RealDanglingOpenValues).Count -gt 0) { throw "Real dangling OPENn registration(s) exist ($(@(Get-RealDanglingOpenValues | ForEach-Object { "$($_.Name)=$($_.Path)" }) -join ', ')); step 9 would remove them and nothing would put them back. Refusing." }
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
    try { $f = Join-Path (Get-XlStartPath) $FixtureXlStartFile; if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } } catch { }
    try { foreach ($v in @(Get-FixtureOpenValues)) { Remove-ItemProperty -LiteralPath (Get-OptionsPath) -Name $v.Name -ErrorAction SilentlyContinue } } catch { }
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
            Assert-ExcelClosed -BreakName 'AutoRecoverDisabled'
            Set-RegValue -Path (Get-OptionsPath) -Name 'AutoRecoverEnabled' -Value 0 -Type DWord
        } })
        Capture  = { Get-AutoRecoverBaseline }
        Verify   = {
            $v = (Get-RegValueInfo -Path (Get-OptionsPath) -Name 'AutoRecoverEnabled').Value
            if ("$v" -ne '0') { Write-Host "           AutoRecoverEnabled is '$v', expected 0" }
            ("$v" -eq '0') -and (-not (Test-ProcessRunning 'EXCEL'))
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
        Name = 'XlStartContentGated'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false
        Env = @{ AllowDestructiveActions = '' }; Excludes = @()
        Methods  = @(@{ Name = 'PlantXlStartFile'; Apply = { Install-XlStartFixture } })
        Capture  = { Get-XlStartBaseline }
        Verify   = { Test-XlStartFixturePlanted }
        # Step 6: "<n> file(s) open at every Excel launch: DEXTest_lab.csv (0KB) [user]. A corrupt one crashes Excel at start. Move to XLSTART_quarantine_<stamp> beside the folder -- set ..."
        Validate = {
            param($Original)
            $still = Test-XlStartFixturePlanted
            $q = @(Get-NewQuarantineDirs -Original $Original)
            if ($q.Count -gt 0) { Write-Host "           a quarantine folder was made during a gated run: $($q -join ', ')" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step06_' -Pattern "^\[Warning\] \d+ file\(s\) open at every Excel launch: .*$([regex]::Escape($FixtureXlStartFile)) \(\d+KB\) \[user\].*A corrupt one crashes Excel at start\. Move to XLSTART_quarantine_<stamp> beside the folder$GatedSuffix"
            $still -and ($q.Count -eq 0) -and $reported
        }
        Restore  = { param($Original) Restore-XlStartBaseline -Original $Original }
    },

    @{
        Name = 'XlStartContent'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false
        Env = @{ AllowDestructiveActions = 'true' }; Excludes = @()
        Methods  = @(@{ Name = 'PlantXlStartFile'; Apply = {
            Assert-ExcelClosed -BreakName 'XlStartContent'
            $real = @(Get-RealXlStartFiles)
            if ($real.Count -gt 0) { throw "Real startup content exists ($($real -join '; ')); the script quarantines every file but PERSONAL.XLSB. Run XlStartContentGated instead." }
            Install-XlStartFixture
        } })
        Capture  = { Get-XlStartBaseline }
        Verify   = { (Test-XlStartFixturePlanted) -and (-not (Test-ProcessRunning 'EXCEL')) }
        # Resolution: "Moved 1 startup file(s) to <...>\Excel\XLSTART_quarantine_<stamp>. Excel launches clean; restore from there if one was wanted."
        Validate = {
            param($Original)
            $gone = -not (Test-Path -LiteralPath (Join-Path (Get-XlStartPath) $FixtureXlStartFile))
            if (-not $gone) { Write-Host '           fixture still in XLSTART; it was not moved' }
            $q = @(Get-NewQuarantineDirs -Original $Original)
            $oneQ = ($q.Count -eq 1) -and ((Split-Path -Path $q[0] -Leaf) -match '^XLSTART_quarantine_\d{8}-\d{6}$') -and (Test-Path -LiteralPath (Join-Path $q[0] $FixtureXlStartFile))
            if (-not $oneQ) { Write-Host "           expected exactly one XLSTART_quarantine_<stamp> holding the fixture, found: $(if ($q.Count) { $q -join ', ' } else { 'none' })" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step06_' -Pattern "^\[Remediated\] Moved 1 startup file\(s\) to $([regex]::Escape((Split-Path -Path (Get-XlStartPath) -Parent)))\\XLSTART_quarantine_\d{8}-\d{6}\. Excel launches clean; restore from there if one was wanted\.$"
            $gone -and $oneQ -and $reported
        }
        Restore  = { param($Original) Restore-XlStartBaseline -Original $Original }
    },

    @{
        Name = 'XlamDanglingRegistration'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false
        Env = @{}; Excludes = @()
        Methods  = @(@{ Name = 'RegisterMissingXlam'; Apply = {
            Assert-ExcelClosed -BreakName 'XlamDanglingRegistration'
            $real = @(Get-RealDanglingOpenValues)
            if ($real.Count -gt 0) { throw "Real dangling OPENn registration(s) exist ($(@($real | ForEach-Object { "$($_.Name)=$($_.Path)" }) -join ', ')); the script would remove them too. Fix or remove them first." }
            Install-FixtureXlamRegistration
        } })
        Capture  = { Get-OpenBaseline }
        Verify   = { (Test-FixtureXlamDangling) -and (-not (Test-ProcessRunning 'EXCEL')) }
        # Resolution: "Removed 1 dangling registration(s); none kept." | "1 kept as OPEN" | "<n> kept, renumbered OPEN..OPEN<n-1>"
        Validate = {
            param($Original)
            $removed = (@(Get-FixtureOpenValues).Count -eq 0)
            if (-not $removed) { Write-Host '           an OPENn value still points at the fixture .xlam' }
            $now  = @(Get-OpenValues)
            $kept = @($Original.OpenValues)
            $allKept = $true
            foreach ($k in $kept) {
                if (@($now | Where-Object { $_.Value -eq "$($k.Value)" }).Count -eq 0) { $allKept = $false; Write-Host "           real registration '$($k.Value)' is gone" }
            }
            $expectedNames = @(for ($i = 0; $i -lt $kept.Count; $i++) { if ($i -eq 0) { 'OPEN' } else { "OPEN$i" } })
            $contiguous = ((@($now | ForEach-Object { $_.Name }) -join ',') -eq ($expectedNames -join ','))
            if (-not $contiguous) { Write-Host "           OPENn names are $(@($now | ForEach-Object { $_.Name }) -join ','); expected $($expectedNames -join ',')" }
            $keptText = switch ($kept.Count) { 0 { 'none kept' } 1 { '1 kept as OPEN' } default { "$($kept.Count) kept, renumbered OPEN..OPEN$($kept.Count - 1)" } }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step09_' -Pattern "^\[Remediated\] Removed 1 dangling registration\(s\); $([regex]::Escape($keptText))\.$"
            $removed -and $allKept -and $contiguous -and $reported
        }
        Restore  = { param($Original) Restore-OpenBaseline -Original $Original }
    },

    @{
        Name = 'CalcModeManual'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false
        Env = @{}; Excludes = @()
        Methods  = @(@{ Name = 'SetDefaultCalcMode'; Apply = { Set-RegValue -Path (Get-OptionsPath) -Name 'DefaultCalcMode' -Value $FixtureCalcMode -Type DWord } })
        Capture  = { @{ OptionsExisted = (Test-Path -LiteralPath (Get-OptionsPath)); CalcMode = (Get-RegValueInfo -Path (Get-OptionsPath) -Name 'DefaultCalcMode') } }
        Verify   = {
            $v = (Get-RegValueInfo -Path (Get-OptionsPath) -Name 'DefaultCalcMode').Value
            if ("$v" -ne "$FixtureCalcMode") { Write-Host "           DefaultCalcMode is '$v', expected $FixtureCalcMode" }
            ("$v" -eq "$FixtureCalcMode")
        }
        # Step 10: "DefaultCalcMode=2 is not automatic. Formulas will not update until F9; report only, manual calculation is often deliberate on large models."
        Validate = {
            $v = (Get-RegValueInfo -Path (Get-OptionsPath) -Name 'DefaultCalcMode').Value
            if ("$v" -ne "$FixtureCalcMode") { Write-Host "           DefaultCalcMode changed to '$v' during a report-only step" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step10_' -Pattern "^\[Warning\] DefaultCalcMode=$FixtureCalcMode is not automatic\. Formulas will not update until F9; report only, manual calculation is often deliberate on large models\.$"
            ("$v" -eq "$FixtureCalcMode") -and $reported
        }
        Restore  = {
            param($Original)
            Set-RegValueInfo -Path (Get-OptionsPath) -Name 'DefaultCalcMode' -Info $Original.CalcMode
            if (-not [bool]$Original.OptionsExisted) { Remove-EmptyRegKey (Get-OptionsPath) }
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

Write-DexBanner -Title 'Invoke-AutoRemediateExcel_BreakTest' -Detail "Environment: $Environment"

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
