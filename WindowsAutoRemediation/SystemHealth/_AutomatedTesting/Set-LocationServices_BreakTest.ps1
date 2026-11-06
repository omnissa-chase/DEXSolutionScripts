<#
.SYNOPSIS
    Set-LocationServices_BreakTest -- puts the device and user location consent values
    into a known starting state, runs Set-LocationServices.ps1 with a given set of
    script variables, and verifies the values it leaves behind.

.DESCRIPTION
    Set-LocationServices.ps1 is an action script driven by script variables, not a
    detector, so each catalog entry is a scenario: a starting state, the variables for
    the run, and the end state the run must produce. Scenarios contradict each other
    (one expects Allow where the next expects Deny), so every scenario is its own
    cycle: snapshot -> apply -> verify -> run -> validate -> restore. The next scenario
    starts from the restored baseline. Writes the uniform JSON result to
    C:\Temp\FixReport\Set-LocationServices\ for Invoke-FixReportAnalysis.ps1.

    THIS SCRIPT CHANGES THE LIVE LOCATION SETTINGS of the device and of every loaded
    user hive, and plants DEXTest.* app entries under each user's location key. Every
    value is captured before a scenario and put back after it. Run it only on a
    disposable VM or a marked test host. See Assert-DexTestHost in DEXTestFramework.psm1.

    REGISTRY (all under ...\CapabilityAccessManager\ConsentStore\location)
      HKLM Value                       device switch
      HKU\<SID> Value                  user switch
      HKU\<SID>\NonPackaged Value      desktop (Win32) apps
      HKU\<SID>\<PackageFamilyName>    one entry per modern app: Allow | Deny | Prompt

    SCENARIOS (ExpectedOutcome: ExpectFixed = the run must change the values;
    ExpectReportedOnly = the run must leave them alone)
      DeviceOffEnable    device and user Deny; LocationServices=Enable -> all Allow,
                         app entries untouched, lfsvc not Disabled
      DeviceOnDisable    device and user Allow; LocationServices=Disable -> all Deny,
                         app entries untouched
      ModernAppsDenied   two fixture apps Allow; Enable + ModernApps=Deny -> every app
                         entry Deny, desktop apps Allow
      AllowListOnly      fixture Allowed=Deny, Denied=Allow, New absent; Enable +
                         DesktopApps=Deny + ModernApps=<Allowed*;New> -> Allowed and
                         New (created) Allow, every other app Deny, desktop apps Deny
      KeepPerApp         fixture Prompt, desktop apps Allow; Disable + DesktopApps=Keep
                         -> device and user Deny, fixture still Prompt, desktop still Allow
      WhatIfNoChange     device and user Deny; Enable + WhatIf=true -> nothing changes,
                         output carries "(WhatIf)", exit 0

    Fixture app entries are DEXTest.LocationAllowed_0000000000000,
    DEXTest.LocationDenied_0000000000000 and DEXTest.LocationNew_0000000000000. They are
    removed on restore. Nothing that Windows or a real app wrote is ever deleted.

    REBOOTS
    Nothing here needs a reboot and there is no resume plumbing.

.PARAMETER RemediationTest
    After applying a scenario's starting state, run Set-LocationServices.ps1 and
    validate the end state. Without this the harness applies, verifies and restores.

.PARAMETER Environment
    Physical (default) restores after every scenario. Snapshot skips restore.

.PARAMETER Seed
    Replays an earlier run's scenario selection order. Recorded in the result.

.PARAMETER BreakName
    Force specific scenarios instead of a random selection.

.PARAMETER BreakCount
    How many scenarios to run when selecting randomly. Default 6 (all).

.PARAMETER Restore
    Undo an interrupted run's scenario from state.json and exit.

.PARAMETER Force
    Required acknowledgement that this machine's location settings will be changed.

.NOTES
    Script Name  : Set-LocationServices_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-06
    Reporting    : C:\Temp\FixReport\Set-LocationServices\

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
    [int]$BreakCount = 6,
    [switch]$IncludeRebootBreaks,
    [switch]$Restore,
    [switch]$Resume,
    [switch]$Force,
    [string[]]$ProductionDomainDenyList = @()
)

