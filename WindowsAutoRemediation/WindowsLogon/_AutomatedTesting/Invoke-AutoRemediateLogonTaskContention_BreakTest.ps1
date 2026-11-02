<#
.SYNOPSIS
    Invoke-AutoRemediateLogonTaskContention_BreakTest -- deliberately registers
    AtLogOn scheduled tasks that contend with logon, then verifies
    Invoke-AutoRemediateLogonTaskContention.ps1 staggers and reports them.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateLogonTaskContention\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It registers scheduled tasks under the
    \DEXTest\ Task Scheduler folder that fire at every user logon (each only runs
    'cmd.exe /c exit 0'), and the remediation it invokes rewrites the trigger Delay
    of EVERY enabled non-Microsoft AtLogOn task on the host, not just the fixtures.
    Run it only on a disposable VM or a marked test host. See Assert-DexTestHost in
    DEXTestFramework.psm1.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the remediation "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES
    Step 2 of Invoke-AutoRemediateLogonTaskContention.ps1 (AtLogOn Task Volume) has
    ResolutionScript = $null by design, so breaking it must NOT expect a repair.
    Each break declares which it is:
      ExpectFixed        -- remediation must repair the component
      ExpectReportedOnly -- remediation must DETECT and report it, and leave it alone

    REPORTED-ONLY VALIDATION
    The script under test records run summaries (LastRun, Warnings, ...) under
    HKLM:\Software\AirWatch\Extensions\LogonTaskContention\Remediation rather than
    per-step DEXRecords values. A report-only break is therefore validated by the
    Warnings counter of a run that started after this test did, plus the step's own
    "[Warning] <step name>:" line in the captured remediation output.

    REBOOTS
    None of the breaks in this catalog needs a reboot; scheduled-task changes are
    live immediately. The reboot plumbing is kept so the harness stays uniform with
    its siblings, and -IncludeRebootBreaks has no effect here.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateLogonTaskContention.ps1 and validate the
    outcome. Without this the script breaks and reports only.

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
    Script Name  : Invoke-AutoRemediateLogonTaskContention_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateLogonTaskContention\

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

$ScriptUnderTest   = 'Invoke-AutoRemediateLogonTaskContention'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateLogonTaskContention.ps1'
# The script under test writes run summaries here (LastRun, Passed, Warnings, Failed,
# RemediationsRun, QualifyingTaskCount, TasksDelayed), not per-step DEXRecords values.
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extensions\LogonTaskContention\Remediation'
$SelfPath          = $MyInvocation.MyCommand.Path

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Fixture ------------------------------------------------------------------
# Every fixture task lives under its own \DEXTest\ folder so nothing the harness
# registers can be confused with a vendor task, and Remove-Fixture can sweep the
# folder without pattern-matching the root namespace.
$FixtureTaskPath      = '\DEXTest\'
$FixtureDelayTask     = 'DEXTest LogonDelay'
$FixtureVolumePrefix  = 'DEXTest LogonVolume'
# Defaults of the script under test. The harness invokes it with no parameters and
# no environment overrides, so these are the thresholds it will apply.
$ScriptMinDelaySeconds   = 60
$ScriptVolumeWarnCount   = 8
# Volume fixtures carry a delay already above MinDelaySeconds so they are pure
# "volume" signal and step 1 has no reason to rewrite them.
$VolumeTaskDelaySeconds  = 90
$VolumeTaskDelayIso      = 'PT1M30S'

