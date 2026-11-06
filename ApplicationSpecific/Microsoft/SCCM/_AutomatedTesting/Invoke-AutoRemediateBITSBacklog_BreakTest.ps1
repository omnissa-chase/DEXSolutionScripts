<#
.SYNOPSIS
    Invoke-AutoRemediateBITSBacklog_BreakTest -- deliberately disables or stops the
    BITS service and plants a foreign (non-CCM) BITS job, then verifies
    Invoke-AutoRemediateBITSBacklog.ps1 repairs the service, reports the foreign job
    and leaves it alone.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateBITSBacklog\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It stops BITS, sets it Disabled, and
    queues a BITS job of its own. Run it only on a disposable VM or a marked test
    host. See Assert-DexTestHost in DEXTestFramework.psm1.

    WHAT IS BEING TESTED
    Invoke-AutoRemediateBITSBacklog.ps1 runs three steps inline (no scheduled task,
    no DEXRecords key; the console output and exit code are the whole contract):
      1  BITS Service State    Failed only when BITS is Disabled; fixed with
                               'sc config start= demand' + 'sc start'. Stopped is
                               explicitly Passed (BITS is trigger-started).
      2  Stalled CCM Jobs      Removes 'CCMDTS*' jobs that are Error > 4 h or
                               Suspended > 24 h. Nothing else is ever removed.
      3  Non-CCM Job Survey    Report only. Warning when a non-CCM job is Error or
                               Suspended, naming up to three; Passed otherwise.
    The engine exits 1 whenever any step detected Failed, even after a successful
    remediation, so BitsDisabled expects exit 1 and the reported-only breaks exit 0.

    BREAKS
      BitsDisabled        ExpectFixed. BITS stopped and Disabled (Set-Service or
                          sc.exe). Step 1 must report 'BITS is Disabled', run its
                          remediation, leave StartMode Manual and the service Running.
      BitsStopped         ExpectReportedOnly. BITS stopped with its start type intact.
                          Step 1 must report 'BITS is Stopped' as Passed and must NOT
                          remediate; the start type must be untouched. (The script's
                          own Get-BitsTransfer in step 2 trigger-starts BITS as a side
                          effect; that is not a remediation and is not asserted.)
                          On an idle host BITS is normally already Stopped, so this
                          break confirms the 'Stopped is normal' promise rather than
                          injecting a change; Restore puts the captured state back.
      ForeignStalledJob   ExpectReportedOnly. A BITS job owned by the harness user,
                          DisplayName 'DEXTest-Foreign-<TestId>', source
                          http://198.51.100.1/dextest (TEST-NET-1, unroutable).
                            SuspendedJob      created -Suspended: step 3 must Warn and
                                              name it; the job must still exist.
                            UnreachableSource created -Asynchronous: it sits in
                                              Connecting/TransientError, which the
                                              script deliberately does not treat as
                                              stalled, so step 3 must report it present
                                              and healthy; the job must still exist.
                          Step 2 must report 'No Configuration Manager BITS jobs
                          queued' in both cases.

    SELECTION RULES
    BitsDisabled supersedes BitsStopped (a Disabled service is also stopped and step 1
    can only report one of them), so BitsStopped is dropped when both are drawn.
    ForeignStalledJob is always applied before a service break so the job can be
    queued while BITS is startable; when BITS is not Running at verify time the job
    cannot be enumerated without trigger-starting the service and undoing the other
    break, so Verify falls back to the JobId Start-BitsTransfer returned (a job id
    exists only if BITS accepted and persisted the job).

    WHAT IS NOT COVERED
    The step 2 CCM path. There is no Configuration Manager client on the test host,
    so step 2 is Passed by design on every run here. A fake 'CCMDTS*' job is not
    planted: the harness only ever creates jobs named DEXTest*, and the script's age
    gate (CreationTime older than 4 h / 24 h) cannot be satisfied by a job created
    during the run anyway. The age gate itself is therefore untested. The harness
    never cancels or completes a BITS job it did not create.

    REBOOTS
    No break in this catalog needs a reboot. The reboot plumbing (-Resume) is
    retained for parity with the other break tests.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateBITSBacklog.ps1 and validate the outcome.
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