$ErrorActionPreference = 'Stop'

$ScriptUnderTest   = 'Set-LocationServices'
$RemediationScript = Join-Path $PSScriptRoot '..\Set-LocationServices.ps1'
$ConsentSubPath    = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
$DeviceKey         = "HKLM:\$ConsentSubPath"
$VariableNames     = @('LocationServices', 'DesktopApps', 'ModernApps', 'WhatIf')

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Fixture ------------------------------------------------------------------
$FixAllowed = 'DEXTest.LocationAllowed_0000000000000'
$FixDenied  = 'DEXTest.LocationDenied_0000000000000'
$FixNew     = 'DEXTest.LocationNew_0000000000000'

# -- Helpers ------------------------------------------------------------------

function Write-DexNote {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Message = '')
    Write-Host "  [Info   ] $Name$(if ($Message) { ": $Message" })" -ForegroundColor Gray
}

function Get-DexUserKeys {
    # Same selection as the script under test: every loaded local, domain or Entra ID hive.
    @(Get-ChildItem -Path 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)-[\d-]+$' } |
        ForEach-Object { "Registry::HKEY_USERS\$($_.PSChildName)\$ConsentSubPath" })
}

function Get-DexValue {
    param([Parameter(Mandatory = $true)][string]$Path)
    $k = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $k) { return $null }
    return $k.GetValue('Value', $null)
}

function Set-DexValue {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Value)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name Value -PropertyType String -Value $Value -Force -ErrorAction Stop | Out-Null
}

function Get-DexAppNames {
    param([Parameter(Mandatory = $true)][string]$UserKey)
    @(Get-ChildItem -LiteralPath $UserKey -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -ne 'NonPackaged' } | ForEach-Object { $_.PSChildName })
}

