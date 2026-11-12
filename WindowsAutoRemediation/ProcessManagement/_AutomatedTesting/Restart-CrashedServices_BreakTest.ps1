<#
.SYNOPSIS
    Restart-CrashedServices_BreakTest -- crashes the Print Spooler for real (ends
    spoolsv.exe so the SCM logs 7031/7034), then verifies Restart-CrashedServices.ps1
    starts it, or leaves it alone, as each scenario requires.

.DESCRIPTION
    Restart-CrashedServices.ps1 takes no input and finds its own targets, so every
    scenario is a machine state plus the outcome one run must produce. The scenarios
    contradict each other, so each is its own cycle:
    snapshot -> apply -> verify -> run -> validate -> restore.
    Writes the uniform JSON result to C:\Temp\FixReport\Restart-CrashedServices\ for
    Invoke-FixReportAnalysis.ps1.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It ends the Print Spooler process, rewrites
    the Spooler's SCM recovery actions and startup type, stops the Themes service, and
    writes the script's cool-down history for Spooler. All of it is captured first and
    put back. Run it only on a disposable VM or a marked test host. See
    Assert-DexTestHost in DEXTestFramework.psm1.

    SCENARIOS
      CrashedAndStopped    recovery actions cleared, spoolsv ended: crash event logged,
                           Spooler stays Stopped -> started, exit 0, one history entry
      CrashedButRecovered  recovery = restart after 1 s, spoolsv ended: the SCM brings
                           it back -> reported "recovered", same PID after the run, exit 0
      CooldownHold         crashed and stopped, history seeded with two recent starts
                           -> "Held:", still Stopped, exit 1
      DisabledRespected    crashed and stopped, then startup type Disabled
                           -> still Stopped and Disabled, exit 0
      WhatIfNoStart        crashed and stopped, WhatIf=true -> "WhatIf: would start",
                           still Stopped, exit 0
      CleanStopIgnored     Themes stopped cleanly with no crash event in the lookback
                           -> Themes still Stopped, exit 0 (a stopped service alone is
                           never a target)

    RECOVERY ACTIONS
    Cleared and set with sc.exe failure. Restored by writing the captured FailureActions
    registry value back, which is where the SCM reads it from.

    Not covered: the deny list (nothing on it can be crashed safely), Manual services,
    the per-run cap (needs three crashed services at once), a crashed per-user service.

    Any other service on the host that genuinely crashed inside the lookback and is
    stopped will be started by the run as well; that is the script working.

.PARAMETER RemediationTest
    Run Restart-CrashedServices.ps1 after each scenario's state is in place and validate.
    Without this the harness applies, verifies and restores.

.PARAMETER Environment
    Physical (default) restores after every scenario. Snapshot skips restore.

.PARAMETER Seed
    Replays an earlier run's scenario order. Recorded in the result.

.PARAMETER BreakName
    Run specific scenarios instead of a random selection.

.PARAMETER BreakCount
    How many scenarios to run when selecting randomly. Default 6 (all).

.PARAMETER Restore
    Put the Spooler, Themes and the cool-down history back after an interrupted run.

.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Restart-CrashedServices_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-12
    Reporting    : C:\Temp\FixReport\Restart-CrashedServices\

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

$ScriptUnderTest   = 'Restart-CrashedServices'
$RemediationScript = Join-Path $PSScriptRoot '..\Restart-CrashedServices.ps1'
$Svc               = 'Spooler'
$CleanSvc          = 'Themes'
$SvcRegKey         = "HKLM:\SYSTEM\CurrentControlSet\Services\$Svc"
$HistoryKey        = "HKLM:\Software\AirWatch\Extensions\ServiceRecovery\Crashed\$Svc"
$LookbackHours     = 24   # the script's own default; CleanStopIgnored depends on it

$modulePath = Join-Path $PSScriptRoot '..\..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "DEXTestFramework.psm1 not found at $modulePath" }
Import-Module $modulePath -Force