.PARAMETER Restore
    Undo an in-flight run's breaks and exit. No remediation, no validation.

.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot.

.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Invoke-AutoRemediateBITSBacklog_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/arm64)
    Context      : Administrator (elevated), Windows PowerShell 5.1
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateBITSBacklog\

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

$ScriptUnderTest   = 'Invoke-AutoRemediateBITSBacklog'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateBITSBacklog.ps1'
# The script writes no DEXRecords key; it reports by console output and exit code only.
$DexRecordsPath    = $null
$SelfPath          = $MyInvocation.MyCommand.Path
# Pin the engine UEM uses; the harness may itself have been started from pwsh.
$WinPS             = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$modulePath = Join-Path $PSScriptRoot '..\..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force
Import-Module BitsTransfer -ErrorAction Stop

$ForeignJobSource = 'http://198.51.100.1/dextest'   # TEST-NET-1: never routable
$ForeignJobPrefix = 'DEXTest-Foreign-'

# -- Fixture ------------------------------------------------------------------
function Initialize-Fixture {
    if (-not (Test-Path -LiteralPath $RemediationScript)) { throw "Script under test missing: $RemediationScript" }
    if (-not (Get-Service -Name 'BITS' -ErrorAction SilentlyContinue)) { throw 'No BITS service on this machine.' }
    # Jobs left by an aborted earlier run carry this harness's prefix and nothing else does.
    $stale = @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "$ForeignJobPrefix*" })
    foreach ($j in $stale) {
        Remove-BitsTransfer -BitsJob $j -ErrorAction SilentlyContinue
        Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Removed stale harness job '$($j.DisplayName)'"
    }
}

function Remove-Fixture {
    # Per-break Restore removes the job it created; nothing else to tear down.
}

# -- Helpers ------------------------------------------------------------------

function Add-HarnessError {
    # Every catch funnels here so the result's HarnessError carries message and line.
    param([Parameter(Mandatory = $true)][hashtable]$State, [Parameter(Mandatory = $true)]$ErrorRecord)
    $text = "$($ErrorRecord.Exception.Message) (line $($ErrorRecord.InvocationInfo.ScriptLineNumber))"
    $State.HarnessError = if ($State.HarnessError) { "$($State.HarnessError); $text" } else { $text }
}

function Get-ServiceCim {
    param([Parameter(Mandatory = $true)][string]$Name)
    # CIM reads the SCM record without touching the service; Get-BitsTransfer would trigger-start it.
    Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
}

function ConvertTo-StartupType {
    param([string]$StartMode)
    switch ($StartMode) {
        'Auto'     { 'Automatic' }
        'Manual'   { 'Manual'    }
        'Disabled' { 'Disabled'  }
        default    { 'Manual'    }
    }
}

function Get-BitsSnapshot {
    $cim = Get-ServiceCim -Name 'BITS'
    @{ StartMode = "$($cim.StartMode)"; State = "$($cim.State)" }
}

function Restore-BitsSnapshot {
    param([Parameter(Mandatory = $true)]$Snapshot)
    Set-Service -Name 'BITS' -StartupType (ConvertTo-StartupType $Snapshot.StartMode) -ErrorAction SilentlyContinue
    if ($Snapshot.State -eq 'Running') {
        Start-Service -Name 'BITS' -ErrorAction SilentlyContinue
    } else {
        # The script (sc start) and its own Get-BitsTransfer both leave BITS Running.
        Stop-Service -Name 'BITS' -Force -ErrorAction SilentlyContinue
    }
}

function Get-BitsStartMode { "$((Get-ServiceCim -Name 'BITS').StartMode)" }
function Test-BitsRunning  { "$((Get-ServiceCim -Name 'BITS').State)" -eq 'Running' }

function Wait-ServiceState {
    param([string]$Name, [string]$State, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        if ("$((Get-ServiceCim -Name $Name).State)" -eq $State) { return $true }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-HarnessJobs {
    # Plain enumeration on purpose: callers wrap in @(). Trigger-starts BITS when it is Stopped.
    param([Parameter(Mandatory = $true)][string]$Name)
    return @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $Name })
}

