<#
.SYNOPSIS
    Invoke-SCCMLabRun -- runs the five SCCM client health scripts on a lab client,
    checks their behaviour, and bundles the evidence into one zip.

.DESCRIPTION
    Built for an external SCCM lab where there is no Workspace ONE tenant. Everything
    runs locally on one Configuration Manager client, elevated, in Windows PowerShell 5.1.

    PHASE 1  Baseline. Each script runs once on the client as it is. The harness checks
             that it parses, prints its banner and step lines, exits 0 when nothing is
             Failed, and -- for the three scripts that dispatch a scheduled task -- that
             the task ran, cleaned itself up, and wrote its registry record.

    PHASE 2  Scenarios (opt-in with -IncludeScenarios). Each one captures the current
             state, applies a reversible change, proves the change landed, runs the
             script, checks the documented message and the end state, and restores
             what it captured. Nothing here touches the WMI repository, the client
             cache, or a real install:

               CcmExecStopped        Stop-Service CcmExec; the sweep must restart it.
               CcmExecManualStart    Start type Manual; the sweep must set delayed-auto.
               PolicyLogStale        PolicyAgent.log dated 3 days back; the sweep must
                                     warn and trigger a policy refresh.
               BitsDisabled          BITS Disabled; the BITS script must set it to Manual
                                     and start it.
               ForeignBitsJobKept    A suspended non-CCM BITS job; the BITS script must
                                     report it and must NOT remove it.

    PHASE 3  Bundle. Per-run JSON, every script's raw output, a Summary.csv and a
             LabInfo.json (client version, site, MP, OS) are zipped for return.

    SAFETY
    Refuses to run unless elevated, on Windows PowerShell 5.1, with the test-host
    marker present (C:\Temp\FixReport\.dex-test-machine), with -Force, and with a
    Configuration Manager client installed. Scenarios never run on a device whose
    domain matches -ProductionDomainDenyList.

.PARAMETER Force
    Required. Even the baseline starts services, flushes DNS and triggers policy.

.PARAMETER IncludeScenarios
    Run the reversible scenarios after the baseline.

.PARAMETER Scenario
    Run only the named scenarios. Implies -IncludeScenarios.

.PARAMETER PlanOnly
    Print what would run and exit. Needs nothing on the machine.

.PARAMETER OutputRoot
    Where runs are written. Default C:\Temp\DEXLabRuns.

.PARAMETER TaskWaitSeconds
    How long to wait for a dispatched scheduled task to finish. Default 600.

.NOTES
    Script Name  : Invoke-SCCMLabRun.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated), Windows PowerShell 5.1
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$IncludeScenarios,
    [string[]]$Scenario,
    [switch]$PlanOnly,
    [string]$OutputRoot = 'C:\Temp\DEXLabRuns',
    [int]$TaskWaitSeconds = 600,
    [string[]]$ProductionDomainDenyList = @()
)

$ErrorActionPreference = 'Stop'

$ScriptDir  = Join-Path $PSScriptRoot '..'
$RepoRoot   = Join-Path $PSScriptRoot '..\..\..'
$ModulePath = Join-Path $RepoRoot 'AutomatedTesting\DEXTestFramework.psm1'
$RecordRoot = 'HKLM:\Software\AirWatch\Extension\DEXRecords\SCCM'

# -- The scripts under test ----------------------------------------------------
# Dispatch: $true when the script's launcher registers a scheduled task and exits,
# leaving the real work (and the registry record) to the task.
$Targets = @(
    @{ Name = 'Invoke-AutoRemediateSCCMClient.ps1';        Steps = 14; Dispatch = $false; Record = $null;              Budget = 120 }
    @{ Name = 'Invoke-AutoRemediateWMIRepository.ps1';     Steps = 3;  Dispatch = $true;  Record = 'WMIRepository';    Budget = 300 }
    @{ Name = 'Invoke-AutoRemediateCcmCache.ps1';          Steps = 4;  Dispatch = $true;  Record = 'CcmCache';         Budget = 300 }
    @{ Name = 'Invoke-AutoRemediateBITSBacklog.ps1';       Steps = 3;  Dispatch = $false; Record = $null;              Budget = 60  }
    @{ Name = 'Invoke-AutoRemediateOrphanedCcmSetup.ps1';  Steps = 4;  Dispatch = $true;  Record = 'OrphanedCcmSetup'; Budget = 300 }
)
$DispatchTaskNames = @('DEX_SCCMRemediateWMI', 'DEX_SCCMRemediateCache', 'DEX_SCCMRemediateCcmSetup')

