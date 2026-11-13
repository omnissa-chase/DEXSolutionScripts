<#
.SYNOPSIS
    Restart-HungApps_BreakTest -- runs a small fixture app that can be made to hang,
    stall or spin, then verifies Restart-HungApps.ps1 ends it, or leaves it alone, as
    each scenario requires.

.DESCRIPTION
    Restart-HungApps.ps1 takes no input and finds its own targets, so every scenario is
    a machine state plus the outcome one run must produce. Each scenario is its own
    cycle: reset -> apply -> verify -> run -> wait for the watchdog -> validate -> reset.
    The script is run the way Hub runs it (Detached): the launcher returns at once and
    the watchdog runs as a scheduled task in the logged-on user's session. The harness
    waits for state\result.json. Writes the uniform JSON result to
    C:\Temp\FixReport\Restart-HungApps\ for Invoke-FixReportAnalysis.ps1.

    THE FIXTURE
    DEXTestHungApp.exe is a one-window .NET app compiled at run time (Add-Type, Windows
    PowerShell 5.1) into C:\Temp\FixReport\Restart-HungApps\fixture\. About 1.5 s after
    its window opens it reads mode.txt beside its exe:
      hang    the UI thread sleeps for ever (not answering, no CPU)
      busy    the UI thread spins (not answering, a full core)
      slow    the UI thread sleeps 30 s, then the app answers again
      normal  nothing; the app answers throughout
    It is started through explorer.exe so that it runs unelevated, as a user's app
    does; the Limited watchdog could not end an elevated one.

    The script under test acts on every hung app in the session, so a genuinely hung
    app on the host would be ended by the run as well. Run this from the logged-on
    user's own elevated prompt (the watchdog runs in that user's session). Each hung
    scenario takes a little over the script's 60 s watch; the full set runs about six
    minutes.

    SCENARIOS
      HungAppEnded       hang -> process ended, one history entry
      BusyAppLeft        busy -> "Busy", same process still running, no history
      SlowAppRecovered   slow -> "Recovered", same process still running, no history
      CooldownHold       hang, history seeded with two recent recoveries -> "Held",
                         same process still running, history still two
      WhatIfNoAction     hang, WhatIf=true -> "WouldEnd", same process still running
      NoHungApps         normal -> the watchdog ends within seconds and does not list
                         the fixture

    Not covered: the deny list, the per-run cap (needs three hung apps), the Explorer
    restart, RelaunchApps, an elevated hung app (reported as Error), the SYSTEM launch
    (the harness runs the launcher as an elevated administrator).

.PARAMETER RemediationTest
    Run Restart-HungApps.ps1 after each scenario's state is in place and validate.
.PARAMETER Environment
    Physical (default) removes the fixture when the run ends. Snapshot leaves it.
.PARAMETER Seed
    Replays an earlier run's scenario order. Recorded in the result.
.PARAMETER BreakName
    Run specific scenarios instead of a random selection.
.PARAMETER BreakCount
    How many scenarios to run when selecting randomly. Default 6 (all).
.PARAMETER Restore
    Remove the fixture and the script's own folder after an interrupted run.
.PARAMETER Force
    Required acknowledgement.

.NOTES
    Script Name  : Restart-HungApps_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : Administrator (elevated) in the logged-on user's session, Windows
                   PowerShell 5.1 (compiles the fixture)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-12
    Reporting    : C:\Temp\FixReport\Restart-HungApps\

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

$ScriptUnderTest   = 'Restart-HungApps'
$RemediationScript = Join-Path $PSScriptRoot '..\Restart-HungApps.ps1'
$App               = 'DEXTestHungApp'
$FixtureDir        = 'C:\Temp\FixReport\Restart-HungApps\fixture'
$FixtureExe        = Join-Path $FixtureDir "$App.exe"
$ModeFile          = Join-Path $FixtureDir 'mode.txt'
$BaseDir           = Join-Path $env:ProgramData 'AirWatch\Extensions\HungApps'
$StateDir          = Join-Path $BaseDir 'state'
$ResultFile        = Join-Path $StateDir 'result.json'
$HistoryFile       = Join-Path $StateDir 'history.json'
$RegPath           = 'HKLM:\Software\AirWatch\Extension\DEXRecords\HungApps'
$TaskName          = 'WS1_HungAppsWatchdog'

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "DEXTestFramework.psm1 not found at $modulePath" }
Import-Module $modulePath -Force