function Get-HarnessJobFiles {
    <#
        Files the job may have left in its destination directory: the destination
        itself plus BITS's BIT*.tmp staging file. One array object always comes back
        (leading comma), so a single path is not unrolled into a bare string.
    #>
    param([Parameter(Mandatory = $true)][string]$Destination)
    $dir  = Split-Path -Path $Destination -Parent
    $leaf = Split-Path -Path $Destination -Leaf
    $hits = @(Get-ChildItem -LiteralPath $dir -Filter "$leaf*" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    return ,[string[]]@($hits)
}

function Get-RemediationStepLine {
    <#
        Parses one '[Status ] Name: message' line out of the captured console output.
        Returns @{ Status; Message } or $null. Validate casts its own result with [bool],
        so this helper must stay silent on the output stream apart from its return.
    #>
    param([Parameter(Mandatory = $true)][string]$Step)
    if (-not $script:state.Remediation) { return $null }
    $text = [string]$script:state.Remediation.Output
    $m = [regex]::Match($text, '\[(Passed |Warning|Failed )\] ' + [regex]::Escape($Step) + ': ([^\r\n]*)')
    if (-not $m.Success) { return $null }
    return @{ Status = $m.Groups[1].Value.Trim(); Message = $m.Groups[2].Value.Trim() }
}

function Test-StepLine {
    # True when the script printed the step with the status, an optional message match,
    # and the expected presence or absence of the '-> Remediation ran' suffix.
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Pattern = '',
        [bool]$Remediated = $false
    )
    $line = Get-RemediationStepLine -Step $Step
    if (-not $line) { Write-Host "    [detail] step '$Step' not found in output" -ForegroundColor Red; return $false }
    $ok = $true
    if ($line.Status -ne $Status) { Write-Host "    [detail] step '$Step' is $($line.Status), expected $Status" -ForegroundColor Red; $ok = $false }
    if ($Pattern -and ($line.Message -notmatch $Pattern)) { Write-Host "    [detail] step '$Step' message '$($line.Message)' does not match '$Pattern'" -ForegroundColor Red; $ok = $false }
    $ran = $line.Message -match '-> Remediation ran'
    if ($ran -ne $Remediated) { Write-Host "    [detail] step '$Step' remediation ran=$ran, expected $Remediated" -ForegroundColor Red; $ok = $false }
    if ($line.Message -match 'Remediation ERROR:') { Write-Host "    [detail] step '$Step' reported a remediation error" -ForegroundColor Red; $ok = $false }
    return $ok
}

