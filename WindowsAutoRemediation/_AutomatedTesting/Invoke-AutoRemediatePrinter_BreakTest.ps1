<#
.SYNOPSIS
    Invoke-AutoRemediatePrinter_BreakTest -- deliberately breaks printer components,
    then verifies Invoke-AutoRemediatePrinter.ps1 actually fixes them.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediatePrinter\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It stops the Spooler, marks printers
    offline, and disables a Windows optional feature. Run it only on a disposable
    VM or a marked test host. See Assert-DexTestHost in DEXTestFramework.psm1.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES
    Five of the nine steps in Invoke-AutoRemediatePrinter.ps1 have
    ResolutionScript = $null by design, so breaking them must NOT expect a repair.
    Each break declares which it is:
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    REBOOTS
    Breaks flagged RequiresReboot suspend the run, register an AtStartup resume
    task, and reboot. The run re-enters at the recorded Phase. Opt in with
    -IncludeRebootBreaks; they are excluded by default.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediatePrinter.ps1 and validate the outcome.
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
    Script Name  : Invoke-AutoRemediatePrinter_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-07
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediatePrinter\

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

$ScriptUnderTest   = 'Invoke-AutoRemediatePrinter'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediatePrinter.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\PrinterErrors'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\_AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Fixture ------------------------------------------------------------------
# A bare VM often has only Microsoft Print to PDF/XPS, so the breaks need a
# printer of their own to act on rather than mutating whatever happens to exist.
$FixturePrinter    = 'DEXTest Printer'
$FixtureNetPrinter = 'DEXTest NetPrinter'
# 192.0.2.0/24 is TEST-NET-1 (RFC 5737): guaranteed unroutable, so the network
# reachability check fails deterministically instead of depending on the LAN.
$FixtureNetPort    = 'DEXTEST_192.0.2.1'
$FixtureNetAddress = '192.0.2.1'

function Initialize-Fixture {
    if (-not (Get-Printer -Name $FixturePrinter -ErrorAction SilentlyContinue)) {
        $driver = Get-PrinterDriver -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like 'Microsoft Print*PDF*' } |
                  Select-Object -First 1
        if (-not $driver) {
            $driver = Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if (-not $driver) { throw 'No printer driver available to build the test fixture.' }

        Add-Printer -Name $FixturePrinter -DriverName $driver.Name -PortName 'FILE:' -ErrorAction Stop
        Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Created '$FixturePrinter' on driver '$($driver.Name)'"
    }
}

function Remove-Fixture {
    foreach ($p in @($FixturePrinter, $FixtureNetPrinter)) {
        if (Get-Printer -Name $p -ErrorAction SilentlyContinue) {
            Remove-Printer -Name $p -ErrorAction SilentlyContinue
        }
    }
    if (Get-PrinterPort -Name $FixtureNetPort -ErrorAction SilentlyContinue) {
        Remove-PrinterPort -Name $FixtureNetPort -ErrorAction SilentlyContinue
    }
}

# -- Helpers ------------------------------------------------------------------

function Get-SpoolerCim {
    Get-CimInstance -ClassName Win32_Service -Filter "Name='Spooler'" -ErrorAction SilentlyContinue
}

function ConvertTo-StartupType {
    param([string]$StartMode)
    switch ($StartMode) {
        'Auto'     { 'Automatic' }
        'Manual'   { 'Manual'    }
        'Disabled' { 'Disabled'  }
        default    { 'Automatic' }
    }
}

