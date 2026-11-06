<#
.SYNOPSIS
    Invoke-AutoRemediateWMIRepository_BreakTest -- exercises the guard, the
    consistent-repository path and the dispatch plumbing of
    Invoke-AutoRemediateWMIRepository.ps1 WITHOUT ever touching the WMI repository.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform
    JSON result to C:\Temp\FixReport\Invoke-AutoRemediateWMIRepository\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DESTRUCTIVE-ADJACENT. It starts a fake blocker process, plants a
    stale scheduled task under the script's own task name, and lets the script
    dispatch its SYSTEM payload. Run it only on a disposable VM or a marked test
    host. See Assert-DexTestHost in DEXTestFramework.psm1.

    ABSOLUTE SAFETY LIMIT
    The WMI repository on the host is never corrupted, reset, salvaged or rebuilt by
    this harness. The salvage path (step 2 Failed -> 'winmgmt /salvagerepository')
    is NOT simulated: there is no reversible way to make /verifyrepository fail
    twice, and a genuine corruption would restart Winmgmt and could drop MOF classes
    third-party agents depend on. Initialize-Fixture runs /verifyrepository itself
    and REFUSES to continue when the repository is not consistent, because the
    script would then salvage it. Every Validate asserts RemediationsRun = 0 and that
    the Winmgmt service still runs under the PID captured before the run.

    WHAT IS BEING TESTED
    Invoke-AutoRemediateWMIRepository.ps1 is a launcher: it stages a copy of itself
    under %ProgramData%\Omnissa\DEX\SCCM, stamps Status=Dispatched in
    HKLM:\Software\AirWatch\Extension\DEXRecords\SCCM\WMIRepository, replaces any
    stale 'DEX_SCCMRemediateWMI' task, registers a new one as SYSTEM, starts it and
    exits 0. The payload (RunAsPayload via environment variable) runs three steps,
    writes Status / LastRunTime / Passed / Warnings / Failed / RemediationsRun to
    the same key and unregisters its task. Its console output goes nowhere, so the
    harness waits for a LastRunTime newer than the launcher call (the way the
    ProcessGraceful harness waits for result.json) and judges from the record.

    BREAKS
      RepositoryConsistent   ExpectReportedOnly. No corruption; the payload must find
                             the repository consistent and do nothing. Methods:
                             NoMutation (record cleared by the fixture) and
                             StaleRecordPresent (two-day-old Failed record with
                             RemediationsRun=1 planted; it must be overwritten).
                             Expected record WITHOUT a CM client (this host): Failed,
                             2/0/1 -- step 3 fails by design because root\ccm is
                             absent. With a client: Passed, 3/0/0. If TrustedInstaller
                             is servicing, step 1 aborts legitimately: Warning 0/3/0
                             is accepted with a note.
      InstallInProgressGuard ExpectReportedOnly. A copy of waitfor.exe named
                             ccmsetup.exe or TSManager.exe is started hidden so step
                             1 finds an 'install in progress'. Expected record:
                             Warning 0/3/0, RemediationsRun 0; the fake process must
                             still be alive afterwards.
      StaleDispatchTask      ExpectFixed. A harmless task ('cmd /c rem DEXTest-...')
                             is pre-registered under the production task name. The
                             launcher must replace it, the payload must run (fresh
                             record) and the task must be gone afterwards.
    RepositoryConsistent is dropped when InstallInProgressGuard is drawn with it
    (the guard changes every count the baseline asserts). Other pairs combine.

    WHAT IS NOT COVERED
    Salvage (step 2 Failed), post-salvage verification, the CcmExec restart inside
    the salvage block, and the /verifyrepository false-positive branch (first check
    fails, second passes) -- all need a repository that reports inconsistent on
    demand. A real ccmsetup.exe or TSManager.exe is never started. The 'root\ccm
    responding' Passed branch of step 3 needs a CM client (see Invoke-SCCMLabRun.ps1).
    If the payload leaves its task registered or never finishes inside the wait,
    Remove-Fixture stops and unregisters it. The DEXRecords key and the staged
    payload copy are the script's own output and are left in place.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateWMIRepository.ps1, wait for the payload
    and validate the outcome. Without this the script breaks and reports only.

.PARAMETER Environment
    Physical (default) restores the machine when the run ends.
    Snapshot skips restore on the assumption the host reverts a checkpoint.

.PARAMETER Seed
    Replays an earlier run's random break selection exactly.

