<#
.SYNOPSIS
    Restart-WindowsUpdateServices_BreakTest -- deliberately stops the Windows Update
    service stack, then verifies Restart-WindowsUpdateServices.ps1 brings it back.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Restart-WindowsUpdateServices\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It stops wuauserv, BITS and
    Cryptographic Services (which takes AppIDSvc / applockerfltr down with it).
    Run it only on a disposable VM or a marked test host. See Assert-DexTestHost
    in DEXTestFramework.psm1.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES
    Restart-WindowsUpdateServices.ps1 has exactly one promise: after it runs, every
    service in its list (wuauserv, bits, cryptsvc, msiserver) is Running, else it
    exits 1. It writes nothing to DEXRecords, so every break here is ExpectFixed:
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- (unused) remediation must DETECT and report it only

    On an idle VM BITS and msiserver are normally Stopped (Manual start), so the
    BitsStopped break confirms the "start whatever is not running" promise rather
    than injecting a change of state; its Capture records Stopped so Restore puts
    it back to Stopped afterwards. msiserver is left alone: stopping it can abort
    an in-flight MSI install on the host and the script treats it identically.

    WHAT IS NOT COVERED
    A Disabled service: the script calls Start-Service without resetting the
    startup type, so Start fails and the run exits 1. That is a reported failure,
    not a repair, and there is no DEXRecords key to assert against, so no break
    is defined for it. A stale SoftwareDistribution store is not something this
    script looks at (Invoke-AutoRemediateWindowsUpdates does) and is not broken here.

    REBOOTS
    No break in this catalog needs a reboot. The reboot plumbing (-IncludeRebootBreaks,
    -Resume) is retained for parity with the other break tests.

.PARAMETER RemediationTest
    After breaking, run Restart-WindowsUpdateServices.ps1 and validate the outcome.
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
    Script Name  : Restart-WindowsUpdateServices_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
    Reporting    : C:\Temp\FixReport\Restart-WindowsUpdateServices\

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

$ScriptUnderTest   = 'Restart-WindowsUpdateServices'
$RemediationScript = Join-Path $PSScriptRoot '..\Restart-WindowsUpdateServices.ps1'
# Restart-WindowsUpdateServices.ps1 writes no findings to DEXRecords; it reports by
# exit code only. Kept for schema parity with the other break tests.
$DexRecordsPath    = $null
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Fixture ------------------------------------------------------------------
# The services under test are built into Windows, so there is nothing to create.
# The two functions stay so the Main section is identical across break tests.
function Initialize-Fixture { }

function Remove-Fixture { }

# -- Helpers ------------------------------------------------------------------

function Get-ServiceCim {
    param([Parameter(Mandatory = $true)][string]$Name)
    Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
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

function Get-RunningDependentNames {
    <#
        Stop-Service -Force takes a service's running dependents down with it (cryptsvc
        carries AppIDSvc and applockerfltr). Capture records them so Restore can bring
        them back; the remediation script itself never does.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return @() }
    @($svc.DependentServices | Where-Object { $_.Status -eq 'Running' } | ForEach-Object { $_.Name })
}

function Get-ServiceSnapshot {
    param([Parameter(Mandatory = $true)][string]$Name)
    $cim = Get-ServiceCim -Name $Name
    @{
        StartMode         = "$($cim.StartMode)"
        State             = "$($cim.State)"
        RunningDependents = @(Get-RunningDependentNames -Name $Name)
    }
}

function Restore-ServiceSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Snapshot
    )
    Set-Service -Name $Name -StartupType (ConvertTo-StartupType $Snapshot.StartMode) -ErrorAction SilentlyContinue
    if ($Snapshot.State -eq 'Running') {
        Start-Service -Name $Name -ErrorAction SilentlyContinue
        foreach ($dep in @($Snapshot.RunningDependents)) {
            Start-Service -Name $dep -ErrorAction SilentlyContinue
        }
    } else {
        # The remediation starts every service it knows about, including ones that were
        # idle at baseline (BITS, msiserver). Put them back the way they were.
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    }
}

