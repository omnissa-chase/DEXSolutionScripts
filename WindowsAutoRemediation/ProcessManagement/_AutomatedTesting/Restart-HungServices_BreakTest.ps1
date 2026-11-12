<#
.SYNOPSIS
    Restart-HungServices_BreakTest -- installs a small fixture service that can be made
    to hang while starting or stopping, then verifies Restart-HungServices.ps1 recovers
    it, or leaves it alone, as each scenario requires.

.DESCRIPTION
    Restart-HungServices.ps1 takes no input and finds its own targets, so every scenario
    is a machine state plus the outcome one run must produce. Each scenario is its own
    cycle: reset fixture -> apply -> verify -> run -> validate -> reset fixture.
    Writes the uniform JSON result to C:\Temp\FixReport\Restart-HungServices\ for
    Invoke-FixReportAnalysis.ps1.

    THE FIXTURE
    DEXTestHungSvc is a .NET service compiled at run time (Add-Type, Windows PowerShell
    5.1) into C:\Temp\FixReport\Restart-HungServices\fixture\. It reads mode.txt beside
    its exe:
      hangstart-once  OnStart never returns (service stays Start Pending); the mode is
                      rewritten to normal first, so the next start succeeds
      hangstop        OnStop never returns (service stays Stop Pending)
      slowstart       OnStart takes 20 s, then the service runs: slow, not hung
      normal          starts and stops at once
    The service runs as LocalSystem in its own process. It and its folder are removed
    when the run ends. No real service is broken by this harness.

    The script under test acts on every hung service it finds, so a genuinely hung
    service on the host would be recovered by the run as well. Each hung scenario takes
    a little over the script's 60 s watch; the full set runs about seven minutes.

    SCENARIOS
      HungStarting           stuck Start Pending -> process ended, started, Running in
                             a new process, exit 0, one history entry
      HungStoppingAutomatic  Automatic, stuck Stop Pending -> process ended, started
                             again, Running in a new process, exit 0
      HungStoppingManual     Manual, stuck Stop Pending -> process ended, left Stopped,
                             exit 0
      SlowStartNotHung       takes 20 s to start -> "Slow, not hung", same process,
                             Running, no history, exit 0
      CooldownHold           stuck Start Pending, history seeded with two recent
                             recoveries -> "Held:", same process still pending, exit 1
      WhatIfNoAction         stuck Start Pending, WhatIf=true -> "WhatIf:", same process
                             still pending, exit 0

    Not covered: a shared service host and the critical-process guard (the fixture owns
    its process), the deny list, the per-run cap (needs three hung services at once).

.PARAMETER RemediationTest
    Run Restart-HungServices.ps1 after each scenario's state is in place and validate.

.PARAMETER Environment
    Physical (default) removes the fixture when the run ends. Snapshot leaves it.

.PARAMETER Seed
    Replays an earlier run's scenario order. Recorded in the result.

.PARAMETER BreakName
    Run specific scenarios instead of a random selection.

.PARAMETER BreakCount
    How many scenarios to run when selecting randomly. Default 6 (all).

.PARAMETER Restore
    Remove the fixture service and its history after an interrupted run.

.PARAMETER Force
    Required acknowledgement.

.NOTES
    Script Name  : Restart-HungServices_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : Administrator (elevated), Windows PowerShell 5.1 (compiles the fixture)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-12
    Reporting    : C:\Temp\FixReport\Restart-HungServices\

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
    [int]$BreakCount = 6,
    [switch]$IncludeRebootBreaks,
    [switch]$Restore,
    [switch]$Resume,
    [switch]$Force,
    [string[]]$ProductionDomainDenyList = @()
)

$ErrorActionPreference = 'Stop'

$ScriptUnderTest   = 'Restart-HungServices'
$RemediationScript = Join-Path $PSScriptRoot '..\Restart-HungServices.ps1'
$Svc               = 'DEXTestHungSvc'
$FixtureDir        = 'C:\Temp\FixReport\Restart-HungServices\fixture'
$FixtureExe        = Join-Path $FixtureDir 'DEXTestHungSvc.exe'
$ModeFile          = Join-Path $FixtureDir 'mode.txt'
$HistoryKey        = "HKLM:\Software\AirWatch\Extensions\ServiceRecovery\Hung\$Svc"

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "DEXTestFramework.psm1 not found at $modulePath" }
Import-Module $modulePath -Force