function Test-RemediationExitCode {
    param([Parameter(Mandatory = $true)][int]$Expected)
    if (-not $script:state.Remediation) { Write-Host '    [detail] no remediation result recorded' -ForegroundColor Red; return $false }
    $actual = [int]$script:state.Remediation.ExitCode
    if ($actual -ne $Expected) { Write-Host "    [detail] exit code $actual, expected $Expected" -ForegroundColor Red }
    return ($actual -eq $Expected)
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Apply receives the captured hashtable and may fill
# in what it created. Verify proves the break landed. Validate receives the original
# state and decides whether remediation did its job. ApplyOrder sorts a multi-break run.
$BreakCatalog = @(

    @{
        Name            = 'ForeignStalledJob'
        ExpectedOutcome = 'ExpectReportedOnly'
        ExpectedText    = 'foreign DEXTest job reported by step 3 and left in the queue; step 2 saw no CCM jobs'
        RequiresReboot  = $false
        ApplyOrder      = 1
        Methods         = @(
            @{
                # Suspended is one of the two states step 3 calls stalled.
                Name  = 'SuspendedJob'
                Apply = {
                    param($Original)
                    $job = Start-BitsTransfer -Source $ForeignJobSource -Destination $Original.Destination `
                               -DisplayName $Original.JobName -Suspended -ErrorAction Stop
                    $Original.JobId       = "$($job.JobId)"
                    $Original.ExpectStep3 = 'Warning'
                }
            },
            @{
                # Connecting/TransientError against an unroutable host: BITS keeps retrying
                # and the script deliberately does not call that stalled.
                Name  = 'UnreachableSource'
                Apply = {
                    param($Original)
                    $job = Start-BitsTransfer -Source $ForeignJobSource -Destination $Original.Destination `
                               -DisplayName $Original.JobName -Asynchronous -ErrorAction Stop
                    $Original.JobId       = "$($job.JobId)"
                    $Original.ExpectStep3 = 'Passed'
                }
            }
        )
        Capture  = {
            # Service snapshot first: the job enumeration below trigger-starts BITS.
            $bits  = Get-BitsSnapshot
            $other = @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue |
                       Where-Object { $_.DisplayName -notlike 'CCMDTS*' -and $_.JobState -in 'Error', 'Suspended' })
            @{
                JobName                 = "$ForeignJobPrefix$($script:state.TestId)"
                Destination             = Join-Path $env:TEMP "DEXTest-bits-$($script:state.TestId).bin"
                JobId                   = ''
                ExpectStep3             = ''
                PreexistingStalledOther = $other.Count
                Bits                    = $bits
            }
        }
        Verify   = {
            param($Original)
            if (Test-BitsRunning) {
                $n = @(Get-HarnessJobs -Name $Original.JobName).Count
                if ($n -ne 1) { Write-Host "    [detail] $n job(s) named '$($Original.JobName)', expected 1" -ForegroundColor Red }
                $n -eq 1
            } else {
                # A service break landed after this one; enumerating now would start BITS.
                Write-Host "    [detail] BITS not running; trusting JobId '$($Original.JobId)' returned at creation" -ForegroundColor Gray
                -not [string]::IsNullOrEmpty([string]$Original.JobId)
            }
        }
        Validate = {
            param($Original)
            $ok = $true
            $jobs = @(Get-HarnessJobs -Name $Original.JobName)
            if ($jobs.Count -ne 1) { Write-Host "    [detail] job '$($Original.JobName)' count $($jobs.Count) after remediation, expected 1 (never removed)" -ForegroundColor Red; $ok = $false }
            else { Write-Host "    [detail] job still queued in state $($jobs[0].JobState)" -ForegroundColor Gray }
            if (-not (Test-StepLine -Step 'Stalled CCM Jobs' -Status 'Passed' -Pattern 'No Configuration Manager BITS jobs queued')) { $ok = $false }

            $pre = [int]$Original.PreexistingStalledOther
            if ($Original.ExpectStep3 -eq 'Warning') {
                # Step 3 names at most three stalled jobs; ours is only guaranteed a mention when fewer than three others exist.
                $pattern = if ($pre -lt 3) { [regex]::Escape($Original.JobName) } else { 'stalled non-CCM BITS job' }
                if (-not (Test-StepLine -Step 'Non-CCM Job Survey' -Status 'Warning' -Pattern $pattern)) { $ok = $false }
            } elseif ($pre -gt 0) {
                Write-Host "    [detail] $pre stalled non-CCM job(s) already on the host; step 3 Warning accepted" -ForegroundColor Gray
                $line = Get-RemediationStepLine -Step 'Non-CCM Job Survey'
                if (-not $line -or $line.Status -ne 'Warning') { Write-Host '    [detail] step 3 missing or not Warning' -ForegroundColor Red; $ok = $false }
            } else {
                if (-not (Test-StepLine -Step 'Non-CCM Job Survey' -Status 'Passed' -Pattern 'present and healthy -- not touched')) { $ok = $false }
            }
            $ok
        }
        Restore  = {
            param($Original)
            foreach ($j in @(Get-HarnessJobs -Name $Original.JobName)) { Remove-BitsTransfer -BitsJob $j -ErrorAction SilentlyContinue }
            foreach ($f in (Get-HarnessJobFiles -Destination $Original.Destination)) {
                Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            }
            # Removing the job trigger-started BITS; put the captured service state back.
            Restore-BitsSnapshot -Snapshot $Original.Bits
        }
    },

    @{
        Name            = 'BitsStopped'
        ExpectedOutcome = 'ExpectReportedOnly'
        ExpectedText    = 'step 1 reports BITS Stopped as Passed, no remediation, start type untouched'
        RequiresReboot  = $false
        ApplyOrder      = 2
        Methods         = @(
            @{
                Name  = 'StopService'
                Apply = { Stop-Service -Name 'BITS' -Force -ErrorAction Stop }
            },
            @{
                Name  = 'ScStop'
                Apply = {
                    # 1062 = ERROR_SERVICE_NOT_ACTIVE: already stopped, which is the state we want.
                    & sc.exe stop BITS | Out-Null
                    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1062) { throw "sc.exe stop BITS returned $LASTEXITCODE" }
                }
            }
        )
        Capture  = { Get-BitsSnapshot }
        Verify   = { Wait-ServiceState -Name 'BITS' -State 'Stopped' -TimeoutSec 20 }
        Validate = {
            param($Original)
            $ok = $true
            if (-not (Test-StepLine -Step 'BITS Service State' -Status 'Passed' -Pattern 'BITS is Stopped' -Remediated $false)) { $ok = $false }
            $mode = Get-BitsStartMode
            if ($mode -ne "$($Original.StartMode)") { Write-Host "    [detail] StartMode is $mode, was $($Original.StartMode); the script must not touch it" -ForegroundColor Red; $ok = $false }
            if (-not (Test-RemediationExitCode -Expected 0)) { $ok = $false }
            $ok
        }
        Restore  = {
            param($Original)
            Restore-BitsSnapshot -Snapshot $Original
        }
    },

    @{
        Name            = 'BitsDisabled'
        ExpectedOutcome = 'ExpectFixed'
        ExpectedText    = 'step 1 reports BITS Disabled and remediates; StartMode Manual and service Running afterwards'
        RequiresReboot  = $false
        ApplyOrder      = 3
        Methods         = @(
            @{
                Name  = 'SetServiceDisabled'
                Apply = {
                    Stop-Service -Name 'BITS' -Force -ErrorAction SilentlyContinue
                    Set-Service -Name 'BITS' -StartupType Disabled -ErrorAction Stop
                }
            },
            @{
                Name  = 'ScConfigDisabled'
                Apply = {
                    & sc.exe stop BITS | Out-Null
                    & sc.exe config BITS start= disabled | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "sc.exe config BITS start= disabled returned $LASTEXITCODE" }
                }
            }
        )
        Capture  = { Get-BitsSnapshot }
        Verify   = {
            $mode = Get-BitsStartMode
            if ($mode -ne 'Disabled') { Write-Host "    [detail] StartMode is $mode" -ForegroundColor Red }
            $mode -eq 'Disabled'
        }
        Validate = {
            param($Original)
            $ok = $true
            if (-not (Test-StepLine -Step 'BITS Service State' -Status 'Failed' -Pattern 'BITS is Disabled' -Remediated $true)) { $ok = $false }
            $mode = Get-BitsStartMode
            if ($mode -ne 'Manual') { Write-Host "    [detail] StartMode is $mode after remediation, expected Manual" -ForegroundColor Red; $ok = $false }
            if (-not (Wait-ServiceState -Name 'BITS' -State 'Running' -TimeoutSec 30)) { Write-Host '    [detail] BITS not Running within 30 s of remediation' -ForegroundColor Red; $ok = $false }
            # The engine exits 1 whenever a step detected Failed, remediated or not.
            if (-not (Test-RemediationExitCode -Expected 1)) { $ok = $false }
            $ok
        }
        Restore  = {
            param($Original)
            Restore-BitsSnapshot -Snapshot $Original
        }
    }
)