function Initialize-Fixture {
    if (-not (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw 'The ScheduledTasks module is not available; cannot build the test fixture.'
    }
    # Tasks are registered by the breaks themselves; there is nothing to pre-create.
    # Register-ScheduledTask creates the \DEXTest\ folder on first use.
}

function Remove-Fixture {
    Get-ScheduledTask -TaskPath $FixtureTaskPath -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -like 'DEXTest*' } |
        ForEach-Object {
            Unregister-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    # Unregister-ScheduledTask leaves the folder behind; only the COM API can drop it.
    try {
        $svc = New-Object -ComObject 'Schedule.Service'
        $svc.Connect()
        $root   = $svc.GetFolder('\')
        $folder = $root.GetFolder('DEXTest')
        if ($folder.GetTasks(1).Count -eq 0) { $root.DeleteFolder('DEXTest', 0) }
    } catch {
        # Folder never existed or is already gone.
    }
}

# -- Helpers ------------------------------------------------------------------

function New-DexLogonTask {
    <#
        Registers an enabled AtLogOn task outside the \Microsoft\ namespace -- exactly
        the shape Invoke-AutoRemediateLogonTaskContention.ps1 scans for. A group
        principal is used so Set-ScheduledTask can rewrite it without a password.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$DelayIso = ''
    )
    $action    = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 0'
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    if ($DelayIso) { $trigger.Delay = $DelayIso }
    $principal = New-ScheduledTaskPrincipal -GroupId 'Users' -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $Name -TaskPath $FixtureTaskPath -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
}

function Get-DexDelaySeconds {
    # Trigger.Delay is an ISO 8601 duration ('PT1M30S'); empty means no delay.
    param([string]$Delay)
    if ([string]::IsNullOrWhiteSpace($Delay)) { return 0 }
    try   { return [int][System.Xml.XmlConvert]::ToTimeSpan($Delay).TotalSeconds }
    catch { return 0 }
}

function Get-DexLogonTriggers {
    param($Task)
    @($Task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })
}

function Get-DexQualifyingLogonTasks {
    # Same filter as the script under test: enabled, outside \Microsoft\, at least one
    # AtLogOn trigger. Used to decide how many volume fixtures are needed and to prove
    # the volume break actually crossed the warn threshold.
    @(
        Get-ScheduledTask -ErrorAction SilentlyContinue |
            Where-Object {
                $_.State -ne 'Disabled' -and
                $_.TaskPath -notlike '\Microsoft\*' -and
                (Get-DexLogonTriggers -Task $_).Count -gt 0
            }
    )
}

function Get-DexFixtureTask {
    param([Parameter(Mandatory = $true)][string]$Name)
    Get-ScheduledTask -TaskPath $FixtureTaskPath -TaskName $Name -ErrorAction SilentlyContinue
}

function Get-DexFixtureVolumeTasks {
    @(
        Get-ScheduledTask -TaskPath $FixtureTaskPath -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskName -like "$FixtureVolumePrefix*" }
    )
}

