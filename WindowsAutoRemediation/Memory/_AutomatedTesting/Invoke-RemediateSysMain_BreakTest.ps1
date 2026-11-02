<#
.SYNOPSIS
    Invoke-RemediateSysMain_BreakTest -- deliberately stops or disables the SysMain
    (Superfetch) service, then verifies Invoke-RemediateSysMain.ps1 actually fixes it.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-RemediateSysMain\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It stops the SysMain service and changes
    its startup type. Run it only on a disposable VM or a marked test host. See
    Assert-DexTestHost in DEXTestFramework.psm1.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES
    Invoke-RemediateSysMain.ps1 promises a SysMain that is running AND set to start
    automatically, so both breaks expect a repair and validate both halves of that
    promise plus the DEXRecords 'Status' = 'Remediated' record:
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    SysMainService              Stopped (optionally also Disabled or Manual). The
                                script's primary case.
    SysMainDisabledWhileRunning Still running, but StartType = Disabled: healthy
                                until the next boot, then gone. Script 1.0.0 tested
                                only Status -eq 'Running' and would have produced a
                                FalsePass here; 1.0.1 (2026-11-02) also requires
                                StartType Automatic and sets it, so this break now
                                expects a genuine repair.
    The two breaks cannot share a run: the first needs the service stopped, the
    second needs it running. When both are selected the one drawn first is kept.

    Not covered: the detection-exception branch (Get-Service throwing). Deleting or
    renaming the service is not a reversible lab fault.

    REBOOTS
    Service state and startup type change immediately; nothing here is flagged
    RequiresReboot. Breaks flagged RequiresReboot would suspend the run, register an
    AtStartup resume task, and reboot. Opt in with -IncludeRebootBreaks; they are
    excluded by default.

.PARAMETER RemediationTest
    After breaking, run Invoke-RemediateSysMain.ps1 and validate the outcome.
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
    Script Name  : Invoke-RemediateSysMain_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
    Reporting    : C:\Temp\FixReport\Invoke-RemediateSysMain\

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

$ScriptUnderTest   = 'Invoke-RemediateSysMain'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-RemediateSysMain.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\MemoryErrors\SysMain'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Fixture ------------------------------------------------------------------
# The component under test is the built-in SysMain service; nothing is built. The
# fixture clears the script's DEXRecords key so a 'Status' value found during
# validation was written by THIS run rather than left over from an earlier one.
# The record written by the run is kept as evidence.
$ServiceName = 'SysMain'

function Initialize-Fixture {
    if (Test-Path -LiteralPath $DexRecordsPath) {
        Remove-Item -LiteralPath $DexRecordsPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Cleared stale DEXRecords at $DexRecordsPath"
    }
}

function Remove-Fixture {
    # Intentionally empty: the DEXRecords key written by the remediation is left in
    # place so the operator can inspect what the script reported.
}

# -- Helpers ------------------------------------------------------------------

function Get-SysMainCim {
    Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
}

function Get-SysMainService {
    Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
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

function Get-SysMainBaseline {
    $svc = Get-SysMainCim
    @{ StartMode = $svc.StartMode; State = $svc.State }
}

function Restore-SysMainBaseline {
    param($Original)
    Set-Service -Name $ServiceName -StartupType (ConvertTo-StartupType $Original.StartMode) -ErrorAction SilentlyContinue
    if ($Original.State -eq 'Running') {
        Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    } else {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    }
}

function Test-SysMainHealthy {
    # Both halves of the script's promise: running now, and coming back after a boot.
    $svc = Get-SysMainService
    $svc -and $svc.Status -eq 'Running' -and $svc.StartType -eq 'Automatic'
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

function Get-DexRecordValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { return $null }
    (Get-ItemProperty -LiteralPath $DexRecordsPath -Name $Name -ErrorAction SilentlyContinue).$Name
}

function Test-DexRecordStatus {
    <#
        The script writes a single 'Status' value per run: Passed, Failed or
        Remediated. ExpectFixed breaks demand 'Remediated'; a repaired component with
        any other record means the script fixed it without saying so.
    #>
    param([Parameter(Mandatory = $true)][string]$Expected)

    (Test-DexRecordContains -ValueNamePrefix 'Status') -and ((Get-DexRecordValue -Name 'Status') -eq $Expected)
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
$BreakCatalog = @(

    @{
        Name            = 'SysMainService'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                # Script branch: "SysMain is Stopped (StartType: Automatic). Starting service."
                Name  = 'StopService'
                Apply = { Stop-Service -Name $ServiceName -Force -ErrorAction Stop }
            },
            @{
                # Script branch: "SysMain is disabled. Setting to Automatic and starting."
                Name  = 'DisableAndStop'
                Apply = {
                    Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction Stop
                    Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                }
            },
            @{
                # Script branch: "SysMain is Stopped (StartType: Manual). Starting service."
                # Also proves the fix sets Automatic rather than merely starting the service.
                Name  = 'ManualAndStop'
                Apply = {
                    Set-Service -Name $ServiceName -StartupType Manual -ErrorAction Stop
                    Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                }
            }
        )
        Capture  = { Get-SysMainBaseline }
        Verify   = { (Get-SysMainService).Status -ne 'Running' }
        Validate = { (Test-SysMainHealthy) -and (Test-DexRecordStatus -Expected 'Remediated') }
        Restore  = {
            param($Original)
            Restore-SysMainBaseline -Original $Original
        }
    },

    @{
        Name            = 'SysMainDisabledWhileRunning'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'DisableStartupLeaveRunning'
                Apply = {
                    # The break needs a running service to be meaningful; a host where
                    # SysMain happens to be stopped is started first (Capture already
                    # recorded the stopped state, so Restore puts it back).
                    if ((Get-SysMainService).Status -ne 'Running') {
                        Start-Service -Name $ServiceName -ErrorAction Stop
                    }
                    Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction Stop
                }
            }
        )
        Capture  = { Get-SysMainBaseline }
        Verify   = {
            $svc = Get-SysMainService
            $svc -and $svc.Status -eq 'Running' -and $svc.StartType -eq 'Disabled'
        }
        # The script promises Automatic + Running; 1.0.1 detects the StartType gap and
        # repairs it, so a genuine Remediated record is expected here. See header.
        Validate = { (Test-SysMainHealthy) -and (Test-DexRecordStatus -Expected 'Remediated') }
        Restore  = {
            param($Original)
            Restore-SysMainBaseline -Original $Original
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

Write-DexBanner -Title "Invoke-RemediateSysMain_BreakTest" -Detail "Environment: $Environment"

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

        # The two breaks act on the same service and need opposite starting states (stopped
        # versus running), so they cannot share a run. Keep whichever the seeded shuffle drew
        # first so both get coverage across seeds; force one with -BreakName.
        $exclusive = @('SysMainService', 'SysMainDisabledWhileRunning')
        if (@($selected | Where-Object { $exclusive -contains $_.Name }).Count -gt 1) {
            $keep     = @($selected | Where-Object { $exclusive -contains $_.Name })[0].Name
            $selected = @($selected | Where-Object { ($exclusive -notcontains $_.Name) -or ($_.Name -eq $keep) })
            Write-DexStep -Status 'Info' -Name 'Selection' -Message "SysMain breaks are mutually exclusive; kept '$keep'"
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