function Get-BreakDefinition {
    param([Parameter(Mandatory = $true)][string]$Name)
    $BreakCatalog | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Resolve-BreakSelection {
    # Drops BitsStopped when BitsDisabled is drawn alongside it and orders what is left
    # so the job is queued before BITS is made unstartable.
    param([Parameter(Mandatory = $true)][object[]]$Selected)
    $list = @($Selected)
    if (($list | Where-Object { $_.Name -eq 'BitsDisabled' }) -and ($list | Where-Object { $_.Name -eq 'BitsStopped' })) {
        $list = @($list | Where-Object { $_.Name -ne 'BitsStopped' })
        Write-DexStep -Status 'Info' -Name 'Selection' -Message 'BitsStopped dropped: BitsDisabled supersedes it; test it alone with -BreakName BitsStopped'
    }
    return ,@($list | Sort-Object { [int]$_.ApplyOrder })
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

Write-DexBanner -Title 'Invoke-AutoRemediateBITSBacklog_BreakTest' -Detail "Environment: $Environment"

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
            Add-HarnessError -State $state -ErrorRecord $_
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
        $baseline = Get-BitsSnapshot
        Write-DexStep -Status 'Info' -Name 'Baseline' -Message "BITS is $($baseline.State), StartMode $($baseline.StartMode); CcmExec $(if (Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue) { 'present' } else { 'absent (step 2 Passed by design)' })"

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
        $selected = Resolve-BreakSelection -Selected @($selected)

        $applied = @()
        foreach ($def in $selected) {
            $method = (Get-DexRandomSubset -InputObject $def.Methods -Random $state.Random -Count 1)[0]

            $original = & $def.Capture
            & $method.Apply $original

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
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "invoking $([System.IO.Path]::GetFileName($RemediationScript)) (no inputs; the script takes none)"

            # The script writes its step lines to stdout; a non-zero exit or a stderr
            # line must not abort the harness, so the preference is relaxed around the call.
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $sw     = [System.Diagnostics.Stopwatch]::StartNew()
                $output = & $WinPS -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1 | ForEach-Object { "$_" }
                $rc     = $LASTEXITCODE
                $sw.Stop()
            } finally {
                $ErrorActionPreference = $prevEap
            }

            $state.Remediation = @{
                ExitCode    = $rc
                DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                Output      = ($output | Out-String).Trim()
            }
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "exit $rc after $($state.Remediation.DurationSec)s"
            foreach ($stepName in 'BITS Service State', 'Stalled CCM Jobs', 'Non-CCM Job Survey') {
                $line = Get-RemediationStepLine -Step $stepName
                if ($line) { Write-DexStep -Status 'Info' -Name "  step '$stepName'" -Message "$($line.Status): $($line.Message)" }
                else       { Write-DexStep -Status 'Warning' -Name "  step '$stepName'" -Message 'no step line in output' }
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
            $passed = [bool](& $def.Validate ([PSCustomObject]$b.OriginalState))

            $validation += @{
                Name     = $b.Name
                Method   = $b.Method
                Expected = $def.ExpectedText
                Actual   = if ($passed) { 'as expected' } else { 'NOT as expected' }
                Result   = if ($passed) { 'Pass' } else { 'Fail' }
            }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) `
                          -Name "Validate $($b.Name)" -Message $def.ExpectedText
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
    Add-HarnessError -State $state -ErrorRecord $_
    if ($state.Overall -eq 'Incomplete') { $state.Overall = 'Failed' }
    $exitCode = 1
}

# -- Restore -------------------------------------------------------------------
# Snapshot environments revert on the host, so restoring here would only add risk.
if ($Environment -eq 'Physical') {
    $restoreFailed = $false
    # Newest-first: the oldest capture is the true baseline and wins by running last.
    $toRestore = @($state.Breaks); [array]::Reverse($toRestore)
    foreach ($b in $toRestore) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
        } catch {
            $restoreFailed = $true
            Add-HarnessError -State $state -ErrorRecord $_
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }
    try { Remove-Fixture } catch { $restoreFailed = $true; Add-HarnessError -State $state -ErrorRecord $_ }

    if ($restoreFailed) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'machine left modified -- manual cleanup required'
    } else {
        $state.Phase = 'Restored'
        $after = Get-BitsSnapshot
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message "machine returned to baseline (BITS $($after.State), StartMode $($after.StartMode))"
    }
}

Unregister-DexTestResume -State $state

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) `
              -Name 'Overall' -Message $state.Overall

Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state

exit $exitCode