.PARAMETER BreakName
    Force specific breaks instead of a random selection.

.PARAMETER BreakCount
    How many breaks to apply when selecting randomly. Default 2.

.PARAMETER PayloadWaitSec
    How long to wait for the payload's registry record. Default 300.

.PARAMETER Restore
    Undo an in-flight run's breaks and exit. No remediation, no validation.

.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot.

.PARAMETER Force
    Required acknowledgement that this machine will be modified.

.NOTES
    Script Name  : Invoke-AutoRemediateWMIRepository_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/arm64)
    Context      : Administrator (elevated), Windows PowerShell 5.1
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateWMIRepository\

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
    [int]$PayloadWaitSec = 300,
    [switch]$IncludeRebootBreaks,
    [switch]$Restore,
    [switch]$Resume,
    [switch]$Force,
    [string[]]$ProductionDomainDenyList = @()
)

$ErrorActionPreference = 'Stop'

$ScriptUnderTest   = 'Invoke-AutoRemediateWMIRepository'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateWMIRepository.ps1'
$DexRecordsPath    = 'HKLM:\Software\AirWatch\Extension\DEXRecords\SCCM\WMIRepository'
$SelfPath          = $MyInvocation.MyCommand.Path
$WinPS             = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$modulePath = Join-Path $PSScriptRoot '..\..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

# -- Script-under-test artefacts -----------------------------------------------
$PayloadTaskName  = 'DEX_SCCMRemediateWMI'
$PayloadStagePath = Join-Path $env:ProgramData 'Omnissa\DEX\SCCM\Invoke-AutoRemediateWMIRepository.ps1'
$WinmgmtExe       = Join-Path $env:SystemRoot 'System32\wbem\winmgmt.exe'
$FixtureDir       = Join-Path 'C:\Temp\FixReport' "$ScriptUnderTest\fixture"
$StaleTaskMarker  = 'DEXTest-stale-task'
$WaitForExe       = Join-Path $env:SystemRoot 'System32\waitfor.exe'

# -- Fixture ------------------------------------------------------------------
function Initialize-Fixture {
    if (-not (Test-Path -LiteralPath $RemediationScript)) { throw "Script under test missing: $RemediationScript" }
    if (-not (Test-Path -LiteralPath $WinmgmtExe))        { throw "winmgmt.exe not found at $WinmgmtExe" }
    if (-not (Test-Path -LiteralPath $WaitForExe))        { throw "waitfor.exe not found at $WaitForExe (needed for the fake blocker)" }

    # A real install or task sequence means the guard would fire for a real reason.
    foreach ($n in 'ccmsetup', 'TSManager') {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { throw "A real $n.exe is running; not testing underneath an install." }
    }
    # A payload still running could be mid-salvage; never pull the task out from under it.
    $task = Get-PayloadTask
    if ($task -and $task.State -eq 'Running') { throw "Scheduled task '$PayloadTaskName' is running right now; wait for it to finish." }

    # THE safety gate: an inconsistent repository would make -RemediationTest salvage it.
    if (-not (Test-RepositoryConsistent)) {
        throw 'winmgmt /verifyrepository reports the repository is NOT consistent. Refusing: the script would salvage it, and this harness never permits that.'
    }
    Write-DexStep -Status 'Info' -Name 'Fixture' -Message 'WMI repository verified consistent; salvage path unreachable'

    if ($task) {
        Remove-PayloadTask
        Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Removed stale scheduled task '$PayloadTaskName'"
    }
    if (Test-Path -LiteralPath $DexRecordsPath) {
        Remove-Item -LiteralPath $DexRecordsPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-DexStep -Status 'Info' -Name 'Fixture' -Message "Cleared stale DEXRecords at $DexRecordsPath"
    }
    # The child must take the launcher branch; a leaked flag would run the payload inline.
    Remove-Item -Path 'Env:\RunAsPayload' -ErrorAction SilentlyContinue

    Stop-FakeBlockers
    if (-not (Test-Path -LiteralPath $FixtureDir)) { New-Item -ItemType Directory -Path $FixtureDir -Force | Out-Null }
}

function Remove-Fixture {
    if (Get-PayloadTask) {
        Write-DexStep -Status 'Warning' -Name 'Fixture' -Message "payload left '$PayloadTaskName' registered; removing it"
        Remove-PayloadTask
    }
    Stop-FakeBlockers
    Remove-Item -LiteralPath $FixtureDir -Recurse -Force -ErrorAction SilentlyContinue
}