$FixtureSource = @'
using System;
using System.IO;
using System.ServiceProcess;
using System.Threading;
public class DexTestHungSvc : ServiceBase {
    static string ModeFile;
    public static void Main(string[] a) {
        ModeFile = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "mode.txt");
        ServiceBase.Run(new DexTestHungSvc());
    }
    public DexTestHungSvc() { ServiceName = "DEXTestHungSvc"; CanStop = true; }
    static string Mode() { try { return File.ReadAllText(ModeFile).Trim(); } catch { return "normal"; } }
    protected override void OnStart(string[] args) {
        string m = Mode();
        if (m == "hangstart-once") { try { File.WriteAllText(ModeFile, "normal"); } catch { } Thread.Sleep(Timeout.Infinite); }
        if (m == "slowstart") { RequestAdditionalTime(60000); Thread.Sleep(20000); }
    }
    protected override void OnStop() { if (Mode() == "hangstop") Thread.Sleep(Timeout.Infinite); }
}
'@

# -- Helpers ------------------------------------------------------------------

function Write-DexNote {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Message = '')
    Write-Host "  [Info   ] $Name$(if ($Message) { ": $Message" })" -ForegroundColor Gray
}

function Get-SvcCim { Get-CimInstance -ClassName Win32_Service -Filter "Name='$Svc'" -ErrorAction SilentlyContinue }

function Get-HistoryCount {
    try { return @((Get-ItemProperty -Path $HistoryKey -Name History -ErrorAction Stop).History | Where-Object { "$_" }).Count } catch { return 0 }
}