function Test-DexStepReported {
    <#
        Confirms the remediation script reported a finding for a given report-only
        step. The script under test has no per-step registry record, so two
        independent signals are required: the summary key's Warnings counter from a
        run that started after this test did, and the step's own [Warning] line in
        the captured console output.
    #>
    param([Parameter(Mandatory = $true)][string]$StepName)

    $outputOk = $false
    if ($state -and $state.Remediation -and $state.Remediation.Output) {
        $pattern  = '\[Warning\]\s+' + [regex]::Escape($StepName) + ':'
        $outputOk = ([string]$state.Remediation.Output) -match $pattern
    }

    $regOk = $false
    if (Test-Path -LiteralPath $DexRecordsPath) {
        $key = Get-ItemProperty -LiteralPath $DexRecordsPath -ErrorAction SilentlyContinue
        $lastRun = $null
        if ($key -and $key.LastRun) {
            try { $lastRun = [datetime]::ParseExact([string]$key.LastRun, 'yyyy-MM-dd HH:mm:ss', $null) } catch { $lastRun = $null }
        }
        $started = [datetime]::Parse([string]$state.StartedAt)
        $regOk = $key -and ([int]$key.Warnings -ge 1) -and $lastRun -and ($lastRun -ge $started.AddMinutes(-1))
    }

    return ($outputOk -and $regOk)
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether remediation did its job.
$BreakCatalog = @(

    @{
        # Step 1: AtLogOn Task Trigger Delay. A qualifying task whose logon trigger
        # fires with less than MinDelaySeconds of delay must be raised to at least that.
        Name            = 'AtLogOnTriggerDelay'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'NoDelay'
                Apply = { New-DexLogonTask -Name $FixtureDelayTask }
            },
            @{
                Name  = 'ShortDelay'
                Apply = { New-DexLogonTask -Name $FixtureDelayTask -DelayIso 'PT10S' }
            }
        )
        Capture  = { @{ Existed = [bool](Get-DexFixtureTask -Name $FixtureDelayTask) } }
        Verify   = {
            $t = Get-DexFixtureTask -Name $FixtureDelayTask
            if (-not $t) { return $false }
            $triggers = Get-DexLogonTriggers -Task $t
            if ($triggers.Count -eq 0) { return $false }
            $minDelay = ($triggers | ForEach-Object { Get-DexDelaySeconds $_.Delay } | Measure-Object -Minimum).Minimum
            ($t.State -ne 'Disabled') -and ([int]$minDelay -lt $ScriptMinDelaySeconds)
        }
        # The script promises to raise the Delay and nothing else: the task must still
        # exist, still be enabled, and every logon trigger must now meet the minimum.
        Validate = {
            $t = Get-DexFixtureTask -Name $FixtureDelayTask
            if (-not $t) { return $false }
            $triggers = Get-DexLogonTriggers -Task $t
            if ($triggers.Count -eq 0) { return $false }
            $minDelay = ($triggers | ForEach-Object { Get-DexDelaySeconds $_.Delay } | Measure-Object -Minimum).Minimum
            ($t.State -ne 'Disabled') -and ([int]$minDelay -ge $ScriptMinDelaySeconds)
        }
        Restore  = {
            param($Original)
            if (Get-DexFixtureTask -Name $FixtureDelayTask) {
                Unregister-ScheduledTask -TaskPath $FixtureTaskPath -TaskName $FixtureDelayTask -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    },

    @{
        # Step 2: AtLogOn Task Volume. Report only -- the count of qualifying tasks
        # reaching TaskVolumeWarnCount is flagged for an admin, never auto-trimmed.
        Name            = 'AtLogOnTaskVolume'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                Name  = 'FillToWarnThreshold'
                Apply = {
                    $existing = (Get-DexQualifyingLogonTasks).Count
                    $needed   = [math]::Max(1, $ScriptVolumeWarnCount - $existing)
                    for ($i = 1; $i -le $needed; $i++) {
                        New-DexLogonTask -Name ('{0} {1:D2}' -f $FixtureVolumePrefix, $i) -DelayIso $VolumeTaskDelayIso
                    }
                }
            },
            @{
                Name  = 'ExceedWarnThreshold'
                Apply = {
                    $existing = (Get-DexQualifyingLogonTasks).Count
                    $needed   = [math]::Max(1, $ScriptVolumeWarnCount - $existing) + 2
                    for ($i = 1; $i -le $needed; $i++) {
                        New-DexLogonTask -Name ('{0} {1:D2}' -f $FixtureVolumePrefix, $i) -DelayIso $VolumeTaskDelayIso
                    }
                }
            }
        )
        Capture  = {
            @{
                PreexistingQualifying = (Get-DexQualifyingLogonTasks).Count
                FixtureCount          = (Get-DexFixtureVolumeTasks).Count
            }
        }
        Verify   = {
            ((Get-DexFixtureVolumeTasks).Count -gt 0) -and
            ((Get-DexQualifyingLogonTasks).Count -ge $ScriptVolumeWarnCount)
        }
        # Correct behaviour is to report and leave alone: every volume fixture must
        # still be registered, enabled and carrying its original delay, the host must
        # still be at or over the threshold, and the finding must have been recorded.
        Validate = {
            $fixtures = Get-DexFixtureVolumeTasks
            if ($fixtures.Count -eq 0) { return $false }
            $untouched = $true
            foreach ($t in $fixtures) {
                if ($t.State -eq 'Disabled') { $untouched = $false; break }
                $triggers = Get-DexLogonTriggers -Task $t
                if ($triggers.Count -eq 0) { $untouched = $false; break }
                foreach ($tr in $triggers) {
                    if ((Get-DexDelaySeconds $tr.Delay) -ne $VolumeTaskDelaySeconds) { $untouched = $false; break }
                }
            }
            $stillOver = (Get-DexQualifyingLogonTasks).Count -ge $ScriptVolumeWarnCount
            $reported  = Test-DexStepReported -StepName 'AtLogOn Task Volume'
            $untouched -and $stillOver -and $reported
        }
        Restore  = {
            param($Original)
            foreach ($t in (Get-DexFixtureVolumeTasks)) {
                Unregister-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue
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

Write-DexBanner -Title "Invoke-AutoRemediateLogonTaskContention_BreakTest" -Detail "Environment: $Environment"

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

        # Both breaks act on distinct DEXTest task names and the volume fixtures carry a
        # delay step 1 has no reason to rewrite, so they can share a run; no selection
        # guard is needed.

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