# -- Helpers ------------------------------------------------------------------

function Add-HarnessError {
    param([Parameter(Mandatory = $true)][hashtable]$State, [Parameter(Mandatory = $true)]$ErrorRecord)
    $text = "$($ErrorRecord.Exception.Message) (line $($ErrorRecord.InvocationInfo.ScriptLineNumber))"
    $State.HarnessError = if ($State.HarnessError) { "$($State.HarnessError); $text" } else { $text }
}

function Test-RepositoryConsistent {
    # Read-only. Output stays off the pipeline so Verify blocks can call this directly.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try   { $out = & $WinmgmtExe /verifyrepository 2>&1 | ForEach-Object { "$_" }; $rc = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prevEap }
    Write-Host "    [detail] winmgmt /verifyrepository exit $rc`: $(($out -join ' ').Trim())" -ForegroundColor Gray
    return ($rc -eq 0)
}

function Get-WinmgmtInfo {
    $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='Winmgmt'" -ErrorAction SilentlyContinue
    @{ State = "$($cim.State)"; ProcessId = [int]$cim.ProcessId }
}

function Test-TrustedInstallerRunning { [bool](Get-Process -Name 'TrustedInstaller' -ErrorAction SilentlyContinue) }

function Get-PayloadTask { Get-ScheduledTask -TaskName $PayloadTaskName -ErrorAction SilentlyContinue }