function Wait-SvcState {
    param([string]$State, [int]$Seconds = 20)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $c = Get-SvcCim
        if ($c -and $c.State -eq $State) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Reset-Fixture {
    # Back to a clean, stopped, Manual fixture with mode normal and no history.
    $c = Get-SvcCim
    if ($c -and $c.State -ne 'Stopped') {
        Set-Content -LiteralPath $ModeFile -Value 'normal' -Encoding ASCII
        if ([int]$c.ProcessId -gt 4) { Stop-Process -Id ([int]$c.ProcessId) -Force -ErrorAction SilentlyContinue }
        if (-not (Wait-SvcState -State 'Stopped' -Seconds 20)) { throw 'The fixture service did not reach Stopped after its process was ended.' }
    }
    Set-Content -LiteralPath $ModeFile -Value 'normal' -Encoding ASCII
    if ($c) { Set-Service -Name $Svc -StartupType Manual }
    if (Test-Path -LiteralPath $HistoryKey) { Remove-Item -LiteralPath $HistoryKey -Recurse -Force }
}

function Initialize-Fixture {
    Remove-Fixture
    New-Item -ItemType Directory -Path $FixtureDir -Force | Out-Null
    Add-Type -TypeDefinition $FixtureSource -OutputAssembly $FixtureExe -OutputType ConsoleApplication -ReferencedAssemblies 'System.ServiceProcess'
    if (-not (Test-Path -LiteralPath $FixtureExe)) { throw 'The fixture service did not compile.' }
    Set-Content -LiteralPath $ModeFile -Value 'normal' -Encoding ASCII
    New-Service -Name $Svc -BinaryPathName "`"$FixtureExe`"" -DisplayName 'DEX Test Hung Service' -StartupType Manual | Out-Null
    # Prove the fixture is a working service before any scenario leans on it.
    (Get-Service -Name $Svc).Start()
    if (-not (Wait-SvcState -State 'Running' -Seconds 20)) { throw 'The fixture service does not start in normal mode.' }
    (Get-Service -Name $Svc).Stop()
    if (-not (Wait-SvcState -State 'Stopped' -Seconds 20)) { throw 'The fixture service does not stop in normal mode.' }
}

function Remove-Fixture {
    $c = Get-SvcCim
    if ($c) {
        if ([int]$c.ProcessId -gt 4) { Stop-Process -Id ([int]$c.ProcessId) -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
        & sc.exe delete $Svc | Out-Null
    }
    if (Test-Path -LiteralPath $HistoryKey) { Remove-Item -LiteralPath $HistoryKey -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $FixtureDir) {
        Start-Sleep -Seconds 1
        Remove-Item -LiteralPath $FixtureDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Start-FixtureHungStarting {
    # ServiceController.Start returns once the process has connected to the SCM; the
    # service then sits in Start Pending because OnStart never returns.
    Set-Content -LiteralPath $ModeFile -Value 'hangstart-once' -Encoding ASCII
    (Get-Service -Name $Svc).Start()
    if (-not (Wait-SvcState -State 'Start Pending' -Seconds 15)) { throw 'The fixture did not enter Start Pending.' }
    $script:pidBeforeRun = [int](Get-SvcCim).ProcessId
}

function Start-FixtureHungStopping {
    param([string]$StartupType)
    Set-Service -Name $Svc -StartupType $StartupType
    Set-Content -LiteralPath $ModeFile -Value 'hangstop' -Encoding ASCII
    (Get-Service -Name $Svc).Start()
    if (-not (Wait-SvcState -State 'Running' -Seconds 20)) { throw 'The fixture did not start.' }
    $script:pidBeforeRun = [int](Get-SvcCim).ProcessId
    (Get-Service -Name $Svc).Stop()
    if (-not (Wait-SvcState -State 'Stop Pending' -Seconds 15)) { throw 'The fixture did not enter Stop Pending.' }
}

function Test-Pending {
    param([string]$State)
    $c = Get-SvcCim
    Write-DexNote -Name 'Verify' -Message "state=$($c.State) pid=$($c.ProcessId)"
    [bool]($c -and $c.State -eq $State -and [int]$c.ProcessId -gt 4)
}

function Test-Run {
    param([int]$ExitCode, [string]$Contains)
    $r = $script:currentRun
    if (-not $r) { return $false }
    $ok = $true
    if ([int]$r.ExitCode -ne $ExitCode) { $ok = $false; Write-DexNote -Name 'Run' -Message "exit $($r.ExitCode), expected $ExitCode" }
    if ($Contains -and ([string]$r.Output -notlike "*$Contains*")) { $ok = $false; Write-DexNote -Name 'Run' -Message "output did not contain '$Contains'" }
    return $ok
}

# -- Scenario definitions ------------------------------------------------------
$BreakCatalog = @(

    @{
        Name = 'HungStarting'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false; Variables = @{}
        Methods  = @(@{ Name = 'OnStartNeverReturns'; Apply = { Start-FixtureHungStarting } })
        Verify   = { Test-Pending -State 'Start Pending' }
        Validate = {
            $c = Get-SvcCim; $h = Get-HistoryCount
            Write-DexNote -Name 'Validate HungStarting' -Message "state=$($c.State) pid=$($c.ProcessId) (was $($script:pidBeforeRun)) history=$h"
            ($c.State -eq 'Running') -and ([int]$c.ProcessId -ne $script:pidBeforeRun) -and ($h -eq 1) -and (Test-Run -ExitCode 0 -Contains 'the service has been started')
        }
    },

    @{
        Name = 'HungStoppingAutomatic'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false; Variables = @{}
        Methods  = @(@{ Name = 'OnStopNeverReturnsAuto'; Apply = { Start-FixtureHungStopping -StartupType Automatic } })
        Verify   = { Test-Pending -State 'Stop Pending' }
        Validate = {
            $c = Get-SvcCim; $h = Get-HistoryCount
            Write-DexNote -Name 'Validate HungStoppingAutomatic' -Message "state=$($c.State) pid=$($c.ProcessId) (was $($script:pidBeforeRun)) history=$h"
            ($c.State -eq 'Running') -and ([int]$c.ProcessId -ne $script:pidBeforeRun) -and ($h -eq 1) -and (Test-Run -ExitCode 0 -Contains 'the service has been started')
        }
    },

    @{
        Name = 'HungStoppingManual'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false; Variables = @{}
        Methods  = @(@{ Name = 'OnStopNeverReturnsManual'; Apply = { Start-FixtureHungStopping -StartupType Manual } })
        Verify   = { Test-Pending -State 'Stop Pending' }
        Validate = {
            $c = Get-SvcCim; $h = Get-HistoryCount
            $gone = -not (Get-Process -Id $script:pidBeforeRun -ErrorAction SilentlyContinue)
            Write-DexNote -Name 'Validate HungStoppingManual' -Message "state=$($c.State) oldProcessGone=$gone history=$h"
            ($c.State -eq 'Stopped') -and $gone -and ($h -eq 1) -and (Test-Run -ExitCode 0 -Contains 'Left stopped (Manual)')
        }
    },

    @{
        Name = 'SlowStartNotHung'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{}
        Methods  = @(@{ Name = 'OnStartTakes20s'; Apply = {
            Set-Content -LiteralPath $ModeFile -Value 'slowstart' -Encoding ASCII
            (Get-Service -Name $Svc).Start()
            if (-not (Wait-SvcState -State 'Start Pending' -Seconds 10)) { throw 'The fixture did not enter Start Pending.' }
            $script:pidBeforeRun = [int](Get-SvcCim).ProcessId
        } })
        Verify   = { Test-Pending -State 'Start Pending' }
        Validate = {
            $c = Get-SvcCim; $h = Get-HistoryCount
            Write-DexNote -Name 'Validate SlowStartNotHung' -Message "state=$($c.State) pid=$($c.ProcessId) (was $($script:pidBeforeRun)) history=$h"
            ($c.State -eq 'Running') -and ([int]$c.ProcessId -eq $script:pidBeforeRun) -and ($h -eq 0) -and (Test-Run -ExitCode 0 -Contains 'Slow, not hung')
        }
    },

    @{
        Name = 'CooldownHold'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{}
        Methods  = @(@{ Name = 'SeededHistory'; Apply = {
            Start-FixtureHungStarting
            New-Item -Path $HistoryKey -Force | Out-Null
            New-ItemProperty -Path $HistoryKey -Name History -PropertyType MultiString -Force `
                -Value ([string[]]@((Get-Date).AddMinutes(-30).ToString('o'), (Get-Date).AddMinutes(-10).ToString('o'))) | Out-Null
        } })
        Verify   = { (Test-Pending -State 'Start Pending') -and ((Get-HistoryCount) -eq 2) }
        Validate = {
            $c = Get-SvcCim; $h = Get-HistoryCount
            Write-DexNote -Name 'Validate CooldownHold' -Message "state=$($c.State) pid=$($c.ProcessId) (was $($script:pidBeforeRun)) history=$h"
            ($c.State -eq 'Start Pending') -and ([int]$c.ProcessId -eq $script:pidBeforeRun) -and ($h -eq 2) -and (Test-Run -ExitCode 1 -Contains 'Held:')
        }
    },

    @{
        Name = 'WhatIfNoAction'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{ WhatIf = 'true' }
        Methods  = @(@{ Name = 'OnStartNeverReturns'; Apply = { Start-FixtureHungStarting } })
        Verify   = { Test-Pending -State 'Start Pending' }
        Validate = {
            $c = Get-SvcCim; $h = Get-HistoryCount
            Write-DexNote -Name 'Validate WhatIfNoAction' -Message "state=$($c.State) pid=$($c.ProcessId) (was $($script:pidBeforeRun)) history=$h"
            ($c.State -eq 'Start Pending') -and ([int]$c.ProcessId -eq $script:pidBeforeRun) -and ($h -eq 0) -and (Test-Run -ExitCode 0 -Contains 'WhatIf:')
        }
    }
)

