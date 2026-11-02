<#
.SYNOPSIS
    Invoke-AutoRemediateAppXBloat_BreakTest -- deliberately installs a deny-listed
    AppX package for existing users, then verifies Invoke-AutoRemediateAppXBloat.ps1
    removes it.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateAppXBloat\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It switches the host into Developer
    Mode (AppModelUnlock registry values, restored afterwards), registers a
    loose-file framework package named DEXTest.BloatProbe for the running user, and
    feeds the script under test DenyListExtra='DEXTest.*' and
    RemoveForExistingUsers=true through the environment, exactly as Workspace ONE
    would.

    COLLATERAL YOU MUST ACCEPT BEFORE RUNNING WITH -RemediationTest
    The script under test applies its built-in default deny list on every run and
    offers no way to turn it off. A -RemediationTest run therefore ALSO deprovisions
    the default consumer inbox apps (Xbox, Weather, News, Solitaire, Feedback Hub,
    Maps, Clipchamp, ...) for future users, and -- because this harness has to set
    RemoveForExistingUsers=true to reach step 2 -- removes them for every existing
    user on the host, including whoever is signed in. That is not reversible from
    here. Run it only on a disposable VM or a marked test host whose signed-in user
    is itself disposable. See Assert-DexTestHost in DEXTestFramework.psm1.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES
    Both steps in Invoke-AutoRemediateAppXBloat.ps1 carry a ResolutionScript, so
    every break here is ExpectFixed:
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    COVERAGE
    Step 1 (Deprovision Non-Essential AppX, Future Users) is NOT covered. Planting
    its condition means adding a provisioned package whose DisplayName matches the
    deny list, and Add-AppxProvisionedPackage accepts only a signed .appx/.msix,
    which this harness cannot build offline. Breaking it against a real inbox
    package would deprovision that package irreversibly, which the fixture rules
    forbid.

    REBOOTS
    The break in this catalog needs no reboot. The reboot plumbing is kept so the
    harness stays uniform with its siblings, and -IncludeRebootBreaks has no effect
    here.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateAppXBloat.ps1 and validate the outcome.
    Without this the script breaks and reports only.

.PARAMETER Environment
    Physical (default) restores the machine when the run ends.
    Snapshot skips restore on the assumption the host reverts a checkpoint.

.PARAMETER Seed
    Replays an earlier run's random break selection exactly. Omit for a new random
    seed, which is always recorded in the result.

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
    Script Name  : Invoke-AutoRemediateAppXBloat_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateAppXBloat\

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

$ScriptUnderTest   = 'Invoke-AutoRemediateAppXBloat'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateAppXBloat.ps1'
# The script under test writes run summaries here (LastRun, Passed, Warnings, Failed,
# RemediationsRun, RemediationErrors, RemoveForExistingUsers), not per-step DEXRecords.
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extensions\AppXBloat\Remediation'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Fixture ------------------------------------------------------------------
# No signed package can be produced offline, so the fixture is a loose-file
# framework package (manifest + logo only, no executable) registered from disk under
# Developer Mode. It is a genuine entry in Get-AppxPackage -AllUsers, which is all
# step 2 of the script under test looks at.
$FixtureRoot        = 'C:\Temp\DEXTest\AppXBloat'
$FixturePackageDir  = Join-Path $FixtureRoot 'BloatProbe'
$FixtureManifest    = Join-Path $FixturePackageDir 'AppxManifest.xml'
$FixturePackageName = 'DEXTest.BloatProbe'
$FixturePublisher   = 'CN=DEXTest'
$FixtureDenyPattern = 'DEXTest.*'
$DevModeKey         = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$DevModeValues      = @('AllowDevelopmentWithoutDevLicense', 'AllowAllTrustedApps')

# 1x1 transparent PNG. The manifest must reference a logo that exists; nothing
# inspects its dimensions at registration time.
$FixtureLogoBase64  = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='

function Initialize-Fixture {
    if (-not (Get-Command -Name Get-AppxPackage -ErrorAction SilentlyContinue)) {
        throw 'The Appx module is not available; cannot build the test fixture.'
    }
    if (-not (Test-Path -LiteralPath $FixturePackageDir)) {
        New-Item -ItemType Directory -Path $FixturePackageDir -Force -ErrorAction Stop | Out-Null
    }
    $assets = Join-Path $FixturePackageDir 'Assets'
    if (-not (Test-Path -LiteralPath $assets)) {
        New-Item -ItemType Directory -Path $assets -Force -ErrorAction Stop | Out-Null
    }
    [System.IO.File]::WriteAllBytes((Join-Path $assets 'Logo.png'), [Convert]::FromBase64String($FixtureLogoBase64))

    $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
         xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
         IgnorableNamespaces="uap">
  <Identity Name="$FixturePackageName" Publisher="$FixturePublisher" Version="1.0.0.0" ProcessorArchitecture="neutral" />
  <Properties>
    <DisplayName>DEXTest Bloat Probe</DisplayName>
    <PublisherDisplayName>DEXTest</PublisherDisplayName>
    <Logo>Assets\Logo.png</Logo>
    <Framework>true</Framework>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Universal" MinVersion="10.0.17763.0" MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Resources>
    <Resource Language="en-US" />
  </Resources>
</Package>
"@
    [System.IO.File]::WriteAllText($FixtureManifest, $manifest, [System.Text.UTF8Encoding]::new($false))
    Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Loose package staged at '$FixturePackageDir'"
}