$FixtureSource = @'
using System;
using System.IO;
using System.Threading;
using System.Windows.Forms;
public class DexTestHungApp : Form {
    System.Windows.Forms.Timer t = new System.Windows.Forms.Timer();
    public DexTestHungApp() {
        Text = "DEX Test Hung App"; Width = 360; Height = 120;
        t.Interval = 1500; t.Tick += Tick; t.Start();
    }
    void Tick(object s, EventArgs e) {
        t.Stop();
        string m = "normal";
        try { m = File.ReadAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "mode.txt")).Trim(); } catch { }
        if (m == "hang") Thread.Sleep(Timeout.Infinite);
        if (m == "slow") Thread.Sleep(30000);
        if (m == "busy") { while (true) { } }
    }
    [STAThread] public static void Main() { Application.Run(new DexTestHungApp()); }
}
'@

# -- Helpers ------------------------------------------------------------------

function Write-DexNote {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Message = '')
    Write-Host "  [Info   ] $Name$(if ($Message) { ": $Message" })" -ForegroundColor Gray
}

function Get-FixtureProcs { @(Get-Process -Name $App -ErrorAction SilentlyContinue) }

function Get-HistoryCount {
    # Entries recorded for the fixture in the script's history file.
    try {
        $h = Get-Content -LiteralPath $HistoryFile -Raw -ErrorAction Stop | ConvertFrom-Json
        return @($h.($App.ToLowerInvariant()) | Where-Object { "$_" }).Count
    } catch { return 0 }
}