# ==============================================================================
# Helpers
# ==============================================================================

function Write-Line {
    param([string]$Status, [string]$Name, [string]$Message = '')
    $text = "  [$($Status.PadRight(7))] $Name$(if ($Message) { ": $Message" })"
    Write-Output $text
    if ($script:LogPath) { Add-Content -LiteralPath $script:LogPath -Value $text -Encoding UTF8 }
}

function Get-ServiceMode {
    param([string]$Name)
    $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $cim) { return $null }
    return @{ Name = $Name; StartMode = [string]$cim.StartMode; State = [string]$cim.State }
}

function Wait-ServiceState {
    param([string]$Name, [string]$State, [int]$TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
        if ($cim -and $cim.State -eq $State) { return $true }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Restore-ServiceMode {
    # Puts a captured start mode and state back. Auto/Manual/Disabled come from Win32_Service.
    param($Original)
    if (-not $Original) { return }
    $startType = switch ([string]$Original.StartMode) {
        'Auto'     { 'Automatic' }
        'Disabled' { 'Disabled' }
        default    { 'Manual' }
    }
    Set-Service -Name $Original.Name -StartupType $startType -ErrorAction Stop
    if ([string]$Original.State -eq 'Running') {
        if ($startType -ne 'Disabled') { Start-Service -Name $Original.Name -ErrorAction SilentlyContinue }
        [void](Wait-ServiceState -Name $Original.Name -State 'Running' -TimeoutSec 60)
    } else {
        Stop-Service -Name $Original.Name -Force -ErrorAction SilentlyContinue
    }
}

function Wait-DispatchTask {
    # The launcher registers the task and starts it; the payload unregisters it when done.
    # Finished = task gone, or present and not Running.
    param([string]$TaskName, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Start-Sleep -Seconds 5
    do {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task) { return 'Completed' }
        if ($task.State -ne 'Running' -and $task.State -ne 'Queued') {
            # Registered but not running: either it has not started or it finished without cleanup.
            Start-Sleep -Seconds 5
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if (-not $task) { return 'Completed' }
            if ($task.State -ne 'Running') { return 'LeftRegistered' }
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    return 'TimedOut'
}

function Get-Record {
    param([string]$Name)
    $path = Join-Path $RecordRoot $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $p = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
    $o = @{}
    foreach ($n in 'Status', 'LastDispatchTime', 'LastRunTime', 'Passed', 'Warnings', 'Failed', 'RemediationsRun', 'ElementsRemoved', 'MBFreed', 'CcmSetupKilled') {
        if ($p.PSObject.Properties[$n]) { $o[$n] = $p.$n }
    }
    return $o
}

function Invoke-Target {
    <#
        Runs one script as a child Windows PowerShell process the way UEM does (as a file,
        no profile), captures everything, waits for a dispatched task if there is one, and
        returns a result hashtable. Never throws for a failing script; that is a finding.
    #>
    param([hashtable]$Target, [string]$Label)

    $path = Join-Path $ScriptDir $Target.Name
    $started = Get-Date
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | ForEach-Object { "$_" }
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $sw.Stop()
    $text = ($output | Out-String).Trim()

    $result = @{
        Label        = $Label
        Script       = $Target.Name
        StartedAt    = $started.ToString('o')
        ExitCode     = $rc
        DurationSec  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Output       = $text
        TaskState    = $null
        Record       = $null
        StepLines    = @([regex]::Matches($text, '\[(Passed |Warning|Failed )\] ([^:\r\n]+): ([^\r\n]*)') | ForEach-Object {
                           @{ Status = $_.Groups[1].Value.Trim(); Name = $_.Groups[2].Value.Trim(); Message = $_.Groups[3].Value.Trim() } })
        Checks       = @()
        Passed       = $true
    }

    if ($Target.Dispatch) {
        $taskName = switch ($Target.Record) {
            'WMIRepository'    { 'DEX_SCCMRemediateWMI' }
            'CcmCache'         { 'DEX_SCCMRemediateCache' }
            'OrphanedCcmSetup' { 'DEX_SCCMRemediateCcmSetup' }
        }
        $result.TaskState = Wait-DispatchTask -TaskName $taskName -TimeoutSec $TaskWaitSeconds
        $result.Record    = Get-Record -Name $Target.Record
        # The payload's console output goes nowhere under a scheduled task; the registry
        # record is the only evidence of what it did, so the step-line checks use that.
    }

    $raw = Join-Path $script:RunDir ("{0}_{1}.txt" -f $Label, [System.IO.Path]::GetFileNameWithoutExtension($Target.Name))
    Set-Content -LiteralPath $raw -Value $text -Encoding UTF8
    return $result
}

function Add-Check {
    param([hashtable]$Result, [string]$Name, [bool]$Ok, [string]$Detail = '')
    $Result.Checks += @{ Name = $Name; Result = $(if ($Ok) { 'Pass' } else { 'Fail' }); Detail = $Detail }
    if (-not $Ok) { $Result.Passed = $false }
    Write-Line -Status $(if ($Ok) { 'Passed' } else { 'Failed' }) -Name $Name -Message $Detail
}

function Test-Baseline {
    # The checks every script must satisfy on an untouched client.
    param([hashtable]$Target, [hashtable]$R)

    if ($Target.Dispatch) {
        Add-Check $R 'launcher exit 0'      ($R.ExitCode -eq 0) "exit $($R.ExitCode) in $($R.DurationSec)s"
        Add-Check $R 'launcher dispatched'  ($R.Output -match "Task 'DEX_SCCMRemediate\w+' dispatched") ''
        Add-Check $R 'launcher under 30 s'  ($R.DurationSec -lt 30) "$($R.DurationSec)s"
        Add-Check $R 'task finished'        ($R.TaskState -eq 'Completed') $R.TaskState
        $rec = $R.Record
        $hasRec = ($null -ne $rec -and $rec.ContainsKey('LastRunTime'))
        Add-Check $R 'registry record written' $hasRec $(if ($hasRec) { "Status $($rec.Status), Passed $($rec.Passed), Warnings $($rec.Warnings), Failed $($rec.Failed)" } else { "no LastRunTime under $RecordRoot\$($Target.Record)" })
        if ($hasRec) {
            $fresh = $false
            try { $fresh = ([datetime]::Parse($rec.LastRunTime) -ge ([datetime]::Parse($R.StartedAt)).AddSeconds(-5)) } catch { }
            Add-Check $R 'record is from this run' $fresh "LastRunTime $($rec.LastRunTime)"
            $sum = [int]$rec.Passed + [int]$rec.Warnings + [int]$rec.Failed
            Add-Check $R 'record counts every step' ($sum -eq $Target.Steps) "$sum of $($Target.Steps)"
            Add-Check $R 'status matches counts' (($rec.Status -eq 'Failed' -and [int]$rec.Failed -gt 0) -or ($rec.Status -eq 'Warning' -and [int]$rec.Failed -eq 0 -and [int]$rec.Warnings -gt 0) -or ($rec.Status -eq 'Passed' -and [int]$rec.Failed -eq 0 -and [int]$rec.Warnings -eq 0)) "Status $($rec.Status)"
        }
    } else {
        $failed = @($R.StepLines | Where-Object { $_.Status -eq 'Failed' }).Count
        Add-Check $R 'banner printed'       ($R.Output -match 'ResolutionWizard -{5,}') ''
        Add-Check $R 'every step reported'  ($R.StepLines.Count -eq $Target.Steps) "$($R.StepLines.Count) of $($Target.Steps) step lines"
        Add-Check $R 'summary line printed' ($R.Output -match 'Passed: \d+\s+\|\s+Warnings: \d+\s+\|\s+Failed: \d+\s+\|\s+Remediations run: \d+') ''
        Add-Check $R 'exit code matches'    ((($failed -gt 0) -and ($R.ExitCode -eq 1)) -or (($failed -eq 0) -and ($R.ExitCode -eq 0))) "exit $($R.ExitCode), $failed Failed step(s)"
        Add-Check $R 'inside time budget'   ($R.DurationSec -le $Target.Budget) "$($R.DurationSec)s of $($Target.Budget)s"
        Add-Check $R 'no detection exceptions' (-not ($R.Output -match 'Detection exception:')) ''
        Add-Check $R 'no remediation errors'   (-not ($R.Output -match 'Remediation ERROR:')) ''
    }
    Add-Check $R 'no dispatch task left behind' (-not (Get-ScheduledTask -TaskName $DispatchTaskNames -ErrorAction SilentlyContinue)) ''
}

function Test-StepLine {
    # True when the script printed the named step with the status and a message match.
    param([hashtable]$R, [string]$Step, [string]$Status, [string]$Pattern, [switch]$Remediated)
    $line = $R.StepLines | Where-Object { $_.Name -eq $Step } | Select-Object -First 1
    if (-not $line) { return $false }
    if ($line.Status -ne $Status) { return $false }
    if ($Pattern -and ($line.Message -notmatch $Pattern)) { return $false }
    if ($Remediated -and ($line.Message -notmatch '-> Remediation ran')) { return $false }
    return $true
}

# ==============================================================================
# Scenarios: Capture -> Apply -> Verify -> run -> Validate -> Restore
# ==============================================================================

$Scenarios = @(

    @{
        Name    = 'CcmExecStopped'
        Target  = $Targets[0]
        Capture = { Get-ServiceMode -Name 'CcmExec' }
        Apply   = { Stop-Service -Name 'CcmExec' -Force -ErrorAction Stop }
        Verify  = { Wait-ServiceState -Name 'CcmExec' -State 'Stopped' -TimeoutSec 60 }
        Validate = {
            param($R)
            $line = Test-StepLine $R 'CcmExec Service State' 'Failed' 'CcmExec is Stopped' -Remediated
            $back = Wait-ServiceState -Name 'CcmExec' -State 'Running' -TimeoutSec 90
            $mode = (Get-ServiceMode -Name 'CcmExec').StartMode
            Add-Check $R 'step 1 reported Stopped and remediated' $line ''
            Add-Check $R 'CcmExec running again' $back ''
            Add-Check $R 'start mode is Auto (delayed)' ($mode -eq 'Auto') "StartMode $mode"
        }
        Restore = { param($O) Restore-ServiceMode -Original $O }
    },

    @{
        Name    = 'CcmExecManualStart'
        Target  = $Targets[0]
        Capture = { Get-ServiceMode -Name 'CcmExec' }
        Apply   = { Set-Service -Name 'CcmExec' -StartupType Manual -ErrorAction Stop }
        Verify  = { (Get-ServiceMode -Name 'CcmExec').StartMode -eq 'Manual' }
        Validate = {
            param($R)
            $line = Test-StepLine $R 'CcmExec Service State' 'Failed' 'StartMode is Manual' -Remediated
            Start-Sleep -Seconds 3
            $mode = (Get-ServiceMode -Name 'CcmExec').StartMode
            Add-Check $R 'step 1 reported Manual and remediated' $line ''
            Add-Check $R 'start mode is Auto (delayed)' ($mode -eq 'Auto') "StartMode $mode"
            Add-Check $R 'service still running' ((Get-ServiceMode -Name 'CcmExec').State -eq 'Running') ''
        }
        Restore = { param($O) Restore-ServiceMode -Original $O }
    },

    @{
        Name    = 'PolicyLogStale'
        Target  = $Targets[0]
        Capture = {
            $log = Join-Path $env:SystemRoot 'CCM\Logs\PolicyAgent.log'
            if (-not (Test-Path $log)) { throw "PolicyAgent.log not found at $log" }
            @{ Path = $log; LastWriteTime = (Get-Item $log).LastWriteTime.ToString('o') }
        }
        Apply   = {
            $log = Join-Path $env:SystemRoot 'CCM\Logs\PolicyAgent.log'
            (Get-Item $log).LastWriteTime = (Get-Date).AddHours(-72)
        }
        Verify  = {
            $log = Join-Path $env:SystemRoot 'CCM\Logs\PolicyAgent.log'
            ((Get-Date) - (Get-Item $log).LastWriteTime).TotalHours -gt 48
        }
        Validate = {
            param($R)
            $line = Test-StepLine $R 'Policy Retrieval Freshness' 'Warning' 'Last policy activity' -Remediated
            Add-Check $R 'step 8 warned and triggered a refresh' $line ''
            # The triggered machine-policy cycle normally writes PolicyAgent.log within a minute.
            $log = Join-Path $env:SystemRoot 'CCM\Logs\PolicyAgent.log'
            $deadline = (Get-Date).AddSeconds(90); $moved = $false
            do { if ((Get-Item $log).LastWriteTime -gt (Get-Date).AddMinutes(-5)) { $moved = $true; break }; Start-Sleep -Seconds 5 } while ((Get-Date) -lt $deadline)
            Add-Check $R 'PolicyAgent.log written after trigger' $moved $(if ($moved) { '' } else { 'no write within 90 s; check the client can reach its MP' })
        }
        Restore = {
            param($O)
            # Only put the old timestamp back if the client did not write the log itself.
            if ((Get-Item $O.Path).LastWriteTime -lt (Get-Date).AddHours(-24)) {
                (Get-Item $O.Path).LastWriteTime = [datetime]::Parse($O.LastWriteTime)
            }
        }
    },

    @{
        Name    = 'BitsDisabled'
        Target  = $Targets[3]
        Capture = { Get-ServiceMode -Name 'BITS' }
        Apply   = {
            Stop-Service -Name 'BITS' -Force -ErrorAction SilentlyContinue
            Set-Service -Name 'BITS' -StartupType Disabled -ErrorAction Stop
        }
        Verify  = { (Get-ServiceMode -Name 'BITS').StartMode -eq 'Disabled' }
        Validate = {
            param($R)
            $line = Test-StepLine $R 'BITS Service State' 'Failed' 'BITS is Disabled' -Remediated
            Start-Sleep -Seconds 3
            $m = Get-ServiceMode -Name 'BITS'
            Add-Check $R 'step 1 reported Disabled and remediated' $line ''
            Add-Check $R 'BITS start mode is Manual' ($m.StartMode -eq 'Manual') "StartMode $($m.StartMode)"
            Add-Check $R 'BITS started' (Wait-ServiceState -Name 'BITS' -State 'Running' -TimeoutSec 30) ''
        }
        Restore = { param($O) Restore-ServiceMode -Original $O }
    },

    @{
        Name    = 'ForeignBitsJobKept'
        Target  = $Targets[3]
        Capture = { @{ JobName = 'DEXTest-NonCCM-' + (Get-Date -Format 'HHmmss') } }
        Apply   = {
            # A suspended job that is not a Configuration Manager job. The BITS script must
            # list it in step 3 and leave it alone. Stored on the state object by name.
            $dest = Join-Path $env:TEMP 'dex-bits-probe.bin'
            $job  = Start-BitsTransfer -Source 'http://127.0.0.1/dex-lab-probe' -Destination $dest -DisplayName $script:ScenarioState.JobName -Suspended -ErrorAction Stop
            $null = $job
        }
        Verify  = { @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $script:ScenarioState.JobName }).Count -eq 1 }
        Validate = {
            param($R)
            $name = $script:ScenarioState.JobName
            $line = Test-StepLine $R 'Non-CCM Job Survey' 'Warning' ([regex]::Escape($name))
            $still = @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $name }).Count -eq 1
            Add-Check $R 'step 3 reported the foreign job' $line ''
            Add-Check $R 'foreign job NOT removed' $still ''
            Add-Check $R 'step 2 did not act' (Test-StepLine $R 'Stalled CCM Jobs' 'Passed' '') ''
        }
        Restore = {
            param($O)
            Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $O.JobName } | Remove-BitsTransfer -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $env:TEMP 'dex-bits-probe.bin') -Force -ErrorAction SilentlyContinue
        }
    }
)

