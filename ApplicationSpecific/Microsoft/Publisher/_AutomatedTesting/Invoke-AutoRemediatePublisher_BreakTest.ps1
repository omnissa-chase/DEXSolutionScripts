<#
.SYNOPSIS
    Invoke-AutoRemediatePublisher_BreakTest -- deliberately plants Publisher faults, then
    verifies Invoke-AutoRemediatePublisher.ps1 reports or repairs them as documented.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediatePublisher\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It writes AutoRecover values into the
    logged-on user's Publisher hive. Run it only on a disposable VM or a marked test host.
    See Assert-DexTestHost in DEXTestFramework.psm1.

    WHAT IS BROKEN AND HOW IT COMES BACK
    Invoke-AutoRemediatePublisher.ps1 resolves the logged-on user from
    Win32_ComputerSystem.UserName and reads that user's hive through HKEY_USERS\<SID>, so
    this harness does the same; run elevated as the interactive user the hive is the
    harness user's own. Every planted artefact carries the DEXTest prefix. Every break
    Captures what it is about to change (which registry keys and folders it had to
    create, the user's AutoRecoverPath and AutoRecoverEnabled values and kinds) and
    Restore writes that back, removing keys and folders only when the harness created
    them and they are empty afterwards.

    GATES
    No break here is gated: step 5 (AutoRecover) has ResolveOnWarning $true in the script.
    The gated add-in steps (3 COM Add-in Conflict, 4 Office-Disabled Items) moved to
    ApplicationSpecific\Microsoft\Office\Invoke-AutoRemediateOfficeAddins.ps1, and their
    four breaks moved to that script's harness. The DestructiveFlag plumbing stays so the
    harness matches the rest of the family; no remaining break sets AllowDestructiveActions.

    EXPECTED OUTCOMES (derived from the script's own messages, 1.0.3)
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    AutoRecoverPathMissing        ExpectFixed. ...\Publisher\Options\AutoRecoverPath =
                                  C:\Temp\DEXTest\Publisher\AutoRecover (REG_SZ, folder absent).
                                  Validate: the folder now exists; Step05_AutoRecoverSettings
                                  reads "[Remediated] AutoRecover: created
                                  C:\Temp\DEXTest\Publisher\AutoRecover." (a "; set
                                  AutoRecoverEnabled=1" clause is tolerated when
                                  AutoRecoverDisabled shares the run).
    AutoRecoverDisabled           ExpectFixed. AutoRecoverEnabled = 0 (REG_DWORD). Needs
                                  MSPUB.EXE closed (Publisher rewrites Options on exit, so the
                                  script leaves 0 alone while it runs; the harness never kills
                                  it). Validate: AutoRecoverEnabled is 1; record reads
                                  "[Remediated] AutoRecover: ...set AutoRecoverEnabled=1."

    NOT COVERED
      Step 2 Crash and Hang History -- needs MSPUB.EXE 1000/1002 events in the Application
             log; planting real crash events is out of bounds.
      Steps 3 and 4 (COM Add-in Conflict, Office-Disabled Items) -- moved to
             Invoke-AutoRemediateOfficeAddins.ps1; its own harness carries those breaks.
      Step 5 'Publisher is open' refusal -- derivable from AutoRecoverDisabled with
             Publisher running (Verify refuses instead of launching it).
      Step 7 Office Document Cache -- Enabled = $false in this script (Word owns it); a
             bloated OfficeFileCache is never read here.
      Step 8 Office C2R Update Health -- Enabled = $false in this script (Word owns it).
      No-user branches ($_noUser) -- need a session with nobody logged on.

    REBOOTS
    No break in this catalog requires a reboot. The reboot plumbing is kept so the
    harness stays uniform with the rest of the family.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediatePublisher.ps1 and validate the outcome.
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
    Script Name  : Invoke-AutoRemediatePublisher_BreakTest.ps1
    Version      : 1.0.1
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated), run as the interactive user
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediatePublisher\

    1.0.1  ThirdPartyAddinConflictGated, ThirdPartyAddinConflict, DisabledItemGated and
           DisabledItem moved to the Invoke-AutoRemediateOfficeAddins.ps1 harness with the
           script's steps 3 and 4; ReenableDisabledItems is no longer passed to the child.
           Two breaks remain. Tracks script 1.0.3.
    1.0.0  Initial: add-in gated/ungated, Resiliency gated/ungated, AutoRecoverPathMissing,
           AutoRecoverDisabled. Tracks script 1.0.1.

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