function Test-ServiceRunning {
    param([Parameter(Mandatory = $true)][string]$Name)
    (Get-Service -Name $Name -ErrorAction SilentlyContinue).Status -eq 'Running'
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
$BreakCatalog = @(

    @{
        Name            = 'WuauservStopped'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'StopService'
                Apply = { Stop-Service -Name wuauserv -Force -ErrorAction Stop }
            }
        )
        Capture  = { Get-ServiceSnapshot -Name wuauserv }
        Verify   = { -not (Test-ServiceRunning -Name wuauserv) }
        Validate = { Test-ServiceRunning -Name wuauserv }
        Restore  = {
            param($Original)
            Restore-ServiceSnapshot -Name wuauserv -Snapshot $Original
        }
    },

    @{
        Name            = 'BitsStopped'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'StopService'
                Apply = { Stop-Service -Name bits -Force -ErrorAction Stop }
            }
        )
        Capture  = { Get-ServiceSnapshot -Name bits }
        Verify   = { -not (Test-ServiceRunning -Name bits) }
        Validate = { Test-ServiceRunning -Name bits }
        Restore  = {
            param($Original)
            Restore-ServiceSnapshot -Name bits -Snapshot $Original
        }
    },

    @{
        Name            = 'CryptSvcStopped'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'StopService'
                Apply = { Stop-Service -Name cryptsvc -Force -ErrorAction Stop }
            }
        )
        Capture  = { Get-ServiceSnapshot -Name cryptsvc }
        Verify   = { -not (Test-ServiceRunning -Name cryptsvc) }
        Validate = { Test-ServiceRunning -Name cryptsvc }
        Restore  = {
            param($Original)
            Restore-ServiceSnapshot -Name cryptsvc -Snapshot $Original
        }
    },

    @{
        # The whole-stack scenario the script exists for: every update service down at once.
        Name            = 'UpdateStackStopped'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'StopAllThree'
                Apply = {
                    Stop-Service -Name wuauserv -Force -ErrorAction Stop
                    Stop-Service -Name bits     -Force -ErrorAction Stop
                    Stop-Service -Name cryptsvc -Force -ErrorAction Stop
                }
            },
            @{
                # Same end state reached the way a hung stack is usually "fixed" by hand:
                # the cryptographic service first, so wuauserv loses its signature checks.
                Name  = 'StopCryptSvcFirst'
                Apply = {
                    Stop-Service -Name cryptsvc -Force -ErrorAction Stop
                    Stop-Service -Name bits     -Force -ErrorAction Stop
                    Stop-Service -Name wuauserv -Force -ErrorAction Stop
                }
            }
        )
        Capture  = {
            @{
                Wuauserv = Get-ServiceSnapshot -Name wuauserv
                Bits     = Get-ServiceSnapshot -Name bits
                CryptSvc = Get-ServiceSnapshot -Name cryptsvc
            }
        }
        Verify   = {
            -not (Test-ServiceRunning -Name wuauserv) -and
            -not (Test-ServiceRunning -Name bits) -and
            -not (Test-ServiceRunning -Name cryptsvc)
        }
        Validate = {
            (Test-ServiceRunning -Name wuauserv) -and
            (Test-ServiceRunning -Name bits) -and
            (Test-ServiceRunning -Name cryptsvc)
        }
        Restore  = {
            param($Original)
            # cryptsvc first so wuauserv/bits come up with signature checking available.
            Restore-ServiceSnapshot -Name cryptsvc -Snapshot $Original.CryptSvc
            Restore-ServiceSnapshot -Name wuauserv -Snapshot $Original.Wuauserv
            Restore-ServiceSnapshot -Name bits     -Snapshot $Original.Bits
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

Write-DexBanner -Title "Restart-WindowsUpdateServices_BreakTest" -Detail "Environment: $Environment"

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

        # UpdateStackStopped already covers the three single-service breaks. Running it
        # alongside one of them is harmless (reverse-order Restore lets the oldest capture
        # win) but tells us nothing new, so it is run alone when randomly co-selected.
        if (@($selected).Count -gt 1 -and ($selected | Where-Object { $_.Name -eq 'UpdateStackStopped' })) {
            $selected = @($selected | Where-Object { $_.Name -ne 'UpdateStackStopped' })
            Write-DexStep -Status 'Info' -Name 'Selection' -Message 'UpdateStackStopped dropped from a multi-break run; test it alone with -BreakName UpdateStackStopped'
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
    $state.HarnessError = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
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
