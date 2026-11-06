<#
.SYNOPSIS
    Restart-WinService_BreakTest -- deliberately stops (or stops and disables) the
    Print Spooler, then verifies Restart-WinService.ps1 does what it promises when
    pointed at it through the ServiceName variable.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Restart-WinService\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It stops the Print Spooler (taking any
    running dependents such as Fax or PrintNotify down with it) and changes its
    startup type. Run it only on a disposable VM or a marked test host. See
    Assert-DexTestHost in DEXTestFramework.psm1.

    HOW THE TARGET IS ADDRESSED
    Restart-WinService.ps1 takes its target from the UEM script-object variable
    ServiceName, which Hub delivers as an environment variable. The harness sets
    $env:ServiceName (and clears $env:WhatIf) in its own process immediately before
    launching the script in a child powershell.exe, exactly the values uem-tests.json
    passes (ServiceName = Spooler, WhatIf = ""), and puts both variables back
    afterwards. The script matches the value as a substring of the service short
    name OR display name; 'Spooler' resolves to the single service Spooler
    ("Print Spooler") on every Windows build. The fixture warns if anything else on
    the host happens to match, because the script would restart that too.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES
    Restart-WinService.ps1 writes nothing to DEXRecords. Its contract is the exit
    code (0 = every matched service was started or restarted, 1 = any failure or no
    match) and a tagged output line per service. Validate therefore checks the real
    service state AND the exit code AND the output line the script documents:
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    SpoolerStopped           Spooler stopped, startup type untouched. The script's
                             primary case: "<label> has been started.", exit 0,
                             Spooler Running afterwards.
    SpoolerDisabledAndStopped Spooler stopped AND StartType = Disabled. The script
                             calls Start-Service without resetting the startup type,
                             so the start fails and it reports
                             "Error, <label> could not be started: ...", exit 1. It
                             must leave the service Stopped and Disabled: a run that
                             silently flipped the startup type would be a change
                             the script does not promise.
    UnknownServiceName       The fault is in the input, not the machine: ServiceName
                             is set to a name no service on the host carries. The
                             script must report "Error: no service matched '<name>'."
                             and exit 1 without touching anything.

    Every break drives the same single script invocation, which can carry only one
    ServiceName, so the breaks are mutually exclusive: BreakCount defaults to 1 and
    when more than one is selected the one drawn first is kept. Force a specific
    break with -BreakName.

    Not covered: a service that is Running but hung (not reproducible on demand);
    the restart-while-running path (the healthy-machine UEM run exercises it); a
    protected service that refuses Stop-Service.

    REBOOTS
    Service state and startup type change immediately; nothing here is flagged
    RequiresReboot. The reboot plumbing (-IncludeRebootBreaks, -Resume) is retained
    for parity with the other break tests.

.PARAMETER RemediationTest
    After breaking, run Restart-WinService.ps1 and validate the outcome.
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
    How many components to break when selecting randomly. Default 1, because every
    break in this catalog needs its own script invocation (see DESCRIPTION).

.PARAMETER IncludeRebootBreaks
    Allow breaks that require a reboot to take effect. Default off.

.PARAMETER Restore
    Undo an in-flight run's breaks and exit. No remediation, no validation.

.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot.

.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Restart-WinService_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
    Reporting    : C:\Temp\FixReport\Restart-WinService\

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
    [int]$BreakCount = 1,
    [switch]$IncludeRebootBreaks,
    [switch]$Restore,
    [switch]$Resume,
    [switch]$Force,
    [string[]]$ProductionDomainDenyList = @()
)

$ErrorActionPreference = 'Stop'

$ScriptUnderTest   = 'Restart-WinService'
$RemediationScript = Join-Path $PSScriptRoot '..\Restart-WinService.ps1'
# Restart-WinService.ps1 writes no findings to DEXRecords; it reports by exit code and
# output text only. Kept for schema parity with the other break tests.
$DexRecordsPath    = $null
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Fixture ------------------------------------------------------------------
# The component under test is the built-in Print Spooler; nothing is built. The
# values below are what uem-tests.json hands the script in production testing.
# UnknownServiceName is a name no Windows service carries; the UnknownServiceName
# break's Verify proves that on this host before the script is run against it.
$ServiceName        = 'Spooler'
$UnknownServiceName = 'DEXNoSuchService'

function Initialize-Fixture {
    # The script substring-matches ServiceName against Name AND DisplayName and acts
    # on every hit. Anything beyond Spooler itself would be restarted too, and a
    # failure there would turn the exit code to 1 for reasons unrelated to the break.
    # Assign first: the helper hands back one string[] object, and piping that straight
    # into Where-Object would filter the array as a single item instead of its elements.
    $matched = Get-MatchedServiceNames -Pattern $ServiceName
    $extra   = @($matched | Where-Object { $_ -ne $ServiceName })
    if ($extra.Count -gt 0) {
        Write-DexStep -Status 'Warning' -Name 'Fixture' -Message "'$ServiceName' also matches: $($extra -join ', '); the script will restart those as well"
    }
}

