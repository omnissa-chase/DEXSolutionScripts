<#
.SYNOPSIS
    Invoke-AutoRemediateStorageHealth_BreakTest -- deliberately turns TRIM off and disables
    the Optimize Drives task, then verifies Invoke-AutoRemediateStorageHealth.ps1 puts
    both back.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateStorageHealth\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It turns TRIM off for NTFS
    (fsutil behavior set DisableDeleteNotify) and disables the
    \Microsoft\Windows\Defrag\ScheduledDefrag task. Both are settings, not data, and
    both are restored. Run it only on a disposable VM or a marked test host. See
    Assert-DexTestHost in DEXTestFramework.psm1.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green. A break that cannot be verified aborts the run as
    BreakFailed.

    VIRTUAL MACHINES
    The script leaves TRIM and the Optimize Drives schedule alone on a virtual machine
    unless IncludeVirtualMachines=true. The lab hosts are VMs, so this harness sets
    that variable for the remediation run.

    EXPECTED OUTCOMES
      TrimDisabled          ExpectFixed. DisableDeleteNotification set to 1.
                            Validate: DisableDeleteNotification = 0.
      OptimizeTaskDisabled  ExpectFixed. ScheduledDefrag disabled.
                            Validate: the task is no longer disabled.

    Not covered, and why:
      Step 1 Drive Health, step 2 Storage Errors In Event Log, step 7 Boot Drive Type
          -- hardware facts and event log history; no reversible lab fault. The
             deduction table is covered by Test-StorageHealthScore.ps1 with synthetic
             facts instead.
      Step 3 System Volume Health -- the "scan needed" flag is set by NTFS itself; the
             only way to raise it by hand is the dirty bit, which forces chkdsk at the
             next boot and cannot be cleared again.
      Step 6 Optimize Drives Recency -- the task's last run time cannot be set. Run the
             script once by hand with OptimizeStaleDays=1 on a host whose task last ran
             two or more days ago to see it start the task and report Pending.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateStorageHealth.ps1 and validate the outcome.
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
    How many components to break when selecting randomly. Default 2 (both).

.PARAMETER IncludeRebootBreaks
    Allow breaks that require a reboot to take effect. None here; kept for parity.

.PARAMETER Restore
    Undo an in-flight run's breaks and exit. No remediation, no validation.

.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot.

.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Invoke-AutoRemediateStorageHealth_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated) or SYSTEM
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-16
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateStorageHealth\

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

$ScriptUnderTest   = 'Invoke-AutoRemediateStorageHealth'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateStorageHealth.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\SystemHealth\StorageHealth'
$SelfPath          = $MyInvocation.MyCommand.Path

# The lab hosts are virtual machines; without this the script reports steps 4 to 7 as
# "not checked" and repairs nothing. The child powershell.exe inherits the variable.
$env:IncludeVirtualMachines = 'true'

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Fixture ------------------------------------------------------------------
# Both components ship with Windows; nothing is built and nothing is torn down.
$FsKey      = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
$TrimValue  = 'DisableDeleteNotification'
$DefragPath = '\Microsoft\Windows\Defrag\'
$DefragTask = 'ScheduledDefrag'

function Initialize-Fixture {
    if (-not (Get-ScheduledTask -TaskPath $DefragPath -TaskName $DefragTask -ErrorAction SilentlyContinue)) {
        throw "The $DefragTask task does not exist on this host; it cannot carry the OptimizeTaskDisabled break."
    }
}

function Remove-Fixture {
    # Intentionally empty: nothing was created.
}

# -- Helpers ------------------------------------------------------------------

function Get-TrimDisabled {
    # $true when NTFS delete notifications (TRIM) are turned off.
    [int](Get-ItemProperty -LiteralPath $FsKey -Name $TrimValue -ErrorAction SilentlyContinue).$TrimValue -eq 1
}

function Set-TrimDisabled {
    param([Parameter(Mandatory = $true)][bool]$Disabled)
    $flag = if ($Disabled) { '1' } else { '0' }
    $null = & fsutil.exe behavior set DisableDeleteNotify NTFS $flag 2>&1
    if ($LASTEXITCODE -ne 0) { $null = & fsutil.exe behavior set DisableDeleteNotify $flag 2>&1 }
    if ($LASTEXITCODE -ne 0) { throw "fsutil behavior set DisableDeleteNotify $flag exited $LASTEXITCODE" }
}

function Test-DefragTaskDisabled {
    $t = Get-ScheduledTask -TaskPath $DefragPath -TaskName $DefragTask -ErrorAction Stop
    ("$($t.State)" -eq 'Disabled') -or (-not $t.Settings.Enabled)
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
$BreakCatalog = @(

    @{
        Name            = 'TrimDisabled'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                # Script branch: "TRIM is turned off (DisableDeleteNotify = 1)".
                Name  = 'FsutilDisableDeleteNotify'
                Apply = { Set-TrimDisabled -Disabled $true }
            }
        )
        Capture  = { @{ Disabled = [bool](Get-TrimDisabled) } }
        Verify   = { [bool](Get-TrimDisabled) }
        Validate = { -not (Get-TrimDisabled) }
        Restore  = {
            param($Original)
            Set-TrimDisabled -Disabled ([bool]$Original.Disabled)
        }
    },

    @{
        Name            = 'OptimizeTaskDisabled'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                # Script branch: "The Optimize Drives task (ScheduledDefrag) is disabled".
                Name  = 'DisableScheduledDefrag'
                Apply = { Disable-ScheduledTask -TaskPath $DefragPath -TaskName $DefragTask -ErrorAction Stop | Out-Null }
            }
        )
        Capture  = { @{ Disabled = [bool](Test-DefragTaskDisabled) } }
        Verify   = { [bool](Test-DefragTaskDisabled) }
        Validate = { -not (Test-DefragTaskDisabled) }
        Restore  = {
            param($Original)
            if ([bool]$Original.Disabled) {
                Disable-ScheduledTask -TaskPath $DefragPath -TaskName $DefragTask -ErrorAction Stop | Out-Null
            } else {
                Enable-ScheduledTask -TaskPath $DefragPath -TaskName $DefragTask -ErrorAction Stop | Out-Null
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

Write-DexBanner -Title "Invoke-AutoRemediateStorageHealth_BreakTest" -Detail "Environment: $Environment"

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
        # A run whose every break expects a repair must also exit 0: the script's own verdict
        # is what UEM and the DEX console show, so a repaired component with exit 1 is a failure.
        $allFixed = (@($state.Breaks | Where-Object { $_.ExpectedOutcome -ne 'ExpectFixed' }).Count -eq 0)
        if ($failedCount -eq 0 -and $allFixed -and $state.Remediation) {
            $rcOut = [int]$state.Remediation.ExitCode
            if ($rcOut -ne 0) {
                Write-DexStep -Status 'Failed' -Name 'Validate exit code' -Message "script exited $rcOut after repairing every break; expected 0"
                $state.Validation += @{ Name = 'ExitCode'; Expected = 'exit 0 after every break was repaired'; Actual = "exit $rcOut"; Result = 'Fail' }
                $state.Overall = 'Failed'
            } else {
                Write-DexStep -Status 'Passed' -Name 'Validate exit code' -Message 'script exited 0 after repairing every break'
            }
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