function Invoke-Scenario {
    param([hashtable]$S)
    Write-Output ''
    Write-Line -Status 'Info' -Name "Scenario $($S.Name)" -Message "target $($S.Target.Name)"
    $script:ScenarioState = $null
    $original = $null
    $result = $null
    try {
        $original = & $S.Capture
        $script:ScenarioState = $original
        & $S.Apply
        $landed = [bool](& $S.Verify)
        if (-not $landed) {
            Write-Line -Status 'Failed' -Name 'Verify' -Message 'the change did not land; the script was not run'
            $result = @{ Label = $S.Name; Script = $S.Target.Name; Passed = $false; Checks = @(@{ Name = 'change landed'; Result = 'Fail'; Detail = '' }); Output = '' }
        } else {
            Write-Line -Status 'Passed' -Name 'Verify' -Message 'change landed'
            $result = Invoke-Target -Target $S.Target -Label $S.Name
            & $S.Validate $result
        }
    } catch {
        Write-Line -Status 'Failed' -Name 'Harness' -Message $_.Exception.Message
        if (-not $result) { $result = @{ Label = $S.Name; Script = $S.Target.Name; Passed = $false; Checks = @(); Output = '' } }
        $result.Passed = $false
        $result.HarnessError = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    } finally {
        try {
            & $S.Restore $original
            Write-Line -Status 'Passed' -Name 'Restore' -Message 'original state put back'
            $result.Restored = $true
        } catch {
            Write-Line -Status 'Failed' -Name 'Restore' -Message "$($_.Exception.Message) -- machine left modified"
            $result.Restored = $false
            $result.Passed = $false
        }
    }
    return $result
}