function Invoke-ScriptUnderTest {
    param([hashtable]$Variables)
    [Environment]::SetEnvironmentVariable('WhatIf', $(if ($Variables.ContainsKey('WhatIf')) { $Variables['WhatIf'] } else { $null }), 'Process')
    try {
        $sw     = [System.Diagnostics.Stopwatch]::StartNew()
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1
        $rc     = $LASTEXITCODE
        $sw.Stop()
    } finally {
        [Environment]::SetEnvironmentVariable('WhatIf', $null, 'Process')
    }
    return @{ Variables = $Variables; ExitCode = $rc; DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Output = ($output | Out-String).Trim() }
}

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList
Write-DexBanner -Title 'Restart-HungServices_BreakTest' -Detail "Environment: $Environment"

if ($Resume) { throw 'This harness has no reboot resume; nothing here reboots.' }

if ($Restore) {
    Remove-Fixture
    Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'fixture service, folder and history removed'
    $stateFile = "C:\Temp\FixReport\$ScriptUnderTest\state.json"
    if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force }
    exit 0
}

$state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Seed $Seed -Environment $Environment
$state.RemediationTest = [bool]$RemediationTest
Write-DexStep -Status 'Info' -Name 'Context' -Message "TestId $($state.TestId)  Seed $($state.Seed)"

$exitCode = 0; $restoreFailed = $false; $anyBreakFailed = $false
$runs = @(); $validation = @()