function Remove-Fixture {
    $pkg = Get-FixturePackage
    if ($pkg) {
        $pkg | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $FixtureRoot) {
        Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -- Helpers ------------------------------------------------------------------

function Get-FixturePackage {
    Get-AppxPackage -AllUsers -Name $FixturePackageName -ErrorAction SilentlyContinue
}

function Get-DevModeState {
    # $null for a value (or the whole key) that does not exist, so Restore can tell
    # "was 0" from "was absent".
    $out = @{ KeyExisted = (Test-Path -LiteralPath $DevModeKey) }
    foreach ($name in $DevModeValues) {
        $out[$name] = $null
        if ($out.KeyExisted) {
            $item = Get-ItemProperty -LiteralPath $DevModeKey -Name $name -ErrorAction SilentlyContinue
            if ($item) { $out[$name] = [int]$item.$name }
        }
    }
    return $out
}

function Enable-DexDeveloperMode {
    if (-not (Test-Path -LiteralPath $DevModeKey)) {
        New-Item -Path $DevModeKey -Force -ErrorAction Stop | Out-Null
    }
    foreach ($name in $DevModeValues) {
        Set-ItemProperty -LiteralPath $DevModeKey -Name $name -Value 1 -Type DWord -ErrorAction Stop
    }
}

function Restore-DexDeveloperMode {
    param($Original)
    if (-not [bool]$Original.KeyExisted) {
        if (Test-Path -LiteralPath $DevModeKey) { Remove-Item -LiteralPath $DevModeKey -Recurse -Force -ErrorAction SilentlyContinue }
        return
    }
    foreach ($name in $DevModeValues) {
        $value = $Original.$name
        if ($null -eq $value) {
            Remove-ItemProperty -LiteralPath $DevModeKey -Name $name -ErrorAction SilentlyContinue
        } else {
            Set-ItemProperty -LiteralPath $DevModeKey -Name $name -Value ([int]$value) -Type DWord -ErrorAction SilentlyContinue
        }
    }
}

function Set-DexScriptEnvironment {
    # The harness launches the script under test as a child powershell.exe, which
    # inherits this process's environment block -- the same channel Workspace ONE uses.
    $env:DenyListExtra          = $FixtureDenyPattern
    $env:RemoveForExistingUsers = 'true'
}

function Restore-DexScriptEnvironment {
    param($Original)
    if ($null -eq $Original.EnvDenyListExtra) { Remove-Item -Path Env:\DenyListExtra -ErrorAction SilentlyContinue }
    else { $env:DenyListExtra = [string]$Original.EnvDenyListExtra }
    if ($null -eq $Original.EnvRemoveForExistingUsers) { Remove-Item -Path Env:\RemoveForExistingUsers -ErrorAction SilentlyContinue }
    else { $env:RemoveForExistingUsers = [string]$Original.EnvRemoveForExistingUsers }
}

function Test-DexRemediationRecorded {
    <#
        Confirms the script under test completed a run after this test started and
        that the environment inputs reached it: RemoveForExistingUsers is echoed back
        into the summary key as a DWord and at least one remediation was applied.
    #>
    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { return $false }
    $key = Get-ItemProperty -LiteralPath $DexRecordsPath -ErrorAction SilentlyContinue
    if (-not $key) { return $false }
    $lastRun = $null
    if ($key.LastRun) {
        try { $lastRun = [datetime]::ParseExact([string]$key.LastRun, 'yyyy-MM-dd HH:mm:ss', $null) } catch { $lastRun = $null }
    }
    $started = [datetime]::Parse([string]$state.StartedAt)
    return ($lastRun -and ($lastRun -ge $started.AddMinutes(-1)) -and
            ([int]$key.RemoveForExistingUsers -eq 1) -and
            ([int]$key.RemediationsRun -ge 1))
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
$BreakCatalog = @(

    @{
        # Step 2: Remove Non-Essential AppX (Existing Users). An installed package whose
        # Name matches the deny list and not the safelist must be removed for all users.
        Name            = 'InstalledDenyListedPackage'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'RegisterLooseDenyListedPackage'
                Apply = {
                    Enable-DexDeveloperMode
                    Add-AppxPackage -Register $FixtureManifest -ErrorAction Stop
                    Set-DexScriptEnvironment
                }
            }
        )
        Capture  = {
            $dev = Get-DevModeState
            @{
                PackageExisted                    = [bool](Get-FixturePackage)
                KeyExisted                        = $dev.KeyExisted
                AllowDevelopmentWithoutDevLicense = $dev.AllowDevelopmentWithoutDevLicense
                AllowAllTrustedApps               = $dev.AllowAllTrustedApps
                EnvDenyListExtra                  = $env:DenyListExtra
                EnvRemoveForExistingUsers         = $env:RemoveForExistingUsers
            }
        }
        # The package must be visible the way step 2 looks for it, and the inputs that
        # make step 2 act on it must be in place; otherwise the run would be a false green.
        Verify   = {
            $pkg = Get-FixturePackage
            [bool]$pkg -and ($pkg.Name -like $FixtureDenyPattern) -and
            ($env:DenyListExtra -eq $FixtureDenyPattern) -and
            ($env:RemoveForExistingUsers -eq 'true')
        }
        Validate = {
            (-not (Get-FixturePackage)) -and (Test-DexRemediationRecorded)
        }
        Restore  = {
            param($Original)
            if (-not [bool]$Original.PackageExisted) {
                $pkg = Get-FixturePackage
                if ($pkg) { $pkg | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue }
            }
            Restore-DexDeveloperMode -Original $Original
            Restore-DexScriptEnvironment -Original $Original
        }
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

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList

Write-DexBanner -Title "Invoke-AutoRemediateAppXBloat_BreakTest" -Detail "Environment: $Environment"

# -- Restore-only mode ---------------------------------------------------------
if ($Restore) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    foreach ($b in $state.Breaks) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
            Write-DexStep -Status 'Passed' -Name "Restore $($b.Name)"
        } catch {
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
    # RemediationTest cannot survive as a switch across the reboot, so it is
    # recovered from the state that was persisted before the machine went down.
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
            Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount
        }

        # A single-entry catalog cannot produce a conflicting selection; no guard is needed.

        $applied = @()
        foreach ($def in $selected) {
            $method = (Get-DexRandomSubset -InputObject $def.Methods -Random $state.Random -Count 1)[0]

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
            # On 2026-10-28 a disabled Spooler was left behind because the next break's Capture
            # threw and the applied list had not been committed yet.
            $state.Breaks = $applied
            Save-DexTestState -State $state
        }

        $state.Breaks = $applied
        $state.Phase  = 'Broken'
        Save-DexTestState -State $state

        if ($state.RequiresReboot) {
            Request-TestReboot -State $state
            exit 0
        }
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
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "invoking $([System.IO.Path]::GetFileName($RemediationScript))"

            $sw     = [System.Diagnostics.Stopwatch]::StartNew()
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1
            $rc     = $LASTEXITCODE
            $sw.Stop()

            $state.Remediation = @{
                ExitCode    = $rc
                DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                Output      = ($output | Out-String).Trim()
            }
            $state.Phase = 'Remediated'
            Save-DexTestState -State $state

            if ($state.RequiresReboot) {
                Request-TestReboot -State $state
                exit 0
            }
        }
    }

    # -- Phase: validate -------------------------------------------------------
    if ($state.Phase -eq 'Remediated') {

        $validation = @()
        foreach ($b in $state.Breaks) {
            $def    = Get-BreakDefinition -Name $b.Name
            $passed = [bool](& $def.Validate)

            $expected = if ($b.ExpectedOutcome -eq 'ExpectFixed') {
                'component repaired by remediation'
            } else {
                'component detected and reported, left unmodified'
            }

            $validation += @{
                Name     = $b.Name
                Expected = $expected
                Actual   = if ($passed) { 'as expected' } else { 'NOT as expected' }
                Result   = if ($passed) { 'Pass' } else { 'Fail' }
            }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) `
                          -Name "Validate $($b.Name)" -Message $expected
        }

        $state.Validation = $validation
        $state.Phase      = 'Validated'

        $failedCount = @($validation | Where-Object { $_.Result -eq 'Fail' }).Count
        $state.Overall = if ($failedCount -eq 0) {
            'Passed'
        } elseif ($state.Remediation -and [int]$state.Remediation.ExitCode -eq 0) {
            # Remediation claimed success while the component is still broken.
            'FalsePass'
        } else {
            'Failed'
        }

        Save-DexTestState -State $state
    }

} catch {
    Write-DexStep -Status 'Failed' -Name 'Harness' -Message $_.Exception.Message
    if ($state.Overall -eq 'Incomplete') { $state.Overall = 'Failed' }
    $exitCode = 1
}

# -- Restore -------------------------------------------------------------------
# Snapshot environments revert on the host, so restoring here would only add risk.
if ($Environment -eq 'Physical') {
    $restoreFailed = $false
    # Restore newest-first. A later break's Capture can record state an earlier break had
    # already changed; undoing in reverse order lets the oldest capture, the true baseline, win.
    $toRestore = @($state.Breaks); [array]::Reverse($toRestore)
    foreach ($b in $toRestore) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
        } catch {
            $restoreFailed = $true
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
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
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) `
              -Name 'Overall' -Message $state.Overall

Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state

exit $exitCode