# ==============================================================================
# Main
# ==============================================================================

$wanted = if ($Scenario) { @($Scenarios | Where-Object { $Scenario -contains $_.Name }) } elseif ($IncludeScenarios) { $Scenarios } else { @() }

if ($PlanOnly) {
    Write-Output ''
    Write-Output 'PLAN -- nothing will run.'
    Write-Output '  Baseline (every script once, client untouched):'
    foreach ($t in $Targets) { Write-Output "    $($t.Name)  steps $($t.Steps)  $(if ($t.Dispatch) { 'dispatches a scheduled task, record ' + $t.Record } else { 'inline' })" }
    Write-Output "  Scenarios ($(@($wanted).Count)):"
    foreach ($s in @($wanted)) { Write-Output "    $($s.Name)  ->  $($s.Target.Name)" }
    if (@($wanted).Count -eq 0) { Write-Output '    (none; add -IncludeScenarios)' }
    Write-Output "  Output: $OutputRoot\SCCM_<timestamp>\ and a zip beside it"
    exit 0
}

# -- Preflight -----------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run this in Windows PowerShell 5.1 (the engine UEM uses), not PowerShell 7.' }
if (-not (Test-Path -LiteralPath $ModulePath)) { throw "DEXTestFramework.psm1 not found at $ModulePath. Copy the whole repo, not just this folder." }
Import-Module $ModulePath -Force
Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList

foreach ($t in $Targets) {
    if (-not (Test-Path -LiteralPath (Join-Path $ScriptDir $t.Name))) { throw "Script under test missing: $($t.Name)" }
}
if (-not (Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue)) { throw 'No CcmExec service on this machine. Run this on a Configuration Manager client.' }
$smsClient = Get-CimInstance -Namespace 'root\ccm' -ClassName 'SMS_Client' -ErrorAction SilentlyContinue
$auth      = Get-CimInstance -Namespace 'root\ccm' -ClassName 'SMS_Authority' -ErrorAction SilentlyContinue | Select-Object -First 1
$os        = Get-CimInstance -ClassName Win32_OperatingSystem

$stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunDir = Join-Path $OutputRoot "SCCM_$stamp"
New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
$script:RunDir  = $RunDir
$script:LogPath = Join-Path $RunDir 'LabRun.log'

Write-DexBanner -Title 'Invoke-SCCMLabRun' -Detail "Client $(if ($smsClient) { $smsClient.ClientVersion } else { 'unknown' })  Site $(if ($auth) { $auth.Name } else { '?' })  MP $(if ($auth) { $auth.CurrentManagementPoint } else { '?' })"

@{
    Machine        = $env:COMPUTERNAME
    OSBuild        = "$($os.Caption) $($os.BuildNumber)"
    ClientVersion  = if ($smsClient) { $smsClient.ClientVersion } else { $null }
    Site           = if ($auth) { $auth.Name } else { $null }
    ManagementPoint = if ($auth) { $auth.CurrentManagementPoint } else { $null }
    CcmExec        = Get-ServiceMode -Name 'CcmExec'
    BITS           = Get-ServiceMode -Name 'BITS'
    StartedAt      = (Get-Date).ToString('o')
    Harness        = '1.0.0'
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $RunDir 'LabInfo.json') -Encoding UTF8