function Get-Result {
    try { return (Get-Content -LiteralPath $ResultFile -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Get-FixtureOutcome {
    # The watchdog's verdict on the fixture, '' when it is not listed.
    $r = Get-Result
    if (-not $r) { return '' }
    $a = @($r.Apps | Where-Object { $_.Name -eq $App }) | Select-Object -First 1
    if ($a) { return [string]$a.Outcome }
    return ''
}

function Remove-WatchdogTask {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Reset-Fixture {
    # No fixture process, no watchdog task, no result, no history.
    Remove-WatchdogTask
    foreach ($p in Get-FixtureProcs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and (Get-FixtureProcs).Count -gt 0) { Start-Sleep -Milliseconds 300 }
    if ((Get-FixtureProcs).Count -gt 0) { throw 'A fixture process is still running after the end request.' }
    foreach ($f in @($ResultFile, $HistoryFile)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    if (Test-Path -LiteralPath $FixtureDir) { Set-Content -LiteralPath $ModeFile -Value 'normal' -Encoding ASCII }
}

function Initialize-Fixture {
    $script:hadBaseDir = Test-Path -LiteralPath $BaseDir
    $script:hadRegKey  = Test-Path -LiteralPath $RegPath
    Remove-Fixture -KeepScriptFolders
    New-Item -ItemType Directory -Path $FixtureDir -Force | Out-Null
    Add-Type -TypeDefinition $FixtureSource -OutputAssembly $FixtureExe -OutputType WindowsApplication -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'
    if (-not (Test-Path -LiteralPath $FixtureExe)) { throw 'The fixture app did not compile.' }
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    # Prove the fixture is a working, answering app before any scenario leans on it.
    Start-Fixture -Mode 'normal'
    if (-not (Test-FixtureResponding)) { throw 'The fixture app does not answer in normal mode.' }
    Reset-Fixture
}

function Remove-Fixture {
    param([switch]$KeepScriptFolders)
    Remove-WatchdogTask
    foreach ($p in Get-FixtureProcs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    if (Test-Path -LiteralPath $FixtureDir) { Remove-Item -LiteralPath $FixtureDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($KeepScriptFolders) { return }
    # The script's own folder and record key go only when this run created them.
    if (-not $script:hadBaseDir -and (Test-Path -LiteralPath $BaseDir)) { Remove-Item -LiteralPath $BaseDir -Recurse -Force -ErrorAction SilentlyContinue }
    elseif (Test-Path -LiteralPath $StateDir) { foreach ($f in @($ResultFile, $HistoryFile)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
    if (-not $script:hadRegKey -and (Test-Path -LiteralPath $RegPath)) { Remove-Item -LiteralPath $RegPath -Recurse -Force -ErrorAction SilentlyContinue }
}

function Start-Fixture {
    # Started through explorer.exe so the app runs unelevated, like a user's own app.
    param([string]$Mode)
    Set-Content -LiteralPath $ModeFile -Value $Mode -Encoding ASCII
    & explorer.exe $FixtureExe
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $p = Get-FixtureProcs | Select-Object -First 1
        if ($p) { $p.Refresh(); if ($p.MainWindowHandle -ne [IntPtr]::Zero) { break } }
        Start-Sleep -Milliseconds 300
    }
    $p = Get-FixtureProcs | Select-Object -First 1
    if (-not $p) { throw 'The fixture app did not start.' }
    $script:pidBeforeRun = [int]$p.Id
    Start-Sleep -Seconds 4   # past the 1.5 s point where the mode takes effect
}

function Test-FixtureResponding {
    $p = Get-Process -Id $script:pidBeforeRun -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    $p.Refresh()
    return [bool]$p.Responding
}

function Test-FixtureSilent {
    $alive = [bool](Get-Process -Id $script:pidBeforeRun -ErrorAction SilentlyContinue)
    $resp  = Test-FixtureResponding
    Write-DexNote -Name 'Verify' -Message "pid=$($script:pidBeforeRun) alive=$alive answering=$resp"
    $alive -and (-not $resp)
}

function Test-FixtureAlive { [bool](Get-Process -Id $script:pidBeforeRun -ErrorAction SilentlyContinue) }

function Test-Run {
    # The launcher must have dispatched (exit 0) and the watchdog must have reported.
    $r = $script:currentRun
    if (-not $r) { return $false }
    $ok = $true
    if ([int]$r.ExitCode -ne 0) { $ok = $false; Write-DexNote -Name 'Run' -Message "launcher exit $($r.ExitCode), expected 0" }
    if (-not $r.ResultSeen) { $ok = $false; Write-DexNote -Name 'Run' -Message 'the watchdog wrote no result.json' }
    return $ok
}

# -- Scenario definitions ------------------------------------------------------
$BreakCatalog = @(

    @{
        Name = 'HungAppEnded'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false; Variables = @{}
        Methods  = @(@{ Name = 'UiThreadSleepsForever'; Apply = { Start-Fixture -Mode 'hang' } })
        Verify   = { Test-FixtureSilent }
        Validate = {
            $alive = Test-FixtureAlive; $o = Get-FixtureOutcome; $h = Get-HistoryCount
            Write-DexNote -Name 'Validate HungAppEnded' -Message "alive=$alive outcome=$o history=$h"
            (-not $alive) -and ($o -eq 'Ended') -and ($h -eq 1) -and (Test-Run)
        }
    },

    @{
        Name = 'BusyAppLeft'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{}
        Methods  = @(@{ Name = 'UiThreadSpins'; Apply = { Start-Fixture -Mode 'busy' } })
        Verify   = { Test-FixtureSilent }
        Validate = {
            $alive = Test-FixtureAlive; $o = Get-FixtureOutcome; $h = Get-HistoryCount
            Write-DexNote -Name 'Validate BusyAppLeft' -Message "alive=$alive outcome=$o history=$h"
            $alive -and ($o -eq 'Busy') -and ($h -eq 0) -and (Test-Run)
        }
    },

    @{
        Name = 'SlowAppRecovered'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{}
        Methods  = @(@{ Name = 'UiThreadSleeps30s'; Apply = { Start-Fixture -Mode 'slow' } })
        Verify   = { Test-FixtureSilent }
        Validate = {
            $alive = Test-FixtureAlive; $o = Get-FixtureOutcome; $h = Get-HistoryCount
            Write-DexNote -Name 'Validate SlowAppRecovered' -Message "alive=$alive outcome=$o history=$h"
            $alive -and ($o -eq 'Recovered') -and ($h -eq 0) -and (Test-Run)
        }
    },

    @{
        Name = 'CooldownHold'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{}
        Methods  = @(@{ Name = 'SeededHistory'; Apply = {
            Start-Fixture -Mode 'hang'
            $seed = [ordered]@{}
            $seed[$App.ToLowerInvariant()] = @((Get-Date).AddMinutes(-30).ToString('o'), (Get-Date).AddMinutes(-10).ToString('o'))
            [PSCustomObject]$seed | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $HistoryFile -Encoding UTF8
        } })
        Verify   = { (Test-FixtureSilent) -and ((Get-HistoryCount) -eq 2) }
        Validate = {
            $alive = Test-FixtureAlive; $o = Get-FixtureOutcome; $h = Get-HistoryCount
            Write-DexNote -Name 'Validate CooldownHold' -Message "alive=$alive outcome=$o history=$h"
            $alive -and ($o -eq 'Held') -and ($h -eq 2) -and (Test-Run)
        }
    },

    @{
        Name = 'WhatIfNoAction'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{ WhatIf = 'true' }
        Methods  = @(@{ Name = 'UiThreadSleepsForever'; Apply = { Start-Fixture -Mode 'hang' } })
        Verify   = { Test-FixtureSilent }
        Validate = {
            $alive = Test-FixtureAlive; $o = Get-FixtureOutcome; $h = Get-HistoryCount
            Write-DexNote -Name 'Validate WhatIfNoAction' -Message "alive=$alive outcome=$o history=$h"
            $alive -and ($o -eq 'WouldEnd') -and ($h -eq 0) -and (Test-Run)
        }
    },

    @{
        Name = 'NoHungApps'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{}
        Methods  = @(@{ Name = 'AnsweringApp'; Apply = { Start-Fixture -Mode 'normal' } })
        Verify   = {
            $resp = Test-FixtureResponding
            Write-DexNote -Name 'Verify' -Message "pid=$($script:pidBeforeRun) answering=$resp"
            $resp
        }
        Validate = {
            $alive = Test-FixtureAlive; $o = Get-FixtureOutcome; $r = Get-Result
            Write-DexNote -Name 'Validate NoHungApps' -Message "alive=$alive fixtureListed=$([bool]$o) status=$($r.Status) checked=$($r.CheckedCount)"
            $alive -and (-not $o) -and ([int]$r.CheckedCount -ge 1) -and (Test-Run)
        }
    }
)

function Invoke-ScriptUnderTest {
    # Runs the launcher (Detached, as Hub does) and waits for the watchdog's result.json.
    param([hashtable]$Variables)
    [Environment]::SetEnvironmentVariable('WhatIf', $(if ($Variables.ContainsKey('WhatIf')) { $Variables['WhatIf'] } else { $null }), 'Process')
    [Environment]::SetEnvironmentVariable('Mode', $null, 'Process')
    if (Test-Path -LiteralPath $ResultFile) { Remove-Item -LiteralPath $ResultFile -Force }
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $sw     = [System.Diagnostics.Stopwatch]::StartNew()
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1 | ForEach-Object { "$_" }
        $rc     = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
        [Environment]::SetEnvironmentVariable('WhatIf', $null, 'Process')
    }
    $launcherSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $seen = $false
    if ($rc -eq 0) {
        $deadline = (Get-Date).AddSeconds(150)
        while ((Get-Date) -lt $deadline) {
            if (Get-Result) { $seen = $true; break }
            Start-Sleep -Seconds 1
        }
    }
    $sw.Stop()
    $log = ''
    try { $log = (Get-Content -LiteralPath (Join-Path $StateDir 'watchdog.log') -Tail 12 -ErrorAction Stop) -join "`n" } catch { }
    return @{ Variables = $Variables; ExitCode = $rc; LauncherSec = $launcherSec; ResultSeen = $seen
              DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
              Output = (($output | Out-String).Trim() + "`n-- result.json --`n" + $(if ($seen) { Get-Content -LiteralPath $ResultFile -Raw } else { '(none)' }) + "`n-- watchdog.log --`n$log") }
}

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList
Write-DexBanner -Title 'Restart-HungApps_BreakTest' -Detail "Environment: $Environment"

if ($Resume) { throw 'This harness has no reboot resume; nothing here reboots.' }

$script:hadBaseDir = $true; $script:hadRegKey = $true

if ($Restore) {
    Remove-Fixture -KeepScriptFolders
    foreach ($f in @($ResultFile, $HistoryFile)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'fixture app, folder, watchdog task, result and history removed'
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
    Write-DexStep -Status 'Passed' -Name 'Fixture' -Message "$App compiled, starts unelevated and answers"

    $candidates = if ($BreakName) {
        @($BreakCatalog | Where-Object { @($BreakName -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Name })
    } else { @($BreakCatalog) }
    if ($candidates.Count -eq 0) { throw 'No scenario matched the requested selection.' }
    $selected = if ($BreakName) { $candidates } else { Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount }

    foreach ($def in $selected) {
        $method = $def.Methods[0]
        $b = @{ Name = $def.Name; Method = $method.Name; ExpectedOutcome = $def.ExpectedOutcome; RequiresReboot = $false
                Applied = $false; BreakVerified = $false; OriginalState = @{ Fixture = $App } }
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
            Write-DexStep -Status 'Info' -Name "Run $($def.Name)" -Message "launcher exit $($script:currentRun.ExitCode) in $($script:currentRun.LauncherSec) s; watchdog result after $($script:currentRun.DurationSec) s"

            $passed   = [bool](& $def.Validate)
            $expected = if ($def.ExpectedOutcome -eq 'ExpectFixed') { 'hung app ended' } else { 'reported, left unmodified' }
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
    if ($restoreFailed -or (Get-FixtureProcs).Count -gt 0 -or (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'fixture not fully removed -- run with -Restore -Force'
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