# -- Helpers ------------------------------------------------------------------

function Write-DexNote {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Message = '')
    Write-Host "  [Info   ] $Name$(if ($Message) { ": $Message" })" -ForegroundColor Gray
}

function Get-SvcCim {
    param([string]$Name = $Svc)
    Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
}

function ConvertTo-StartupType {
    param([string]$StartMode)
    switch ($StartMode) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } 'Disabled' { 'Disabled' } default { 'Automatic' } }
}

function Get-CrashEventCount {
    # 7031/7034 naming the service (display name is the first parameter) since $Since.
    param([string]$Name, [datetime]$Since)
    $display = (Get-SvcCim -Name $Name).DisplayName
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7031, 7034; StartTime = $Since } -ErrorAction SilentlyContinue |
            Where-Object { $_.Properties.Count -gt 0 -and "$($_.Properties[0].Value)" -eq $display })
    return $ev.Count
}

function Get-HistoryValues {
    # Emits the entries one by one so callers can pipe or wrap in @().
    try { (Get-ItemProperty -Path $HistoryKey -Name History -ErrorAction Stop).History } catch { }
}

function New-Snapshot {
    $cim  = Get-SvcCim
    $sc   = Get-Service -Name $Svc
    $fa   = (Get-Item -LiteralPath $SvcRegKey).GetValue('FailureActions', $null)
    $them = Get-SvcCim -Name $CleanSvc
    @{
        StartMode         = "$($cim.StartMode)"
        State             = "$($cim.State)"
        RunningDependents = [string[]]@($sc.DependentServices | Where-Object { $_.Status -eq 'Running' } | ForEach-Object { $_.Name })
        # Base64, so the bytes survive the JSON state file.
        FailureActions    = $(if ($null -ne $fa) { [Convert]::ToBase64String([byte[]]$fa) } else { '' })
        HadHistory        = (Test-Path -LiteralPath $HistoryKey)
        History           = [string[]]@(Get-HistoryValues)
        CleanState        = "$($them.State)"
    }
}

function Restore-Snapshot {
    param($Original)
    # Recovery actions first, so a start below cannot be followed by a surprise SCM action.
    if ("$($Original.FailureActions)") {
        Set-ItemProperty -LiteralPath $SvcRegKey -Name FailureActions -Type Binary -Value ([Convert]::FromBase64String("$($Original.FailureActions)"))
    } else {
        Remove-ItemProperty -LiteralPath $SvcRegKey -Name FailureActions -Force -ErrorAction SilentlyContinue
    }
    Set-Service -Name $Svc -StartupType (ConvertTo-StartupType "$($Original.StartMode)") -ErrorAction SilentlyContinue
    if ("$($Original.State)" -eq 'Running') {
        Start-Service -Name $Svc -ErrorAction SilentlyContinue
        foreach ($dep in @($Original.RunningDependents)) {
            if ([string]::IsNullOrEmpty("$dep")) { continue }
            Start-Service -Name "$dep" -ErrorAction SilentlyContinue
        }
    } else {
        Stop-Service -Name $Svc -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $HistoryKey) { Remove-Item -LiteralPath $HistoryKey -Recurse -Force -ErrorAction SilentlyContinue }
    if ($Original.HadHistory) {
        New-Item -Path $HistoryKey -Force | Out-Null
        $h = [string[]]@(@($Original.History) | Where-Object { -not [string]::IsNullOrEmpty("$_") })
        if ($h.Count -gt 0) { New-ItemProperty -Path $HistoryKey -Name History -PropertyType MultiString -Value $h -Force | Out-Null }
    }
    if ("$($Original.CleanState)" -eq 'Running') { Start-Service -Name $CleanSvc -ErrorAction SilentlyContinue }
}

function Clear-History {
    if (Test-Path -LiteralPath $HistoryKey) { Remove-Item -LiteralPath $HistoryKey -Recurse -Force }
}