function Remove-Fixture {
    # Intentionally empty: nothing was created.
}

# -- Helpers ------------------------------------------------------------------

function Get-ServiceCim {
    param([Parameter(Mandatory = $true)][string]$Name)
    Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
}

function Get-TargetService {
    Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
}

function Get-MatchedServiceNames {
    <#
        Mirrors the script's own matching rule (substring of Name or DisplayName) so
        the harness can see exactly which services a given ServiceName would hit.
    #>
    param([Parameter(Mandatory = $true)][string]$Pattern)
    $names = @(Get-Service -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like "*$Pattern*" -or $_.DisplayName -like "*$Pattern*" } |
               ForEach-Object { $_.Name })
    return ,[string[]]$names
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
        Stop-Service -Force takes a service's running dependents down with it (Spooler
        carries Fax and PrintNotify where present). Capture records them so Restore can
        bring them back; the remediation script itself never does.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return ,[string[]]@() }
    $names = @($svc.DependentServices | Where-Object { $_.Status -eq 'Running' } | ForEach-Object { $_.Name })
    return ,[string[]]$names
}

function Get-ServiceSnapshot {
    param([Parameter(Mandatory = $true)][string]$Name)
    $cim = Get-ServiceCim -Name $Name
    @{
        StartMode         = "$($cim.StartMode)"
        State             = "$($cim.State)"
        # [string[]] cast, not @(): the helper returns one array object and @() would
        # nest it, leaving a String[] where Restore expects service names.
        RunningDependents = [string[]](Get-RunningDependentNames -Name $Name)
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
            # An empty list round-trips through JSON as $null; @($null) iterates once.
            if ([string]::IsNullOrEmpty("$dep")) { continue }
            Start-Service -Name "$dep" -ErrorAction SilentlyContinue
        }
    } else {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    }
}

function Test-TargetRunning {
    $svc = Get-TargetService
    [bool]($svc -and $svc.Status -eq 'Running')
}

function Test-TargetStoppedAndDisabled {
    $svc = Get-TargetService
    [bool]($svc -and $svc.Status -ne 'Running' -and $svc.StartType -eq 'Disabled')
}

function Test-RemediationExitCode {
    <#
        The script's only machine-readable contract. $state is the run context set in
        Main; Validate runs after the Remediation phase has filled $state.Remediation.
        Diagnostics go to the host stream: a Validate scriptblock's output is cast
        with [bool], so nothing may be written to the output stream here.
    #>
    param([Parameter(Mandatory = $true)][int]$Expected)
    if (-not $state.Remediation) { Write-Host '    [detail] no remediation result recorded'; return $false }
    $actual = [int]$state.Remediation.ExitCode
    if ($actual -ne $Expected) { Write-Host "    [detail] exit code $actual, expected $Expected" }
    return ($actual -eq $Expected)
}

function Test-RemediationOutputContains {
    <#
        Confirms the script wrote the line it documents for this outcome. -like with a
        literal wildcard wrapper rather than -match, so parentheses and quotes in the
        service label need no escaping.
    #>
    param([Parameter(Mandatory = $true)][string]$Text)
    if (-not $state.Remediation) { return $false }
    $output = [string]$state.Remediation.Output
    $hit    = $output -like "*$Text*"
    if (-not $hit) { Write-Host "    [detail] output did not contain '$Text'" }
    return $hit
}