try {
    if (-not (Test-Path -LiteralPath $RemediationScript)) { throw "Script under test not found at $RemediationScript" }
    if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run this harness in Windows PowerShell 5.1; the fixture is compiled with the .NET Framework compiler.' }

    Initialize-Fixture
    Write-DexStep -Status 'Passed' -Name 'Fixture' -Message "$Svc compiled, installed, starts and stops"

    $candidates = if ($BreakName) {
        @($BreakCatalog | Where-Object { @($BreakName -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Name })
    } else { @($BreakCatalog) }
    if ($candidates.Count -eq 0) { throw 'No scenario matched the requested selection.' }
    $selected = if ($BreakName) { $candidates } else { Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount }

    foreach ($def in $selected) {
        $method = $def.Methods[0]
        $b = @{ Name = $def.Name; Method = $method.Name; ExpectedOutcome = $def.ExpectedOutcome; RequiresReboot = $false
                Applied = $false; BreakVerified = $false; OriginalState = @{ Fixture = $Svc } }
        $state.Breaks = @($state.Breaks) + @($b)
        Save-DexTestState -State $state

        try {
            Reset-Fixture
            & $method.Apply
            $b.Applied = $true
            Write-DexStep -Status 'Info' -Name "Scenario $($def.Name)" -Message "state '$($method.Name)' applied"

            $b.BreakVerified = [bool](& $def.Verify)
            if (-not $b.BreakVerified) {
                $anyBreakFailed = $true
                Write-DexStep -Status 'Failed' -Name "Verify $($def.Name)" -Message 'state did not land; the run would prove nothing'
                $validation += @{ Name = $def.Name; Expected = 'state in place'; Actual = 'NOT as expected'; Result = 'Fail' }
                continue
            }
            Write-DexStep -Status 'Passed' -Name "Verify $($def.Name)" -Message 'state is in place'
            if (-not $RemediationTest) { continue }

            $script:currentRun = Invoke-ScriptUnderTest -Variables $def.Variables
            $script:currentRun.Scenario = $def.Name
            $runs += $script:currentRun
            Write-DexStep -Status 'Info' -Name "Run $($def.Name)" -Message "exit $($script:currentRun.ExitCode) in $($script:currentRun.DurationSec) s"

            $passed   = [bool](& $def.Validate)
            $expected = if ($def.ExpectedOutcome -eq 'ExpectFixed') { 'hung service recovered' } else { 'reported, left unmodified' }
            $validation += @{ Name = $def.Name; Expected = $expected; Actual = $(if ($passed) { 'as expected' } else { 'NOT as expected' }); Result = $(if ($passed) { 'Pass' } else { 'Fail' }) }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) -Name "Validate $($def.Name)" -Message $expected
            if (-not $passed) { Write-Host $script:currentRun.Output }
        } catch {
            $anyBreakFailed = $true
            Write-DexStep -Status 'Failed' -Name "Scenario $($def.Name)" -Message $_.Exception.Message
            $validation += @{ Name = $def.Name; Expected = 'scenario completes'; Actual = $_.Exception.Message; Result = 'Fail' }
        } finally {
            try { Reset-Fixture } catch { $restoreFailed = $true; Write-DexStep -Status 'Failed' -Name "Reset $($def.Name)" -Message $_.Exception.Message }
            $script:currentRun = $null
            $state.Validation = $validation
            Save-DexTestState -State $state
        }
    }

    $state.Phase = if ($RemediationTest) { 'Validated' } else { 'BreakVerified' }
    if ($runs.Count -gt 0) {
        $state.Remediation = @{
            ExitCode    = ($runs | ForEach-Object { [int]$_.ExitCode } | Measure-Object -Maximum).Maximum
            DurationSec = [math]::Round((($runs | ForEach-Object { $_.DurationSec }) | Measure-Object -Sum).Sum, 1)
            Output      = (($runs | ForEach-Object { "== $($_.Scenario) (exit $($_.ExitCode))`n$($_.Output)" }) -join "`n`n")
            Runs        = $runs
        }
    }
    $failedCount = @($validation | Where-Object { $_.Result -eq 'Fail' }).Count
    $state.Overall = if ($anyBreakFailed) { 'BreakFailed' } elseif (-not $RemediationTest) { 'BreakOnly' } elseif ($failedCount -eq 0) { 'Passed' } else { 'Failed' }

} catch {
    Write-DexStep -Status 'Failed' -Name 'Harness' -Message $_.Exception.Message
    $state.HarnessError = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    if ($state.Overall -eq 'Incomplete') { $state.Overall = 'Failed' }
    $exitCode = 1
}

if ($Environment -eq 'Physical') {
    try { Remove-Fixture } catch { $restoreFailed = $true }
    if ($restoreFailed -or (Get-SvcCim)) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message "fixture not fully removed -- run with -Restore -Force, or sc.exe delete $Svc"
    } else {
        $state.Phase = 'Restored'
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'fixture removed; machine returned to baseline'
    }
}

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) -Name 'Overall' -Message $state.Overall
Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state
exit $exitCode