function Set-Recovery {
    # 'None' leaves the service down after a crash; 'Restart' has the SCM bring it back in 1 s.
    param([ValidateSet('None', 'Restart')][string]$Mode)
    # cmd /c: Windows PowerShell drops an empty-string argument to a native command.
    $cmd = if ($Mode -eq 'None') { "sc.exe failure $Svc reset= 0 actions= `"`"" } else { "sc.exe failure $Svc reset= 86400 actions= restart/1000" }
    $out = & cmd.exe /c $cmd 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sc.exe failure ($Mode) returned $LASTEXITCODE`: $($out | Out-String)" }
}

function Invoke-SpoolerCrash {
    # Ends spoolsv.exe so the SCM records an unexpected termination, and waits for the event.
    if ((Get-SvcCim).State -ne 'Running') { Start-Service -Name $Svc -ErrorAction Stop }
    $since  = Get-Date
    $procId = [int](Get-SvcCim).ProcessId
    if ($procId -le 4) { throw "Spooler has no process to end (PID $procId)." }
    Stop-Process -Id $procId -Force -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if ((Get-CrashEventCount -Name $Svc -Since $since.AddSeconds(-2)) -gt 0) { return }
        Start-Sleep -Milliseconds 500
    }
    throw 'No 7031/7034 event appeared for the Spooler within 20 s of ending its process.'
}

function Wait-SvcState {
    param([string]$State, [int]$Seconds = 20)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-SvcCim).State -eq $State) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Test-Run {
    # Exit code and an output fragment of the run under validation.
    param([int]$ExitCode, [string]$Contains)
    $r = $script:currentRun
    if (-not $r) { return $false }
    $ok = $true
    if ([int]$r.ExitCode -ne $ExitCode) { $ok = $false; Write-DexNote -Name 'Run' -Message "exit $($r.ExitCode), expected $ExitCode" }
    if ($Contains -and ([string]$r.Output -notlike "*$Contains*")) { $ok = $false; Write-DexNote -Name 'Run' -Message "output did not contain '$Contains'" }
    return $ok
}

# -- Scenario definitions ------------------------------------------------------
$applyCrashedStopped = {
    Clear-History
    Set-Recovery -Mode None
    Invoke-SpoolerCrash
}
$verifyCrashedStopped = {
    $st = (Get-SvcCim).State
    Write-DexNote -Name 'Verify' -Message "Spooler state=$st"
    $st -eq 'Stopped'
}