function Remove-Fixture {
    foreach ($u in (Get-DexUserKeys)) {
        foreach ($n in @($FixAllowed, $FixDenied, $FixNew)) {
            if (Test-Path -LiteralPath "$u\$n") { Remove-Item -LiteralPath "$u\$n" -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

function New-DexSnapshot {
    # Every consent value the script under test can touch: the device switch, and per
    # loaded user the user switch, the desktop switch and every app entry (with its
    # existence, so an entry the run created can be told from one it changed).
    $entries = @()
    $entries += @{ Path = $DeviceKey; Kind = 'Device'; Existed = (Test-Path -LiteralPath $DeviceKey); Value = Get-DexValue -Path $DeviceKey }
    foreach ($u in (Get-DexUserKeys)) {
        $entries += @{ Path = $u; Kind = 'User'; Existed = (Test-Path -LiteralPath $u); Value = Get-DexValue -Path $u }
        $np = "$u\NonPackaged"
        $entries += @{ Path = $np; Kind = 'Desktop'; Existed = (Test-Path -LiteralPath $np); Value = Get-DexValue -Path $np }
        foreach ($a in (Get-DexAppNames -UserKey $u)) {
            $entries += @{ Path = "$u\$a"; Kind = 'App'; Existed = $true; Value = Get-DexValue -Path "$u\$a" }
        }
    }
    return @{ Entries = $entries }
}

function Restore-DexSnapshot {
    # $Original is a hashtable in-process or a PSCustomObject after a JSON round trip;
    # property access works on both.
    param($Original)
    foreach ($e in @($Original.Entries)) {
        if (-not $e.Existed) {
            # Only fixture entries are ever created by a scenario or by the run under test.
            if ($e.Kind -eq 'App' -and $e.Path -like '*\DEXTest.*' -and (Test-Path -LiteralPath $e.Path)) {
                Remove-Item -LiteralPath $e.Path -Recurse -Force -ErrorAction SilentlyContinue
            }
            continue
        }
        if ($null -eq $e.Value) {
            if (Test-Path -LiteralPath $e.Path) {
                Remove-ItemProperty -LiteralPath $e.Path -Name Value -Force -ErrorAction SilentlyContinue
            }
        } else {
            Set-DexValue -Path $e.Path -Value ([string]$e.Value)
        }
    }
}

function Test-DexEveryUser {
    # Runs $Check with the user key as $args[0] for every loaded hive; true only if all pass.
    param([Parameter(Mandatory = $true)][scriptblock]$Check, [string]$Label)
    $users = Get-DexUserKeys
    if ($users.Count -eq 0) { Write-DexNote -Name $Label -Message 'no user hives loaded'; return $false }
    $ok = $true
    foreach ($u in $users) {
        $r = [bool](& $Check $u)
        if (-not $r) { $ok = $false; Write-DexNote -Name $Label -Message "failed for $($u.Split('\')[2])" }
    }
    return $ok
}

function Test-DexAppsUntouched {
    # Every app entry that existed at snapshot still holds its snapshot value.
    param($Original)
    $ok = $true
    foreach ($e in @($Original.Entries)) {
        if ($e.Kind -ne 'App') { continue }
        $now = Get-DexValue -Path $e.Path
        if ([string]$now -ne [string]$e.Value) { $ok = $false; Write-DexNote -Name 'AppsUntouched' -Message "$($e.Path.Split('\')[-1]) '$($e.Value)' -> '$now'" }
    }
    return $ok
}

function Test-DexAllApps {
    # Every app entry under every user (fixture included) holds $Value, except names
    # matching any of $Except, which must hold $ExceptValue.
    param([string]$Value, [string[]]$Except = @(), [string]$ExceptValue = '')
    Test-DexEveryUser -Label 'AllApps' -Check {
        param($u)
        $ok = $true
        foreach ($a in (Get-DexAppNames -UserKey $u)) {
            $want = $Value
            foreach ($x in $Except) { if ($a -like $x) { $want = $ExceptValue; break } }
            $now = [string](Get-DexValue -Path "$u\$a")
            if ($now -ne $want) { $ok = $false; Write-DexNote -Name 'AllApps' -Message "$a is '$now', wanted '$want'" }
        }
        $ok
    }
}

function Test-DexRunOk {
    param([int]$ExpectedExit = 0)
    $r = $script:currentRun
    if (-not $r) { return $false }
    $ok = ([int]$r.ExitCode -eq $ExpectedExit)
    if (-not $ok) { Write-DexNote -Name 'Run' -Message "exit $($r.ExitCode), expected $ExpectedExit" }
    return $ok
}

# -- Scenario definitions ------------------------------------------------------
# Apply sets the starting state; Verify proves it landed; Validate reads the end state.
# Capture and Restore are the shared snapshot for every scenario.
$BreakCatalog = @(

    @{
        Name            = 'DeviceOffEnable'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Variables       = @{ LocationServices = 'Enable' }
        Methods         = @(@{ Name = 'DeviceAndUserDeny'; Apply = {
            Set-DexValue -Path $DeviceKey -Value 'Deny'
            foreach ($u in (Get-DexUserKeys)) { Set-DexValue -Path $u -Value 'Deny'; Set-DexValue -Path "$u\NonPackaged" -Value 'Deny' }
        } })
        Verify   = {
            $d = Get-DexValue -Path $DeviceKey
            Write-DexNote -Name 'Verify DeviceOffEnable' -Message "device=$d"
            ($d -eq 'Deny') -and (Test-DexEveryUser -Label 'UserDeny' -Check { param($u) (Get-DexValue -Path $u) -eq 'Deny' })
        }
        Validate = {
            param($Original)
            $d   = Get-DexValue -Path $DeviceKey
            $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='lfsvc'" -ErrorAction SilentlyContinue
            $svcOk = (-not $svc) -or ($svc.StartMode -ne 'Disabled')
            $users = Test-DexEveryUser -Label 'UserAllow' -Check { param($u) ((Get-DexValue -Path $u) -eq 'Allow') -and ((Get-DexValue -Path "$u\NonPackaged") -eq 'Allow') }
            $apps  = Test-DexAppsUntouched -Original $Original
            Write-DexNote -Name 'Validate DeviceOffEnable' -Message "device=$d users=$users appsUntouched=$apps lfsvcOk=$svcOk"
            ($d -eq 'Allow') -and $users -and $apps -and $svcOk -and (Test-DexRunOk)
        }
    },

    @{
        Name            = 'DeviceOnDisable'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Variables       = @{ LocationServices = 'Disable' }
        Methods         = @(@{ Name = 'DeviceAndUserAllow'; Apply = {
            Set-DexValue -Path $DeviceKey -Value 'Allow'
            foreach ($u in (Get-DexUserKeys)) { Set-DexValue -Path $u -Value 'Allow'; Set-DexValue -Path "$u\NonPackaged" -Value 'Allow' }
        } })
        Verify   = {
            $d = Get-DexValue -Path $DeviceKey
            Write-DexNote -Name 'Verify DeviceOnDisable' -Message "device=$d"
            ($d -eq 'Allow') -and (Test-DexEveryUser -Label 'UserAllow' -Check { param($u) (Get-DexValue -Path $u) -eq 'Allow' })
        }
        Validate = {
            param($Original)
            $d     = Get-DexValue -Path $DeviceKey
            $users = Test-DexEveryUser -Label 'UserDeny' -Check { param($u) ((Get-DexValue -Path $u) -eq 'Deny') -and ((Get-DexValue -Path "$u\NonPackaged") -eq 'Deny') }
            $apps  = Test-DexAppsUntouched -Original $Original
            Write-DexNote -Name 'Validate DeviceOnDisable' -Message "device=$d users=$users appsUntouched=$apps"
            ($d -eq 'Deny') -and $users -and $apps -and (Test-DexRunOk)
        }
    },

    @{
        Name            = 'ModernAppsDenied'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Variables       = @{ LocationServices = 'Enable'; ModernApps = 'Deny' }
        Methods         = @(@{ Name = 'FixtureAppsAllow'; Apply = {
            Set-DexValue -Path $DeviceKey -Value 'Allow'
            foreach ($u in (Get-DexUserKeys)) { Set-DexValue -Path "$u\$FixAllowed" -Value 'Allow'; Set-DexValue -Path "$u\$FixDenied" -Value 'Allow' }
        } })
        Verify   = {
            $ok = Test-DexEveryUser -Label 'FixtureAllow' -Check { param($u) ((Get-DexValue -Path "$u\$FixAllowed") -eq 'Allow') -and ((Get-DexValue -Path "$u\$FixDenied") -eq 'Allow') }
            Write-DexNote -Name 'Verify ModernAppsDenied' -Message "fixtureAllow=$ok"
            $ok
        }
        Validate = {
            param($Original)
            $apps    = Test-DexAllApps -Value 'Deny'
            $desktop = Test-DexEveryUser -Label 'DesktopAllow' -Check { param($u) (Get-DexValue -Path "$u\NonPackaged") -eq 'Allow' }
            Write-DexNote -Name 'Validate ModernAppsDenied' -Message "allAppsDeny=$apps desktopAllow=$desktop"
            $apps -and $desktop -and (Test-DexRunOk)
        }
    },

    @{
        Name            = 'AllowListOnly'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Variables       = @{ LocationServices = 'Enable'; DesktopApps = 'Deny'; ModernApps = "DEXTest.LocationAllowed*;$FixNew" }
        Methods         = @(@{ Name = 'FixtureInverted'; Apply = {
            Set-DexValue -Path $DeviceKey -Value 'Deny'
            foreach ($u in (Get-DexUserKeys)) {
                Set-DexValue -Path "$u\$FixAllowed" -Value 'Deny'
                Set-DexValue -Path "$u\$FixDenied"  -Value 'Allow'
                if (Test-Path -LiteralPath "$u\$FixNew") { Remove-Item -LiteralPath "$u\$FixNew" -Recurse -Force }
            }
        } })
        Verify   = {
            $ok = Test-DexEveryUser -Label 'FixtureInverted' -Check { param($u)
                ((Get-DexValue -Path "$u\$FixAllowed") -eq 'Deny') -and ((Get-DexValue -Path "$u\$FixDenied") -eq 'Allow') -and (-not (Test-Path -LiteralPath "$u\$FixNew")) }
            Write-DexNote -Name 'Verify AllowListOnly' -Message "fixtureInverted=$ok device=$(Get-DexValue -Path $DeviceKey)"
            $ok -and ((Get-DexValue -Path $DeviceKey) -eq 'Deny')
        }
        Validate = {
            param($Original)
            $d       = Get-DexValue -Path $DeviceKey
            $apps    = Test-DexAllApps -Value 'Deny' -Except @('DEXTest.LocationAllowed*', $FixNew) -ExceptValue 'Allow'
            $new     = Test-DexEveryUser -Label 'NewCreated' -Check { param($u) (Get-DexValue -Path "$u\$FixNew") -eq 'Allow' }
            $desktop = Test-DexEveryUser -Label 'DesktopDeny' -Check { param($u) (Get-DexValue -Path "$u\NonPackaged") -eq 'Deny' }
            Write-DexNote -Name 'Validate AllowListOnly' -Message "device=$d listApplied=$apps newCreated=$new desktopDeny=$desktop"
            ($d -eq 'Allow') -and $apps -and $new -and $desktop -and (Test-DexRunOk)
        }
    },

    @{
        Name            = 'KeepPerApp'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Variables       = @{ LocationServices = 'Disable'; DesktopApps = 'Keep' }
        Methods         = @(@{ Name = 'FixturePromptDesktopAllow'; Apply = {
            Set-DexValue -Path $DeviceKey -Value 'Allow'
            foreach ($u in (Get-DexUserKeys)) { Set-DexValue -Path "$u\$FixAllowed" -Value 'Prompt'; Set-DexValue -Path "$u\NonPackaged" -Value 'Allow' }
        } })
        Verify   = {
            $ok = Test-DexEveryUser -Label 'FixturePrompt' -Check { param($u) ((Get-DexValue -Path "$u\$FixAllowed") -eq 'Prompt') -and ((Get-DexValue -Path "$u\NonPackaged") -eq 'Allow') }
            Write-DexNote -Name 'Verify KeepPerApp' -Message "fixturePrompt=$ok"
            $ok
        }
        Validate = {
            param($Original)
            $d    = Get-DexValue -Path $DeviceKey
            $kept = Test-DexEveryUser -Label 'Kept' -Check { param($u)
                ((Get-DexValue -Path $u) -eq 'Deny') -and ((Get-DexValue -Path "$u\$FixAllowed") -eq 'Prompt') -and ((Get-DexValue -Path "$u\NonPackaged") -eq 'Allow') }
            Write-DexNote -Name 'Validate KeepPerApp' -Message "device=$d userDenyFixturePromptDesktopAllow=$kept"
            ($d -eq 'Deny') -and $kept -and (Test-DexRunOk)
        }
    },

    @{
        Name            = 'WhatIfNoChange'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Variables       = @{ LocationServices = 'Enable'; WhatIf = 'true' }
        Methods         = @(@{ Name = 'DeviceAndUserDeny'; Apply = {
            Set-DexValue -Path $DeviceKey -Value 'Deny'
            foreach ($u in (Get-DexUserKeys)) { Set-DexValue -Path $u -Value 'Deny' }
        } })
        Verify   = {
            $d = Get-DexValue -Path $DeviceKey
            Write-DexNote -Name 'Verify WhatIfNoChange' -Message "device=$d"
            ($d -eq 'Deny') -and (Test-DexEveryUser -Label 'UserDeny' -Check { param($u) (Get-DexValue -Path $u) -eq 'Deny' })
        }
        Validate = {
            param($Original)
            $d        = Get-DexValue -Path $DeviceKey
            $users    = Test-DexEveryUser -Label 'UserStillDeny' -Check { param($u) (Get-DexValue -Path $u) -eq 'Deny' }
            $apps     = Test-DexAppsUntouched -Original $Original
            $reported = $script:currentRun -and ([string]$script:currentRun.Output -match '\(WhatIf\)')
            Write-DexNote -Name 'Validate WhatIfNoChange' -Message "device=$d usersUnchanged=$users appsUntouched=$apps whatIfLine=$reported"
            ($d -eq 'Deny') -and $users -and $apps -and $reported -and (Test-DexRunOk)
        }
    }
)

function Get-BreakDefinition {
    param([Parameter(Mandatory = $true)][string]$Name)
    $BreakCatalog | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Invoke-ScriptUnderTest {
    # Every variable is set or cleared explicitly so nothing bleeds between scenarios
    # or in from the operator's shell. The child inherits the process environment, which
    # is how UEM script variables reach the script.
    param([hashtable]$Variables)
    foreach ($n in $VariableNames) {
        [Environment]::SetEnvironmentVariable($n, $(if ($Variables.ContainsKey($n)) { $Variables[$n] } else { $null }), 'Process')
    }
    try {
        $sw     = [System.Diagnostics.Stopwatch]::StartNew()
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1
        $rc     = $LASTEXITCODE
        $sw.Stop()
    } finally {
        foreach ($n in $VariableNames) { [Environment]::SetEnvironmentVariable($n, $null, 'Process') }
    }
    return @{
        Variables   = $Variables
        ExitCode    = $rc
        DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Output      = ($output | Out-String).Trim()
    }
}

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList

Write-DexBanner -Title 'Set-LocationServices_BreakTest' -Detail "Environment: $Environment"

if ($Resume) { throw 'This harness has no reboot resume; nothing here reboots.' }

# -- Restore-only mode ---------------------------------------------------------
if ($Restore) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    $toRestore = @($state.Breaks); [array]::Reverse($toRestore)
    foreach ($b in $toRestore) {
        try {
            Restore-DexSnapshot -Original ([PSCustomObject]$b.OriginalState)
            Write-DexStep -Status 'Passed' -Name "Restore $($b.Name)"
        } catch {
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }
    Remove-Fixture
    $state.Phase   = 'Restored'
    $state.Overall = 'Restored'
    Write-DexTestResult -State $state | Out-Null
    Clear-DexTestState -State $state
    exit 0
}

# -- Acquire context -----------------------------------------------------------
$state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Seed $Seed -Environment $Environment
$state.RemediationTest = [bool]$RemediationTest
Write-DexStep -Status 'Info' -Name 'Context' -Message "TestId $($state.TestId)  Seed $($state.Seed)"

if (-not (Test-Path -LiteralPath $RemediationScript)) { throw "Script under test not found at $RemediationScript" }
if ((Get-DexUserKeys).Count -eq 0) { throw 'No user hive is loaded; sign a user in so the per-user values can be exercised.' }

$exitCode      = 0
$restoreFailed = $false
$runs          = @()
$validation    = @()
$anyBreakFailed = $false

try {
    $candidates = if ($BreakName) {
        @($BreakCatalog | Where-Object { @($BreakName -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Name })
    } else {
        @($BreakCatalog)
    }
    if ($candidates.Count -eq 0) { throw 'No scenario matched the requested selection.' }

    $selected = if ($BreakName) { $candidates } else { Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount }

    foreach ($def in $selected) {
        $method   = (Get-DexRandomSubset -InputObject $def.Methods -Random $state.Random -Count 1)[0]
        $original = New-DexSnapshot

        $b = @{
            Name            = $def.Name
            Method          = $method.Name
            ExpectedOutcome = $def.ExpectedOutcome
            RequiresReboot  = $false
            Applied         = $false
            BreakVerified   = $false
            Variables       = $def.Variables
            OriginalState   = $original
        }
        $state.Breaks = @($state.Breaks) + @($b)
        Save-DexTestState -State $state

        try {
            # -- apply ----------------------------------------------------------------
            & $method.Apply
            $b.Applied = $true
            Write-DexStep -Status 'Info' -Name "Scenario $($def.Name)" -Message "starting state '$($method.Name)' applied"

            # -- verify ---------------------------------------------------------------
            $b.BreakVerified = [bool](& $def.Verify)
            if ($b.BreakVerified) {
                Write-DexStep -Status 'Passed' -Name "Verify $($def.Name)" -Message 'starting state is in place'
            } else {
                $anyBreakFailed = $true
                Write-DexStep -Status 'Failed' -Name "Verify $($def.Name)" -Message 'starting state did not land; the run would prove nothing'
                $validation += @{ Name = $def.Name; Expected = 'starting state in place'; Actual = 'NOT as expected'; Result = 'Fail' }
                continue
            }

            if (-not $RemediationTest) { continue }

            # -- run ------------------------------------------------------------------
            $vars = ($def.Variables.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
            Write-DexStep -Status 'Info' -Name "Run $($def.Name)" -Message $vars
            $script:currentRun = Invoke-ScriptUnderTest -Variables $def.Variables
            $script:currentRun.Scenario = $def.Name
            $runs += $script:currentRun
            Write-DexStep -Status 'Info' -Name "Run $($def.Name)" -Message "exit $($script:currentRun.ExitCode) in $($script:currentRun.DurationSec) s"

            # -- validate -------------------------------------------------------------
            $passed   = [bool](& $def.Validate $original)
            $expected = if ($def.ExpectedOutcome -eq 'ExpectFixed') { 'values changed to the requested state' } else { 'values reported, left unmodified' }
            $validation += @{
                Name     = $def.Name
                Expected = $expected
                Actual   = if ($passed) { 'as expected' } else { 'NOT as expected' }
                Result   = if ($passed) { 'Pass' } else { 'Fail' }
            }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) -Name "Validate $($def.Name)" -Message $expected
        } finally {
            # -- restore this scenario before the next one starts --------------------
            if ($Environment -eq 'Physical') {
                try {
                    Restore-DexSnapshot -Original $original
                    Remove-Fixture
                    Write-DexStep -Status 'Passed' -Name "Restore $($def.Name)"
                } catch {
                    $restoreFailed = $true
                    Write-DexStep -Status 'Failed' -Name "Restore $($def.Name)" -Message $_.Exception.Message
                }
            }
            $script:currentRun = $null
            $state.Validation = $validation
            Save-DexTestState -State $state
        }
    }

    $state.Phase = if ($RemediationTest) { 'Validated' } else { 'BreakVerified' }
    if ($runs.Count -gt 0) {
        $state.Remediation = @{
            ExitCode    = ($runs | ForEach-Object { [int]$_.ExitCode } | Measure-Object -Maximum).Maximum
            DurationSec = [math]::Round((($runs | ForEach-Object { $_.DurationSec }) | Measure-Object -Sum).Sum, 1)
            Output      = (($runs | ForEach-Object { "== $($_.Scenario) (exit $($_.ExitCode))`n$($_.Output)" }) -join "`n`n")
            Runs        = $runs
        }
    }

    $failedCount = @($validation | Where-Object { $_.Result -eq 'Fail' }).Count
    $state.Overall = if (-not $RemediationTest) {
        'BreakOnly'
    } elseif ($anyBreakFailed) {
        'BreakFailed'
    } elseif ($failedCount -eq 0) {
        'Passed'
    } elseif ($state.Remediation -and [int]$state.Remediation.ExitCode -eq 0) {
        'FalsePass'
    } else {
        'Failed'
    }

} catch {
    Write-DexStep -Status 'Failed' -Name 'Harness' -Message $_.Exception.Message
    $state.HarnessError = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    if ($state.Overall -eq 'Incomplete') { $state.Overall = 'Failed' }
    $exitCode = 1
}

if ($Environment -eq 'Physical') {
    if ($restoreFailed) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'machine left modified -- manual cleanup required'
    } else {
        $state.Phase = 'Restored'
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'machine returned to baseline'
    }
}

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) `
              -Name 'Overall' -Message $state.Overall

Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state

exit $exitCode