function Remove-PayloadTask {
    $t = Get-PayloadTask
    if (-not $t) { return }
    if ($t.State -eq 'Running') { Stop-ScheduledTask -TaskName $PayloadTaskName -ErrorAction SilentlyContinue }
    Unregister-ScheduledTask -TaskName $PayloadTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Register-StaleDummyTask {
    # Inert: 'cmd /c rem <marker>' with no trigger, under the production task name.
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c rem $StaleTaskMarker"
    $prin   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount
    Register-ScheduledTask -TaskName $PayloadTaskName -Action $action -Principal $prin -Force -ErrorAction Stop | Out-Null
}

function Test-PayloadTaskIsHarnessDummy {
    $t = Get-PayloadTask
    if (-not $t) { return $false }
    return [bool](@($t.Actions | Where-Object { "$($_.Arguments)" -like "*$StaleTaskMarker*" }).Count -gt 0)
}

function Get-PayloadRecord {
    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { return $null }
    $p = Get-ItemProperty -LiteralPath $DexRecordsPath -ErrorAction SilentlyContinue
    $o = @{}
    foreach ($n in 'Status', 'LastDispatchTime', 'LastRunTime', 'Passed', 'Warnings', 'Failed', 'RemediationsRun') {
        if ($p.PSObject.Properties[$n]) { $o[$n] = $p.$n }
    }
    return $o
}

function Test-RecordFresh {
    param($Record, [Parameter(Mandatory = $true)][datetime]$Since)
    if (-not $Record -or -not $Record.ContainsKey('LastRunTime')) { return $false }
    try   { return ([datetime]::Parse([string]$Record.LastRunTime) -ge $Since.AddSeconds(-5)) }
    catch { return $false }
}

function Wait-PayloadRecord {
    <#
        Polls the DEXRecords key for a LastRunTime newer than the launcher call, then
        gives the payload up to 20 s to unregister its own task. Returns a hashtable
        the Validate blocks read from $state.Remediation.Payload.
    #>
    param([Parameter(Mandatory = $true)][datetime]$Since, [int]$TimeoutSec)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $rec = $null
    while ((Get-Date) -lt $deadline) {
        $r = Get-PayloadRecord
        if ($r -and (Test-RecordFresh -Record $r -Since $Since)) { $rec = $r; break }
        Start-Sleep -Seconds 2
    }
    $taskState = 'Completed'
    if ($rec) {
        $endBy = (Get-Date).AddSeconds(20)
        while ((Get-PayloadTask) -and ((Get-Date) -lt $endBy)) { Start-Sleep -Milliseconds 500 }
        if (Get-PayloadTask) { $taskState = 'LeftRegistered' }
    } else {
        $t = Get-PayloadTask
        $taskState = if ($t) { "TimedOut (task $($t.State))" } else { 'TimedOut (no task registered)' }
    }
    return @{ Record = $rec; TaskState = $taskState; WaitedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

function Get-FakeBlockerPaths {
    # Every executable the fixture staged. One array object always (leading comma), so a
    # lone path is not unrolled into a bare string by the caller's assignment.
    $hits = @(Get-ChildItem -LiteralPath $FixtureDir -Filter '*.exe' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    return ,[string[]]@($hits)
}

function Start-FakeBlocker {
    # waitfor.exe copied under the blocker's name and parked on a signal nobody sends.
    # Process name is what step 1 matches; the binary itself is inert.
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)]$Original)
    $exe = Join-Path $FixtureDir "$Name.exe"
    Copy-Item -LiteralPath $WaitForExe -Destination $exe -Force -ErrorAction Stop
    $p = Start-Process -FilePath $exe -ArgumentList @('/T', '1500', "DEXTestWmiGuard$($script:state.TestId)") `
             -WindowStyle Hidden -PassThru -ErrorAction Stop
    $Original.ProcessName = $Name
    $Original.ProcessId   = [int]$p.Id
    $Original.ProcessPath = $exe
}

function Test-FakeBlockerAlive {
    param([Parameter(Mandatory = $true)]$Original)
    $p = Get-Process -Name $Original.ProcessName -ErrorAction SilentlyContinue | Where-Object { $_.Id -eq [int]$Original.ProcessId }
    return [bool]$p
}

function Stop-FakeBlockers {
    # Only processes running from the fixture directory are ever stopped. Looking up by
    # name first keeps .Path reads off protected system processes.
    foreach ($exe in (Get-FakeBlockerPaths)) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($exe)
        foreach ($p in @(Get-Process -Name $base -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        $endBy = (Get-Date).AddSeconds(10)
        do {
            Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $exe)) { break }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $endBy)
    }
}

function Test-LauncherOutcome {
    $rem = $script:state.Remediation
    if (-not $rem) { Write-Host '    [detail] no remediation result recorded' -ForegroundColor Red; return $false }
    $ok = $true
    if ([int]$rem.ExitCode -ne 0) { Write-Host "    [detail] launcher exit $($rem.ExitCode), documented dispatch exit is 0" -ForegroundColor Red; $ok = $false }
    if ([string]$rem.Output -notmatch "Task '$PayloadTaskName' dispatched") { Write-Host "    [detail] launcher did not print the dispatch line; output: $([string]$rem.Output)" -ForegroundColor Red; $ok = $false }
    if ([string]$rem.Output -match '\[ERROR\] Launcher failed') { Write-Host '    [detail] launcher reported a failure' -ForegroundColor Red; $ok = $false }
    return $ok
}

function Test-PayloadInvariants {
    <#
        What every break asserts regardless of counts: launcher dispatched, a record from
        THIS run exists, no remediation ran, Winmgmt was never restarted, task cleaned up.
    #>
    param([Parameter(Mandatory = $true)]$Original)
    $ok = Test-LauncherOutcome
    $payload = $script:state.Remediation.Payload
    if (-not $payload -or -not $payload.Record) {
        Write-Host "    [detail] no fresh payload record within $PayloadWaitSec s ($(if ($payload) { $payload.TaskState } else { 'no wait recorded' }))" -ForegroundColor Red
        return $false
    }
    $rec = $payload.Record
    Write-Host "    [detail] record: Status $($rec.Status), Passed $($rec.Passed), Warnings $($rec.Warnings), Failed $($rec.Failed), RemediationsRun $($rec.RemediationsRun), LastRunTime $($rec.LastRunTime) (task $($payload.TaskState), waited $($payload.WaitedSec)s)" -ForegroundColor Gray
    if ([int]$rec.RemediationsRun -ne 0) { Write-Host '    [detail] RemediationsRun is not 0 -- the payload acted on a consistent repository' -ForegroundColor Red; $ok = $false }
    if ($payload.TaskState -ne 'Completed') { Write-Host "    [detail] payload task state '$($payload.TaskState)'; the payload must unregister its own task" -ForegroundColor Red; $ok = $false }
    $w = Get-WinmgmtInfo
    if ($w.State -ne 'Running') { Write-Host "    [detail] Winmgmt is $($w.State)" -ForegroundColor Red; $ok = $false }
    if ($w.ProcessId -ne [int]$Original.WinmgmtPid) { Write-Host "    [detail] Winmgmt PID $($w.ProcessId) differs from captured $($Original.WinmgmtPid) -- the service was restarted" -ForegroundColor Red; $ok = $false }
    return $ok
}

function Test-RecordCounts {
    param([Parameter(Mandatory = $true)]$Record, [string]$Status, [int]$Passed, [int]$Warnings, [int]$Failed)
    $ok = $true
    if ("$($Record.Status)" -ne $Status)         { Write-Host "    [detail] Status '$($Record.Status)', expected '$Status'" -ForegroundColor Red; $ok = $false }
    if ([int]$Record.Passed   -ne $Passed)       { Write-Host "    [detail] Passed $($Record.Passed), expected $Passed" -ForegroundColor Red; $ok = $false }
    if ([int]$Record.Warnings -ne $Warnings)     { Write-Host "    [detail] Warnings $($Record.Warnings), expected $Warnings" -ForegroundColor Red; $ok = $false }
    if ([int]$Record.Failed   -ne $Failed)       { Write-Host "    [detail] Failed $($Record.Failed), expected $Failed" -ForegroundColor Red; $ok = $false }
    return $ok
}

function New-CommonCapture {
    @{
        WinmgmtPid              = (Get-WinmgmtInfo).ProcessId
        TrustedInstallerRunning = Test-TrustedInstallerRunning
        CcmClientPresent        = [bool](Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue)
    }
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Apply receives the captured hashtable and may fill
# in what it created. Verify proves the break landed. Validate receives the original
# state and decides whether the script behaved. ApplyOrder sorts a multi-break run.
$BreakCatalog = @(

    @{
        Name            = 'RepositoryConsistent'
        ExpectedOutcome = 'ExpectReportedOnly'
        ExpectedText    = 'payload verifies a consistent repository, records the run, salvages nothing, Winmgmt untouched'
        RequiresReboot  = $false
        ApplyOrder      = 1
        Methods         = @(
            @{
                # Nothing to mutate: the fixture cleared the record, the repository is healthy.
                Name  = 'NoMutation'
                Apply = { }
            },
            @{
                # An old Failed record with a remediation count; the payload must overwrite every field.
                Name  = 'StaleRecordPresent'
                Apply = {
                    param($Original)
                    $stamp = (Get-Date).AddDays(-2).ToString('o')
                    if (-not (Test-Path -LiteralPath $DexRecordsPath)) { New-Item -Path $DexRecordsPath -Force -ErrorAction Stop | Out-Null }
                    Set-ItemProperty -Path $DexRecordsPath -Name 'Status'          -Value 'Failed' -Type String
                    Set-ItemProperty -Path $DexRecordsPath -Name 'LastRunTime'     -Value $stamp   -Type String
                    Set-ItemProperty -Path $DexRecordsPath -Name 'Passed'          -Value 0        -Type DWord
                    Set-ItemProperty -Path $DexRecordsPath -Name 'Warnings'        -Value 0        -Type DWord
                    Set-ItemProperty -Path $DexRecordsPath -Name 'Failed'          -Value 3        -Type DWord
                    Set-ItemProperty -Path $DexRecordsPath -Name 'RemediationsRun' -Value 1        -Type DWord
                    $Original.PlantedLastRunTime = $stamp
                }
            }
        )
        Capture  = {
            $c = New-CommonCapture
            $c.PlantedLastRunTime = ''
            $c
        }
        Verify   = {
            # "Broken" here means: healthy repository, Winmgmt up, and no record from this run yet.
            $ok = Test-RepositoryConsistent
            $w  = Get-WinmgmtInfo
            if ($w.State -ne 'Running') { Write-Host "    [detail] Winmgmt is $($w.State)" -ForegroundColor Red; $ok = $false }
            if (Test-RecordFresh -Record (Get-PayloadRecord) -Since ([datetime]::Parse([string]$script:state.StartedAt))) {
                Write-Host '    [detail] a record from this run already exists' -ForegroundColor Red; $ok = $false
            }
            $ok
        }
        Validate = {
            param($Original)
            $ok = Test-PayloadInvariants -Original $Original
            $payload = $script:state.Remediation.Payload
            if ($payload -and $payload.Record) {
                $rec = $payload.Record
                $guardTripped = ([int]$rec.Warnings -eq 3 -and [int]$rec.Passed -eq 0 -and [int]$rec.Failed -eq 0)
                if ($guardTripped) {
                    if ([bool]$Original.TrustedInstallerRunning -or (Test-TrustedInstallerRunning)) {
                        Write-Host '    [detail] step 1 guard aborted on TrustedInstaller (servicing in progress on the host) -- legitimate, accepted' -ForegroundColor Yellow
                        if (-not (Test-RecordCounts -Record $rec -Status 'Warning' -Passed 0 -Warnings 3 -Failed 0)) { $ok = $false }
                    } else {
                        Write-Host '    [detail] step 1 guard aborted but no blocker process is visible' -ForegroundColor Red; $ok = $false
                    }
                } elseif ([bool]$Original.CcmClientPresent) {
                    if (-not (Test-RecordCounts -Record $rec -Status 'Passed' -Passed 3 -Warnings 0 -Failed 0)) { $ok = $false }
                } else {
                    Write-Host '    [detail] no CM client on this host: step 3 Failed (root\ccm absent) is the documented outcome' -ForegroundColor Gray
                    if (-not (Test-RecordCounts -Record $rec -Status 'Failed' -Passed 2 -Warnings 0 -Failed 1)) { $ok = $false }
                }
            }
            $ok
        }
        Restore  = {
            param($Original)
            # Only a planted record the payload never overwrote is removed (break-only run).
            $planted = [string]$Original.PlantedLastRunTime
            if ($planted) {
                $rec = Get-PayloadRecord
                if ($rec -and $rec.ContainsKey('LastRunTime') -and ([string]$rec.LastRunTime -eq $planted)) {
                    Remove-Item -LiteralPath $DexRecordsPath -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    },

    @{
        Name            = 'InstallInProgressGuard'
        ExpectedOutcome = 'ExpectReportedOnly'
        ExpectedText    = 'step 1 sees the fake installer, steps 2-3 skip; record Warning 0/3/0, nothing salvaged, blocker left running'
        RequiresReboot  = $false
        ApplyOrder      = 2
        Methods         = @(
            @{
                Name  = 'FakeCcmSetupProcess'
                Apply = { param($Original) Start-FakeBlocker -Name 'ccmsetup' -Original $Original }
            },
            @{
                Name  = 'FakeTSManagerProcess'
                Apply = { param($Original) Start-FakeBlocker -Name 'TSManager' -Original $Original }
            }
        )
        Capture  = {
            $c = New-CommonCapture
            $c.ProcessName = ''; $c.ProcessId = 0; $c.ProcessPath = ''
            $c
        }
        Verify   = {
            param($Original)
            $alive = Test-FakeBlockerAlive -Original $Original
            if (-not $alive) { Write-Host "    [detail] fake $($Original.ProcessName).exe (PID $($Original.ProcessId)) is not running" -ForegroundColor Red }
            $alive
        }
        Validate = {
            param($Original)
            $ok = Test-PayloadInvariants -Original $Original
            $payload = $script:state.Remediation.Payload
            if ($payload -and $payload.Record) {
                if (-not (Test-RecordCounts -Record $payload.Record -Status 'Warning' -Passed 0 -Warnings 3 -Failed 0)) { $ok = $false }
            }
            if (-not (Test-FakeBlockerAlive -Original $Original)) {
                Write-Host '    [detail] the fake blocker is gone; the script must never kill an installer' -ForegroundColor Red; $ok = $false
            }
            $ok
        }
        Restore  = {
            param($Original)
            $p = Get-Process -Id ([int]$Original.ProcessId) -ErrorAction SilentlyContinue
            if ($p -and ($p.Path -eq [string]$Original.ProcessPath)) {
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                $p.WaitForExit(10000) | Out-Null
            }
            Remove-Item -LiteralPath ([string]$Original.ProcessPath) -Force -ErrorAction SilentlyContinue
        }
    },

    @{
        Name            = 'StaleDispatchTask'
        ExpectedOutcome = 'ExpectFixed'
        ExpectedText    = 'launcher replaces the stale task, payload runs and records, task is gone afterwards'
        RequiresReboot  = $false
        ApplyOrder      = 3
        Methods         = @(
            @{
                Name  = 'DisabledStaleTask'
                Apply = {
                    Register-StaleDummyTask
                    Disable-ScheduledTask -TaskName $PayloadTaskName -ErrorAction Stop | Out-Null
                }
            },
            @{
                # Enabled but triggerless: never runs on its own, still occupies the name.
                Name  = 'EnabledStaleTask'
                Apply = { Register-StaleDummyTask }
            }
        )
        Capture  = { New-CommonCapture }
        Verify   = {
            $dummy = Test-PayloadTaskIsHarnessDummy
            if (-not $dummy) { Write-Host "    [detail] '$PayloadTaskName' is absent or not the harness dummy" -ForegroundColor Red }
            $dummy
        }
        Validate = {
            param($Original)
            $ok = Test-PayloadInvariants -Original $Original
            if (Test-PayloadTaskIsHarnessDummy) { Write-Host '    [detail] the stale dummy task is still registered; the launcher did not replace it' -ForegroundColor Red; $ok = $false }
            $ok
        }
        Restore  = {
            param($Original)
            if (Test-PayloadTaskIsHarnessDummy) { Remove-PayloadTask }
        }
    }
)

function Get-BreakDefinition {
    param([Parameter(Mandatory = $true)][string]$Name)
    $BreakCatalog | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Resolve-BreakSelection {
    param([Parameter(Mandatory = $true)][object[]]$Selected)
    $list = @($Selected)
    if (($list | Where-Object { $_.Name -eq 'InstallInProgressGuard' }) -and ($list | Where-Object { $_.Name -eq 'RepositoryConsistent' })) {
        $list = @($list | Where-Object { $_.Name -ne 'RepositoryConsistent' })
        Write-DexStep -Status 'Info' -Name 'Selection' -Message 'RepositoryConsistent dropped: the guard changes every count it asserts; test it alone with -BreakName RepositoryConsistent'
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

Write-DexBanner -Title 'Invoke-AutoRemediateWMIRepository_BreakTest' -Detail "Environment: $Environment"

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
    try { Remove-Fixture } catch { Add-HarnessError -State $state -ErrorRecord $_ }
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
        $w = Get-WinmgmtInfo
        Write-DexStep -Status 'Info' -Name 'Baseline' -Message "Winmgmt $($w.State) (PID $($w.ProcessId)); CcmExec $(if (Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue) { 'present' } else { 'absent (step 3 Failed by design)' }); TrustedInstaller $(if (Test-TrustedInstallerRunning) { 'running (guard may trip legitimately)' } else { 'idle' }); staged payload copy $(if (Test-Path -LiteralPath $PayloadStagePath) { 'present from an earlier dispatch' } else { 'absent' })"

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
                Write-DexStep -Status 'Passed' -Name "Verify $($b.Name)" -Message 'precondition in place'
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
            # Last-second re-check: the launcher is about to hand a SYSTEM payload the
            # authority to salvage. The fixture already gated on this; refuse if it changed.
            if (-not (Test-RepositoryConsistent)) { throw 'Repository no longer verifies consistent; refusing to dispatch the payload.' }

            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "invoking $([System.IO.Path]::GetFileName($RemediationScript)) (launcher; RunAsPayload unset)"
            Remove-Item -Path 'Env:\RunAsPayload' -ErrorAction SilentlyContinue

            $runStart = Get-Date
            $prevEap  = $ErrorActionPreference
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
                StartedAt   = $runStart.ToString('o')
                Payload     = $null
            }
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "launcher exit $rc after $($state.Remediation.DurationSec)s; waiting up to $PayloadWaitSec s for the payload record"

            $state.Remediation.Payload = Wait-PayloadRecord -Since $runStart -TimeoutSec $PayloadWaitSec
            $p = $state.Remediation.Payload
            if ($p.Record) {
                Write-DexStep -Status 'Info' -Name 'Payload' -Message "record after $($p.WaitedSec)s: Status $($p.Record.Status), Passed $($p.Record.Passed), Warnings $($p.Record.Warnings), Failed $($p.Record.Failed), RemediationsRun $($p.Record.RemediationsRun); task $($p.TaskState)"
            } else {
                Write-DexStep -Status 'Warning' -Name 'Payload' -Message "no fresh record after $($p.WaitedSec)s; task $($p.TaskState)"
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
            # The launcher reported a clean dispatch while the payload's record or the
            # host state did not match -- exactly the gap a dispatch-only exit code hides.
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
if ($Environment -eq 'Physical') {
    $restoreFailed = $false
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
        $w = Get-WinmgmtInfo
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message "machine returned to baseline (Winmgmt $($w.State) PID $($w.ProcessId); no '$PayloadTaskName' task; fixture removed)"
    }
}

Unregister-DexTestResume -State $state

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) `
              -Name 'Overall' -Message $state.Overall

Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state

exit $exitCode