function Get-TargetServiceNameForRun {
    <#
        Every break carries the ServiceName the script must be invoked with. The breaks
        are mutually exclusive precisely because the script takes one value per run; a
        state holding breaks that disagree is a harness fault, not a test result.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$State)
    $names = @($State.Breaks | ForEach-Object { (Get-BreakDefinition -Name $_.Name).TargetServiceName } | Sort-Object -Unique)
    if ($names.Count -ne 1) {
        throw "Breaks in this run need $($names.Count) different ServiceName values; the script accepts one per invocation."
    }
    return [string]$names[0]
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
# TargetServiceName is what $env:ServiceName is set to when the script is invoked.
$BreakCatalog = @(

    @{
        Name              = 'SpoolerStopped'
        ExpectedOutcome   = 'ExpectFixed'
        RequiresReboot    = $false
        TargetServiceName = $ServiceName
        Methods           = @(
            @{
                # Script branch: "<label> has been started."
                Name  = 'StopService'
                Apply = { Stop-Service -Name $ServiceName -Force -ErrorAction Stop }
            },
            @{
                # Same end state with StartType Manual: proves the fix is a plain Start
                # and does not depend on the service being Automatic.
                Name  = 'ManualAndStop'
                Apply = {
                    Set-Service -Name $ServiceName -StartupType Manual -ErrorAction Stop
                    Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                }
            }
        )
        Capture  = { Get-ServiceSnapshot -Name $ServiceName }
        Verify   = { -not (Test-TargetRunning) }
        Validate = {
            (Test-TargetRunning) -and
            (Test-RemediationExitCode -Expected 0) -and
            (Test-RemediationOutputContains -Text "($ServiceName) has been started.")
        }
        Restore  = {
            param($Original)
            Restore-ServiceSnapshot -Name $ServiceName -Snapshot $Original
        }
    },

    @{
        # Script branch: "Error, <label> could not be started: ...", exit 1. The script
        # never resets the startup type, so this is a detect-and-report outcome: the
        # service must still be Stopped and Disabled when the script is done.
        Name              = 'SpoolerDisabledAndStopped'
        ExpectedOutcome   = 'ExpectReportedOnly'
        RequiresReboot    = $false
        TargetServiceName = $ServiceName
        Methods           = @(
            @{
                Name  = 'DisableAndStop'
                Apply = {
                    Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction Stop
                    Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                }
            }
        )
        Capture  = { Get-ServiceSnapshot -Name $ServiceName }
        Verify   = { Test-TargetStoppedAndDisabled }
        Validate = {
            (Test-TargetStoppedAndDisabled) -and
            (Test-RemediationExitCode -Expected 1) -and
            (Test-RemediationOutputContains -Text "($ServiceName) could not be started:")
        }
        Restore  = {
            param($Original)
            Restore-ServiceSnapshot -Name $ServiceName -Snapshot $Original
        }
    },

    @{
        # Script branch: "Error: no service matched '<name>'.", exit 1. Nothing on the
        # machine is changed by Apply; the break is the input the script receives.
        Name              = 'UnknownServiceName'
        ExpectedOutcome   = 'ExpectReportedOnly'
        RequiresReboot    = $false
        TargetServiceName = $UnknownServiceName
        Methods           = @(
            @{
                Name  = 'PointAtMissingService'
                Apply = {
                    # Nothing to mutate. Verify proves no service carries the name.
                }
            }
        )
        Capture  = { @{ ServiceName = $UnknownServiceName; Spooler = (Get-ServiceSnapshot -Name $ServiceName) } }
        # (Helper).Count, not @(Helper).Count: the helper returns one array object whose
        # own Count is the number of matches; @() would wrap it and always report 1.
        Verify   = { (Get-MatchedServiceNames -Pattern $UnknownServiceName).Count -eq 0 }
        Validate = {
            # Left alone: still no such service, and the Spooler was not touched either.
            ((Get-MatchedServiceNames -Pattern $UnknownServiceName).Count -eq 0) -and
            (Test-RemediationExitCode -Expected 1) -and
            (Test-RemediationOutputContains -Text "Error: no service matched '$UnknownServiceName'.") -and
            (-not (Test-RemediationOutputContains -Text "($ServiceName)"))
        }
        Restore  = {
            param($Original)
            # Nothing was changed; the Spooler snapshot is kept in the record for evidence.
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

Write-DexBanner -Title "Restart-WinService_BreakTest" -Detail "Environment: $Environment"

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
            $state.HarnessError = "Restore $($b.Name): $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
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
            @($BreakCatalog | Where-Object { @($BreakName -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Name })
        } else {
            @($BreakCatalog | Where-Object { $IncludeRebootBreaks -or -not $_.RequiresReboot })
        }

        if ($candidates.Count -eq 0) { throw 'No break definitions matched the requested selection.' }

        $selected = if ($BreakName) {
            $candidates
        } else {
            Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount
        }

        # The script is invoked once per run with one ServiceName, and the two Spooler
        # breaks need the service in different states, so no two breaks can share a run.
        # Keep whichever the seeded shuffle drew first so all three get coverage across
        # seeds; force one with -BreakName.
        if (@($selected).Count -gt 1) {
            $keep     = @($selected)[0].Name
            $selected = @($selected | Where-Object { $_.Name -eq $keep })
            Write-DexStep -Status 'Info' -Name 'Selection' -Message "breaks are mutually exclusive (one ServiceName per run); kept '$keep'"
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
            $target = Get-TargetServiceNameForRun -State $state
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "invoking $([System.IO.Path]::GetFileName($RemediationScript)) with ServiceName='$target' WhatIf=''"

            # The script reads its UEM variables from the environment. The child
            # powershell.exe inherits this process's block, so the values are set here
            # and put back afterwards (a null value removes the variable).
            $savedEnv = @{
                ServiceName = [Environment]::GetEnvironmentVariable('ServiceName', 'Process')
                WhatIf      = [Environment]::GetEnvironmentVariable('WhatIf', 'Process')
            }
            try {
                [Environment]::SetEnvironmentVariable('ServiceName', $target, 'Process')
                [Environment]::SetEnvironmentVariable('WhatIf', $null, 'Process')

                $sw     = [System.Diagnostics.Stopwatch]::StartNew()
                $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1
                $rc     = $LASTEXITCODE
                $sw.Stop()
            } finally {
                foreach ($k in @($savedEnv.Keys)) {
                    [Environment]::SetEnvironmentVariable($k, $savedEnv[$k], 'Process')
                }
            }

            $state.Remediation = @{
                ExitCode    = $rc
                DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                ServiceName = $target
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
            $state.HarnessError = "Restore $($b.Name): $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
        }
    }
    try {
        Remove-Fixture
    } catch {
        $restoreFailed = $true
        $state.HarnessError = "Remove-Fixture: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    }

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