$BreakCatalog = @(

    @{
        Name = 'CrashedAndStopped'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false; Variables = @{}
        Methods  = @(@{ Name = 'EndProcessNoRecovery'; Apply = $applyCrashedStopped })
        Verify   = $verifyCrashedStopped
        Validate = {
            $st = (Get-SvcCim).State
            $h  = @(Get-HistoryValues | Where-Object { "$_" }).Count
            Write-DexNote -Name 'Validate CrashedAndStopped' -Message "state=$st history=$h"
            ($st -eq 'Running') -and ($h -eq 1) -and (Test-Run -ExitCode 0 -Contains '(Spooler) has been started')
        }
    },

    @{
        Name = 'CrashedButRecovered'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{}
        Methods  = @(@{ Name = 'EndProcessWithRecovery'; Apply = {
            Clear-History
            Set-Recovery -Mode Restart
            Invoke-SpoolerCrash
            if (-not (Wait-SvcState -State 'Running' -Seconds 30)) { throw 'The SCM recovery action did not bring the Spooler back within 30 s.' }
            $script:pidBeforeRun = [int](Get-SvcCim).ProcessId
        } })
        Verify   = {
            $st = (Get-SvcCim).State
            Write-DexNote -Name 'Verify CrashedButRecovered' -Message "state=$st pid=$($script:pidBeforeRun)"
            $st -eq 'Running'
        }
        Validate = {
            $c = Get-SvcCim
            $h = @(Get-HistoryValues | Where-Object { "$_" }).Count
            Write-DexNote -Name 'Validate CrashedButRecovered' -Message "state=$($c.State) pid=$($c.ProcessId) (was $($script:pidBeforeRun)) history=$h"
            ($c.State -eq 'Running') -and ([int]$c.ProcessId -eq $script:pidBeforeRun) -and ($h -eq 0) -and (Test-Run -ExitCode 0 -Contains '(Spooler) crashed')
        }
    },

    @{
        Name = 'CooldownHold'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{}
        Methods  = @(@{ Name = 'SeededHistory'; Apply = {
            & $applyCrashedStopped
            New-Item -Path $HistoryKey -Force | Out-Null
            New-ItemProperty -Path $HistoryKey -Name History -PropertyType MultiString -Force `
                -Value ([string[]]@((Get-Date).AddMinutes(-30).ToString('o'), (Get-Date).AddMinutes(-10).ToString('o'))) | Out-Null
        } })
        Verify   = { (& $verifyCrashedStopped) -and (@(Get-HistoryValues | Where-Object { "$_" }).Count -eq 2) }
        Validate = {
            $st = (Get-SvcCim).State
            $h  = @(Get-HistoryValues | Where-Object { "$_" }).Count
            Write-DexNote -Name 'Validate CooldownHold' -Message "state=$st history=$h"
            ($st -eq 'Stopped') -and ($h -eq 2) -and (Test-Run -ExitCode 1 -Contains 'Held:')
        }
    },

    @{
        Name = 'DisabledRespected'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{}
        Methods  = @(@{ Name = 'CrashThenDisable'; Apply = {
            & $applyCrashedStopped
            Set-Service -Name $Svc -StartupType Disabled -ErrorAction Stop
        } })
        Verify   = { (& $verifyCrashedStopped) -and ((Get-SvcCim).StartMode -eq 'Disabled') }
        Validate = {
            $c = Get-SvcCim
            Write-DexNote -Name 'Validate DisabledRespected' -Message "state=$($c.State) startMode=$($c.StartMode)"
            ($c.State -eq 'Stopped') -and ($c.StartMode -eq 'Disabled') -and (Test-Run -ExitCode 0 -Contains 'startup type is Disabled')
        }
    },

    @{
        Name = 'WhatIfNoStart'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{ WhatIf = 'true' }
        Methods  = @(@{ Name = 'EndProcessNoRecovery'; Apply = $applyCrashedStopped })
        Verify   = $verifyCrashedStopped
        Validate = {
            $st = (Get-SvcCim).State
            $h  = @(Get-HistoryValues | Where-Object { "$_" }).Count
            Write-DexNote -Name 'Validate WhatIfNoStart' -Message "state=$st history=$h"
            ($st -eq 'Stopped') -and ($h -eq 0) -and (Test-Run -ExitCode 0 -Contains 'WhatIf: would start')
        }
    },

    @{
        Name = 'CleanStopIgnored'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{}
        Methods  = @(@{ Name = 'StopThemes'; Apply = {
            if ((Get-CrashEventCount -Name $CleanSvc -Since (Get-Date).AddHours(-$LookbackHours)) -gt 0) {
                throw "$CleanSvc has a real crash event inside the lookback; this scenario cannot prove a clean stop is ignored."
            }
            Stop-Service -Name $CleanSvc -Force -ErrorAction Stop
        } })
        Verify   = {
            $st = (Get-SvcCim -Name $CleanSvc).State
            Write-DexNote -Name 'Verify CleanStopIgnored' -Message "$CleanSvc state=$st"
            $st -eq 'Stopped'
        }
        Validate = {
            $st = (Get-SvcCim -Name $CleanSvc).State
            Write-DexNote -Name 'Validate CleanStopIgnored' -Message "$CleanSvc state=$st"
            ($st -eq 'Stopped') -and (Test-Run -ExitCode 0 -Contains '')
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
Write-DexBanner -Title 'Restart-CrashedServices_BreakTest' -Detail "Environment: $Environment"

if ($Resume) { throw 'This harness has no reboot resume; nothing here reboots.' }

if ($Restore) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    $first = @($state.Breaks) | Select-Object -First 1
    if ($first) {
        try { Restore-Snapshot -Original ([PSCustomObject]$first.OriginalState); Write-DexStep -Status 'Passed' -Name 'Restore' }
        catch { Write-DexStep -Status 'Failed' -Name 'Restore' -Message $_.Exception.Message }
    }
    $state.Phase = 'Restored'; $state.Overall = 'Restored'
    Write-DexTestResult -State $state | Out-Null
    Clear-DexTestState -State $state
    exit 0
}

$state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Seed $Seed -Environment $Environment
$state.RemediationTest = [bool]$RemediationTest
Write-DexStep -Status 'Info' -Name 'Context' -Message "TestId $($state.TestId)  Seed $($state.Seed)"

$exitCode = 0; $restoreFailed = $false; $anyBreakFailed = $false
$runs = @(); $validation = @()

try {
    if (-not (Test-Path -LiteralPath $RemediationScript)) { throw "Script under test not found at $RemediationScript" }
    $c = Get-SvcCim
    if (-not $c -or $c.StartMode -ne 'Auto') { throw "The Spooler must exist and be Automatic for this harness (found '$($c.StartMode)')." }
    if ((Get-CimInstance Win32_Service -Filter "ProcessId=$([int]$c.ProcessId)" | Measure-Object).Count -gt 1 -and $c.State -eq 'Running') {
        throw 'The Spooler shares its process with another service on this host; ending it would not be a clean single-service crash.'
    }

    $candidates = if ($BreakName) {
        @($BreakCatalog | Where-Object { @($BreakName -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Name })
    } else { @($BreakCatalog) }
    if ($candidates.Count -eq 0) { throw 'No scenario matched the requested selection.' }
    $selected = if ($BreakName) { $candidates } else { Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount }

    foreach ($def in $selected) {
        $method   = $def.Methods[0]
        $original = New-Snapshot
        $b = @{ Name = $def.Name; Method = $method.Name; ExpectedOutcome = $def.ExpectedOutcome; RequiresReboot = $false
                Applied = $false; BreakVerified = $false; OriginalState = $original }
        $state.Breaks = @($state.Breaks) + @($b)
        Save-DexTestState -State $state

        try {
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
            $expected = if ($def.ExpectedOutcome -eq 'ExpectFixed') { 'crashed service started' } else { 'reported, left unmodified' }
            $validation += @{ Name = $def.Name; Expected = $expected; Actual = $(if ($passed) { 'as expected' } else { 'NOT as expected' }); Result = $(if ($passed) { 'Pass' } else { 'Fail' }) }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) -Name "Validate $($def.Name)" -Message $expected
            if (-not $passed) { Write-Host $script:currentRun.Output }
        } catch {
            $anyBreakFailed = $true
            Write-DexStep -Status 'Failed' -Name "Scenario $($def.Name)" -Message $_.Exception.Message
            $validation += @{ Name = $def.Name; Expected = 'scenario completes'; Actual = $_.Exception.Message; Result = 'Fail' }
        } finally {
            if ($Environment -eq 'Physical') {
                try { Restore-Snapshot -Original $original; Write-DexStep -Status 'Passed' -Name "Restore $($def.Name)" }
                catch { $restoreFailed = $true; Write-DexStep -Status 'Failed' -Name "Restore $($def.Name)" -Message $_.Exception.Message }
            }
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
    if ($restoreFailed) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'machine left modified -- manual cleanup required'
    } else {
        $state.Phase = 'Restored'
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'machine returned to baseline'
    }
}

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) -Name 'Overall' -Message $state.Overall
Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state
exit $exitCode