$results = @()

# -- Phase 1: baseline ---------------------------------------------------------
Write-Output ''
Write-Line -Status 'Info' -Name 'Phase 1' -Message 'baseline run of every script'
foreach ($t in $Targets) {
    Write-Output ''
    Write-Line -Status 'Info' -Name $t.Name -Message 'running'
    $r = Invoke-Target -Target $t -Label 'Baseline'
    Test-Baseline -Target $t -R $r
    $results += $r
}

# -- Phase 2: scenarios --------------------------------------------------------
if (@($wanted).Count -gt 0) {
    Write-Output ''
    Write-Line -Status 'Info' -Name 'Phase 2' -Message "$(@($wanted).Count) reversible scenario(s)"
    foreach ($s in @($wanted)) { $results += Invoke-Scenario -S $s }
}

# -- Phase 3: bundle -----------------------------------------------------------
$rows = foreach ($r in $results) {
    [pscustomobject]@{
        Label    = $r.Label
        Script   = $r.Script
        Result   = if ($r.Passed) { 'Pass' } else { 'Fail' }
        ExitCode = $r.ExitCode
        Seconds  = $r.DurationSec
        Checks   = @($r.Checks).Count
        Failed   = @($r.Checks | Where-Object { $_.Result -eq 'Fail' }).Count
        Restored = $r.Restored
        Error    = $r.HarnessError
    }
}
$rows | Export-Csv -LiteralPath (Join-Path $RunDir 'Summary.csv') -NoTypeInformation -Encoding UTF8
$results | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $RunDir 'Results.json') -Encoding UTF8

$zip = "$RunDir.zip"
Compress-Archive -Path (Join-Path $RunDir '*') -DestinationPath $zip -Force

Write-Output ''
Write-Output ('-' * 64)
$rows | Format-Table Label, Script, Result, ExitCode, Seconds, Failed, Restored -AutoSize | Out-String -Width 160 | Write-Output
$failTotal = @($rows | Where-Object { $_.Result -eq 'Fail' }).Count
Write-Output "  Runs: $($rows.Count)   Failed: $failTotal"
Write-Output "  Send back: $zip"
Write-Output ('-' * 64)

if ($failTotal -gt 0) { exit 1 }
exit 0