$ScriptUnderTest   = 'Invoke-AutoRemediatePublisher'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediatePublisher.ps1'
$AppName           = 'Publisher'
$AppExe            = 'MSPUB.EXE'
$AppProcess        = 'MSPUB'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\PublisherErrors'
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
$FixtureAutoRecoverDir  = 'C:\Temp\DEXTest\Publisher\AutoRecover'


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
    $arPath     = Get-OptionValue -Name 'AutoRecoverPath'
    $arOn       = Get-OptionValue -Name 'AutoRecoverEnabled'
    Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Office $(Get-OfficeVersion) ($((Get-C2RConfig).VersionToReport)); user $user; Options key: $(Test-Path -LiteralPath (Get-OptionsKeyPath)); AutoRecoverPath '$arPath'; AutoRecoverEnabled '$arOn'; $AppExe running: $(Test-AppRunning)"
}

function Remove-Fixture {
    # Sweep by prefix; the per-break Restore blocks have normally done all of this already.
    try {
        # Only if the value still points at our folder; a restored real path is left alone.
        $p = Get-OptionValue -Name 'AutoRecoverPath'
        if ("$p" -eq $FixtureAutoRecoverDir) { Remove-ItemProperty -LiteralPath (Get-OptionsKeyPath) -Name 'AutoRecoverPath' -ErrorAction SilentlyContinue }
        Remove-MissingDirectories -Paths @('C:\Temp\DEXTest', 'C:\Temp\DEXTest\Publisher', $FixtureAutoRecoverDir)
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
function Get-OptionsKeyPath       { "$(Get-UserAppKeyPath)\Options" }

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

# -- Helpers: AutoRecover options (step 5) ----------------------------------------

function Get-OptionValue {
    # Raw value or $null when the key or value is absent.
    param([Parameter(Mandatory = $true)][string]$Name)
    $k = Get-OptionsKeyPath
    if (-not (Test-Path -LiteralPath $k)) { return $null }
    $item = Get-Item -LiteralPath $k -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    if (@($item.GetValueNames()) -notcontains $Name) { return $null }
    return $item.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Get-OptionValueKind {
    param([Parameter(Mandatory = $true)][string]$Name)
    $k = Get-OptionsKeyPath
    if (-not (Test-Path -LiteralPath $k)) { return $null }
    $item = Get-Item -LiteralPath $k -ErrorAction SilentlyContinue
    if (-not $item -or @($item.GetValueNames()) -notcontains $Name) { return $null }
    return "$($item.GetValueKind($Name))"
}

function Set-OptionValue {
    # $null removes the value; otherwise writes it with the given kind (String, ExpandString, DWord).
    param([Parameter(Mandatory = $true)][string]$Name, $Value, [string]$Kind = 'String')
    $k = Get-OptionsKeyPath
    if ($null -eq $Value) {
        if (Test-Path -LiteralPath $k) { Remove-ItemProperty -LiteralPath $k -Name $Name -ErrorAction SilentlyContinue }
        return
    }
    New-RegistryKeyChain -Path $k
    switch ($Kind) {
        'DWord'        { Set-ItemProperty -LiteralPath $k -Name $Name -Value ([int]$Value) -Type DWord -ErrorAction Stop }
        'ExpandString' { Set-ItemProperty -LiteralPath $k -Name $Name -Value "$Value" -Type ExpandString -ErrorAction Stop }
        default        { Set-ItemProperty -LiteralPath $k -Name $Name -Value "$Value" -Type String -ErrorAction Stop }
    }
}

function Get-AutoRecoverBaseline {
    # Both values are captured by both AutoRecover breaks: the script may change either
    # (a missing path makes it create the folder; a real AutoRecoverEnabled=0 makes it flip
    # the user's own setting to 1), and Restore puts the user's values back.
    @{
        MissingKeys  = @(Get-MissingRegistryKeys -Paths @((Get-UserAppKeyPath), (Get-OptionsKeyPath)))
        MissingDirs  = @(Get-MissingDirectories -Paths @('C:\Temp', 'C:\Temp\DEXTest', 'C:\Temp\DEXTest\Publisher', $FixtureAutoRecoverDir))
        PathValue    = Get-OptionValue -Name 'AutoRecoverPath'
        PathKind     = Get-OptionValueKind -Name 'AutoRecoverPath'
        EnabledValue = Get-OptionValue -Name 'AutoRecoverEnabled'
        EnabledKind  = Get-OptionValueKind -Name 'AutoRecoverEnabled'
    }
}

function Restore-AutoRecoverBaseline {
    param($Original)
    $pk = if ($Original.PathKind)    { "$($Original.PathKind)" }    else { 'String' }
    $ek = if ($Original.EnabledKind) { "$($Original.EnabledKind)" } else { 'DWord' }
    Set-OptionValue -Name 'AutoRecoverPath'    -Value $Original.PathValue    -Kind $pk
    Set-OptionValue -Name 'AutoRecoverEnabled' -Value $Original.EnabledValue -Kind $ek
    Remove-MissingRegistryKeys -Paths @($Original.MissingKeys | Where-Object { $_ })
    if (Test-Path -LiteralPath $FixtureAutoRecoverDir) {
        # The script creates it empty; anything inside would be Publisher's own recovery files.
        if (@(Get-ChildItem -LiteralPath $FixtureAutoRecoverDir -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            throw "$FixtureAutoRecoverDir is not empty; not deleting it."
        }
        Remove-Item -LiteralPath $FixtureAutoRecoverDir -Force -ErrorAction Stop
    }
    Remove-MissingDirectories -Paths @($Original.MissingDirs | Where-Object { $_ })
}

# -- Helpers: running the script under test --------------------------------------

function Get-RemediationVariables {
    $vars = @{
        AllowDestructiveActions = if ([bool]$state.DestructiveFlag) { 'true' } else { $null }
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
# DestructiveFlag: $true -- the run sets the variable to 'true'; $false -- unset; $null -- either.
# Group: breaks sharing a fixture; only the first drawn of a group runs.
$BreakCatalog = @(

    @{
        Name            = 'AutoRecoverPathMissing'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        DestructiveFlag = $null
        Group           = $null
        Methods         = @(@{
            Name  = 'PointAutoRecoverAtMissingFolder'
            Apply = {
                if (Test-Path -LiteralPath $FixtureAutoRecoverDir) { Remove-Item -LiteralPath $FixtureAutoRecoverDir -Recurse -Force -ErrorAction Stop }
                Set-OptionValue -Name 'AutoRecoverPath' -Value $FixtureAutoRecoverDir -Kind 'String'
            }
        })
        Capture  = { Get-AutoRecoverBaseline }
        Verify   = {
            $v = "$(Get-OptionValue -Name 'AutoRecoverPath')"
            $set = ($v -eq $FixtureAutoRecoverDir)
            if (-not $set) { Write-Host "           AutoRecoverPath is '$v', expected '$FixtureAutoRecoverDir'" }
            $missing = -not (Test-Path -LiteralPath $FixtureAutoRecoverDir)
            if (-not $missing) { Write-Host "           $FixtureAutoRecoverDir already exists" }
            return ($set -and $missing)
        }
        Validate = {
            $created = Test-Path -LiteralPath $FixtureAutoRecoverDir -PathType Container
            if (-not $created) { Write-Host "           $FixtureAutoRecoverDir was not created" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step05_' -Pattern "^\[Remediated\] .*created $([regex]::Escape($FixtureAutoRecoverDir))"
            return ($created -and $reported)
        }
        Restore  = { param($Original) Restore-AutoRecoverBaseline -Original $Original }
    },

    @{
        Name            = 'AutoRecoverDisabled'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        DestructiveFlag = $null
        Group           = $null
        Methods         = @(@{
            Name  = 'SetAutoRecoverEnabledZero'
            Apply = { Set-OptionValue -Name 'AutoRecoverEnabled' -Value 0 -Kind 'DWord' }
        })
        Capture  = { Get-AutoRecoverBaseline }
        Verify   = {
            $v = Get-OptionValue -Name 'AutoRecoverEnabled'
            $off = ($null -ne $v) -and ([int]$v -eq 0)
            if (-not $off) { Write-Host "           AutoRecoverEnabled is '$v', expected 0" }
            $closed = -not (Test-AppRunning)
            if (-not $closed) { Write-Host "           $AppExe is running; the script leaves AutoRecoverEnabled=0 while $AppName is open. Close $AppName and re-run (the harness never kills it)." }
            return ($off -and $closed)
        }
        Validate = {
            $v = Get-OptionValue -Name 'AutoRecoverEnabled'
            $on = ($null -ne $v) -and ([int]$v -eq 1)
            if (-not $on) { Write-Host "           AutoRecoverEnabled is '$v' after the run; expected 1" }
            $reported = Test-DexRecordMatches -ValueNamePrefix 'Step05_' -Pattern '^\[Remediated\] AutoRecover: .*set AutoRecoverEnabled=1\.$'
            return ($on -and $reported)
        }
        Restore  = { param($Original) Restore-AutoRecoverBaseline -Original $Original }
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
        foreach ($flag in @(@{ Field = 'DestructiveFlag'; Env = 'AllowDestructiveActions' })) {
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