function Test-DexRecordContains {
    <#
        Confirms the remediation script reported a finding for a given step. Used
        by ExpectReportedOnly breaks, where the correct behaviour is to surface the
        problem rather than fix it.
    #>
    param([Parameter(Mandatory = $true)][string]$ValueNamePrefix)

    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { return $false }
    $key = Get-Item -LiteralPath $DexRecordsPath -ErrorAction SilentlyContinue
    if (-not $key) { return $false }
    return @($key.GetValueNames() | Where-Object { $_ -like "$ValueNamePrefix*" }).Count -gt 0
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
$BreakCatalog = @(

    @{
        Name            = 'SpoolerService'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'StopService'
                Apply = { Stop-Service -Name Spooler -Force -ErrorAction Stop }
            },
            @{
                Name  = 'DisableAndStop'
                Apply = {
                    Set-Service -Name Spooler -StartupType Disabled -ErrorAction Stop
                    Stop-Service -Name Spooler -Force -ErrorAction Stop
                }
            }
        )
        Capture  = {
            $svc = Get-SpoolerCim
            @{ StartMode = $svc.StartMode; State = $svc.State }
        }
        Verify   = { (Get-Service -Name Spooler -ErrorAction SilentlyContinue).Status -ne 'Running' }
        Validate = { (Get-Service -Name Spooler -ErrorAction SilentlyContinue).Status -eq 'Running' }
        Restore  = {
            param($Original)
            Set-Service -Name Spooler -StartupType (ConvertTo-StartupType $Original.StartMode) -ErrorAction SilentlyContinue
            if ($Original.State -eq 'Running') {
                Start-Service -Name Spooler -ErrorAction SilentlyContinue
            }
        }
    },

    @{
        Name            = 'PrinterOffline'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'SetWorkOfflineFlag'
                Apply = {
                    $p = Get-WmiObject -Class Win32_Printer -Filter "Name='$FixturePrinter'" -ErrorAction Stop
                    $p.WorkOffline = $true
                    $p.Put() | Out-Null
                }
            }
        )
        Capture  = {
            $p = Get-WmiObject -Class Win32_Printer -Filter "Name='$FixturePrinter'" -ErrorAction SilentlyContinue
            @{ WorkOffline = [bool]$p.WorkOffline }
        }
        Verify   = {
            $p = Get-WmiObject -Class Win32_Printer -Filter "Name='$FixturePrinter'" -ErrorAction SilentlyContinue
            [bool]$p.WorkOffline
        }
        Validate = {
            $p = Get-WmiObject -Class Win32_Printer -Filter "Name='$FixturePrinter'" -ErrorAction SilentlyContinue
            -not [bool]$p.WorkOffline
        }
        Restore  = {
            param($Original)
            $p = Get-WmiObject -Class Win32_Printer -Filter "Name='$FixturePrinter'" -ErrorAction SilentlyContinue
            if ($p) { $p.WorkOffline = $false; $p.Put() | Out-Null }
        }
    },

    @{
        Name            = 'NetworkPrinterUnreachable'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'AddPrinterOnUnroutableAddress'
                Apply = {
                    if (-not (Get-PrinterPort -Name $FixtureNetPort -ErrorAction SilentlyContinue)) {
                        Add-PrinterPort -Name $FixtureNetPort -PrinterHostAddress $FixtureNetAddress -ErrorAction Stop
                    }
                    $driver = Get-PrinterDriver -ErrorAction SilentlyContinue |
                              Where-Object { $_.Name -like 'Microsoft Print*PDF*' } |
                              Select-Object -First 1
                    if (-not $driver) {
                        $driver = Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -First 1
                    }
                    Add-Printer -Name $FixtureNetPrinter -DriverName $driver.Name -PortName $FixtureNetPort -ErrorAction Stop
                }
            }
        )
        Capture  = { @{ Existed = [bool](Get-Printer -Name $FixtureNetPrinter -ErrorAction SilentlyContinue) } }
        Verify   = { [bool](Get-Printer -Name $FixtureNetPrinter -ErrorAction SilentlyContinue) }
        # Correct behaviour is to report and leave alone: the printer must still be
        # here afterwards, and the finding must have reached the registry.
        Validate = {
            $stillThere = [bool](Get-Printer -Name $FixtureNetPrinter -ErrorAction SilentlyContinue)
            $reported   = Test-DexRecordContains -ValueNamePrefix 'Step07_'
            $stillThere -and $reported
        }
        Restore  = {
            param($Original)
            if (Get-Printer -Name $FixtureNetPrinter -ErrorAction SilentlyContinue) {
                Remove-Printer -Name $FixtureNetPrinter -ErrorAction SilentlyContinue
            }
            if (Get-PrinterPort -Name $FixtureNetPort -ErrorAction SilentlyContinue) {
                Remove-PrinterPort -Name $FixtureNetPort -ErrorAction SilentlyContinue
            }
        }
    },

    @{
        Name            = 'PrintFoundationFeature'
        ExpectedOutcome = 'ExpectFixed'
        # Disable leaves the feature in DisablePending until the machine reboots,
        # and the re-enable needs a second reboot before it reads back as Enabled.
        RequiresReboot  = $true
        Methods         = @(
            @{
                Name  = 'DisableOptionalFeature'
                Apply = {
                    Disable-WindowsOptionalFeature -Online -FeatureName 'Printing-Foundation-Features' `
                        -NoRestart -ErrorAction Stop | Out-Null
                }
            }
        )
        Capture  = {
            $f = Get-WindowsOptionalFeature -Online -FeatureName 'Printing-Foundation-Features' -ErrorAction SilentlyContinue
            @{ State = "$($f.State)" }
        }
        Verify   = {
            $f = Get-WindowsOptionalFeature -Online -FeatureName 'Printing-Foundation-Features' -ErrorAction SilentlyContinue
            $f -and $f.State -ne 'Enabled'
        }
        Validate = {
            $f = Get-WindowsOptionalFeature -Online -FeatureName 'Printing-Foundation-Features' -ErrorAction SilentlyContinue
            $f -and $f.State -eq 'Enabled'
        }
        Restore  = {
            param($Original)
            if ($Original.State -eq 'Enabled') {
                Enable-WindowsOptionalFeature -Online -FeatureName 'Printing-Foundation-Features' `
                    -NoRestart -ErrorAction SilentlyContinue | Out-Null
            }
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

Write-DexBanner -Title "Invoke-AutoRemediatePrinter_BreakTest" -Detail "Environment: $Environment"

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
    foreach ($b in @($state.Breaks)) {
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

Write-Host ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) `
              -Name 'Overall' -Message $state.Overall

Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state

exit $exitCode
