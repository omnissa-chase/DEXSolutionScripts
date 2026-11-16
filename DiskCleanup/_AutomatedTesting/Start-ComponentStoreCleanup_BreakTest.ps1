<#
.SYNOPSIS
    Start-ComponentStoreCleanup_BreakTest -- verifies the component store set: the DISM
    report parser and sensor, a real analysis, the cleanup script's guards, and a real
    background cleanup with its fresh analysis.

.DESCRIPTION
    Covers Invoke-ComponentStoreAnalysis.ps1, Start-ComponentStoreCleanup.ps1 and
    Sensors\disk_component_store_reclaimable_mb.ps1. There is nothing to "break" in a
    component store, so the fixture is the DISM report file the three share
    (%ProgramData%\AirWatch\Extensions\DiskState\component-analyze.log): a canned report
    with known figures, or no report at all. The host's own report is set aside first
    and put back at the end.
    Writes the uniform JSON result to C:\Temp\FixReport\Start-ComponentStoreCleanup\.

    SCENARIOS
      SensorReadsReport      canned report (4.91 GB + 438.21 MB) -> sensor returns 5466
      SensorNoReport         no report, no cached value -> sensor returns -1
      WhatIfNoChange         canned report, WhatIf=true -> "would start", DISM not started
      BelowMinimumRefused    a copy with MinReclaimableMb = 999999, canned report ->
                             "Below the", DISM not started
      NoAnalysisRefused      a copy with MinReclaimableMb = 1, no report -> "no analysis
                             to compare with", DISM not started
      RealAnalysis           no report -> Invoke-ComponentStoreAnalysis.ps1; waits up to
                             15 minutes for DISM; the report parses and the sensor
                             returns its figure           (1 to 5 minutes)
      RealCleanup            Start-ComponentStoreCleanup.ps1 live -> "started in the
                             background", Status Started; waits up to 60 minutes for
                             DISM; the cleanup log ends in success, a fresh report is
                             there, and a second run closes the first out as Completed
                                                           (5 to 40 minutes)

    RealCleanup performs a real component cleanup on this host. That is the supported
    operation Windows also runs by itself, and is not undone. Skip it with
    -BreakName when only the quick scenarios are wanted.

    Not covered: the DISM-running, servicing-busy and restart-pending guards (a host in
    one of those states makes RealCleanup report it instead of starting), ResetBase.

.PARAMETER RemediationTest
    Run the scripts after each scenario's state is in place and validate.
.PARAMETER Environment
    Physical (default) puts the host's own report back when the run ends.
.PARAMETER Seed
    Recorded in the result. The scenario order is fixed: quick ones first.
.PARAMETER BreakName
    Run specific scenarios.
.PARAMETER Restore
    Put the host's own report back after an interrupted run.
.PARAMETER Force
    Required acknowledgement.

.NOTES
    Script Name  : Start-ComponentStoreCleanup_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Reporting    : C:\Temp\FixReport\Start-ComponentStoreCleanup\

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
    [int]$BreakCount = 7,
    [switch]$IncludeRebootBreaks,
    [switch]$Restore,
    [switch]$Resume,
    [switch]$Force,
    [string[]]$ProductionDomainDenyList = @()
)

$ErrorActionPreference = 'Stop'

$ScriptUnderTest = 'Start-ComponentStoreCleanup'
$CleanupScript   = Join-Path $PSScriptRoot '..\Start-ComponentStoreCleanup.ps1'
$AnalysisScript  = Join-Path $PSScriptRoot '..\Invoke-ComponentStoreAnalysis.ps1'
$SensorScript    = Join-Path $PSScriptRoot '..\Sensors\disk_component_store_reclaimable_mb.ps1'
$CachePath       = 'HKLM:\Software\AirWatch\Extensions\DiskState'
$ReportDir       = "C:\Temp\FixReport\$ScriptUnderTest"
$CsDir           = "$env:ProgramData\AirWatch\Extensions\DiskState"
$AnalyzeLog      = "$CsDir\component-analyze.log"
$CleanupLog      = "$CsDir\component-cleanup.log"
$Backup          = "$ReportDir\host-component-analyze.log"
$CacheNames      = @('ComponentStoreReclaimableMb', 'LastComponentCleanupStatus')
$Canned = @'

Deployment Image Servicing and Management tool
Version: 10.0.26100.1

Image Version: 10.0.26200.7171

[==========================100.0%==========================]

Component Store (WinSxS) information:

Windows Explorer Reported Size of Component Store : 12.43 GB

Actual Size of Component Store : 11.87 GB

    Shared with Windows : 6.52 GB
    Backups and Disabled Features : 4.91 GB
    Cache and Temporary Data : 438.21 MB

Date of Last Cleanup : 2026-10-02 09:14:11

Number of Reclaimable Packages : 7
Component Store Cleanup Recommended : Yes

The operation completed successfully.
'@

$modulePath = Join-Path $PSScriptRoot '..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "DEXTestFramework.psm1 not found at $modulePath" }
Import-Module $modulePath -Force

# -- Helpers ------------------------------------------------------------------

function Write-DexNote {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Message = '')
    Write-Host "  [Info   ] $Name$(if ($Message) { ": $Message" })" -ForegroundColor Gray
}

function Test-DismRunning { return (@(Get-Process -Name 'dism' -ErrorAction SilentlyContinue).Count -gt 0) }

function Wait-Dism {
    # Waits for DISM to go and (optionally) for a file to appear. True when both happened in time.
    param([int]$Minutes, [string]$File = '')
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-DismRunning) -and (-not $File -or (Test-Path -LiteralPath $File))) { return $true }
        Start-Sleep -Seconds 10
    }
    return $false
}

function Save-HostState {
    # Once per run: the host's own report and the two cache values the scenarios disturb.
    if (-not (Test-Path -LiteralPath $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
    if ((Test-Path -LiteralPath $AnalyzeLog) -and -not (Test-Path -LiteralPath $Backup)) { Copy-Item -LiteralPath $AnalyzeLog -Destination $Backup -Force }
}

function Restore-HostState {
    # The newest real report wins: one written by RealAnalysis/RealCleanup stays; a canned one is replaced by the backup.
    $canned = (Test-Path -LiteralPath $AnalyzeLog) -and ([IO.File]::ReadAllText($AnalyzeLog) -eq $Canned)
    if ($canned) { Remove-Item -LiteralPath $AnalyzeLog -Force }
    if (-not (Test-Path -LiteralPath $AnalyzeLog) -and (Test-Path -LiteralPath $Backup)) { Copy-Item -LiteralPath $Backup -Destination $AnalyzeLog -Force }
    if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Force }
}

function Set-Report {
    param([bool]$Present)
    if (Test-DismRunning) { throw 'DISM is running on this host; wait for it to finish before this test.' }
    if (-not (Test-Path -LiteralPath $CsDir)) { New-Item -ItemType Directory -Path $CsDir -Force | Out-Null }
    if (Test-Path -LiteralPath $AnalyzeLog) { Remove-Item -LiteralPath $AnalyzeLog -Force }
    if ($Present) { [IO.File]::WriteAllText($AnalyzeLog, $Canned) }
    foreach ($n in $CacheNames) { Remove-ItemProperty -Path $CachePath -Name $n -ErrorAction SilentlyContinue }
}

function Get-CacheText {
    param([string]$Name)
    try { return [string](Get-ItemProperty -Path $CachePath -Name $Name -ErrorAction Stop).$Name } catch { return '' }
}

function New-Variant {
    # A copy of the cleanup script with one SETTINGS constant changed.
    param([string]$Name, [string]$Setting, [string]$Value)
    $text = [IO.File]::ReadAllText($CleanupScript)
    $rx = '(?m)^\$' + [regex]::Escape($Setting) + '(\s*)=\s*\S+'
    if (-not [regex]::IsMatch($text, $rx)) { throw "Setting `$$Setting not found in the script under test." }
    $text = [regex]::Replace($text, $rx, ('$$' + $Setting + '$1= ' + $Value), 1)
    $path = Join-Path $ReportDir "variant-$Name.ps1"
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($true)))
    return $path
}

function Invoke-Script {
    # Runs one script in a fresh Windows PowerShell and captures exit code and output.
    param([string]$Path, [hashtable]$Variables = @{})
    [Environment]::SetEnvironmentVariable('WhatIf', $(if ($Variables.ContainsKey('WhatIf')) { $Variables['WhatIf'] } else { $null }), 'Process')
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $sw     = [System.Diagnostics.Stopwatch]::StartNew()
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path 2>&1 | ForEach-Object { "$_" }
        $rc     = $LASTEXITCODE
        $sw.Stop()
    } finally {
        $ErrorActionPreference = $prevEap
        [Environment]::SetEnvironmentVariable('WhatIf', $null, 'Process')
    }
    return @{ Script = (Split-Path $Path -Leaf); Variables = $Variables; ExitCode = $rc; DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Output = ($output | Out-String).Trim() }
}

function Test-Run {
    param([int]$ExitCode = 0, [string]$Contains)
    $r = $script:currentRun
    if (-not $r) { return $false }
    $ok = $true
    if ([int]$r.ExitCode -ne $ExitCode) { $ok = $false; Write-DexNote -Name 'Run' -Message "exit $($r.ExitCode), expected $ExitCode" }
    if ($Contains -and ([string]$r.Output -notlike "*$Contains*")) { $ok = $false; Write-DexNote -Name 'Run' -Message "output did not contain '$Contains'" }
    return $ok
}

function Test-NothingStarted {
    $dism = Test-DismRunning; $log = Test-Path -LiteralPath $CleanupLog
    Write-DexNote -Name 'Validate' -Message "DISM running=$dism cleanup log present=$log"
    (-not $dism) -and (-not $log)
}

# -- Scenario definitions (fixed order: quick ones first, the real cleanup last) ---------
$BreakCatalog = @(

    @{
        Name = 'SensorReadsReport'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{}; Run = $SensorScript
        Apply    = { Set-Report -Present $true }
        Verify   = { Test-Path -LiteralPath $AnalyzeLog }
        Validate = { Write-DexNote -Name 'Validate SensorReadsReport' -Message "sensor='$($script:currentRun.Output)' expected 5466"; ("$($script:currentRun.Output)" -eq '5466') -and (Test-Run) }
    },

    @{
        Name = 'SensorNoReport'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{}; Run = $SensorScript
        Apply    = { Set-Report -Present $false }
        Verify   = { -not (Test-Path -LiteralPath $AnalyzeLog) }
        Validate = { Write-DexNote -Name 'Validate SensorNoReport' -Message "sensor='$($script:currentRun.Output)' expected -1"; ("$($script:currentRun.Output)" -eq '-1') -and (Test-Run) }
    },

    @{
        Name = 'WhatIfNoChange'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{ WhatIf = 'true' }; Run = $CleanupScript
        Apply    = { Set-Report -Present $true; if (Test-Path -LiteralPath $CleanupLog) { Remove-Item -LiteralPath $CleanupLog -Force } }
        Verify   = { Test-Path -LiteralPath $AnalyzeLog }
        Validate = { (Test-NothingStarted) -and ((Get-CacheText 'LastComponentCleanupStatus') -eq 'WhatIf') -and (Test-Run -Contains 'would start DISM') }
    },

    @{
        Name = 'BelowMinimumRefused'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{}; Run = { New-Variant -Name 'BelowMinimum' -Setting 'MinReclaimableMb' -Value '999999' }
        Apply    = { Set-Report -Present $true; if (Test-Path -LiteralPath $CleanupLog) { Remove-Item -LiteralPath $CleanupLog -Force } }
        Verify   = { Test-Path -LiteralPath $AnalyzeLog }
        Validate = { (Test-NothingStarted) -and ((Get-CacheText 'LastComponentCleanupStatus') -eq 'BelowMinimum') -and (Test-Run -Contains 'Below the 999999 MB minimum') }
    },

    @{
        Name = 'NoAnalysisRefused'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{}; Run = { New-Variant -Name 'NoAnalysis' -Setting 'MinReclaimableMb' -Value '1' }
        Apply    = { Set-Report -Present $false; if (Test-Path -LiteralPath $CleanupLog) { Remove-Item -LiteralPath $CleanupLog -Force } }
        Verify   = { -not (Test-Path -LiteralPath $AnalyzeLog) }
        Validate = { (Test-NothingStarted) -and ((Get-CacheText 'LastComponentCleanupStatus') -eq 'NoAnalysis') -and (Test-Run -Contains 'no analysis to compare with') }
    },

    @{
        Name = 'RealAnalysis'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{}; Run = $AnalysisScript
        Apply    = { Set-Report -Present $false }
        Verify   = { -not (Test-Path -LiteralPath $AnalyzeLog) }
        Validate = {
            $inTime = Wait-Dism -Minutes 15 -File $AnalyzeLog
            $text = if (Test-Path -LiteralPath $AnalyzeLog) { [IO.File]::ReadAllText($AnalyzeLog) } else { '' }
            $ok = $text -match 'The operation completed successfully'
            $s1 = Invoke-Script -Path $SensorScript
            Write-DexNote -Name 'Validate RealAnalysis' -Message "report in time=$inTime DISM success=$ok sensor='$($s1.Output)' cached=$(Get-CacheText 'ComponentStoreReclaimableMb') (cached only when DISM finished inside the script's 100 s)"
            if (-not $ok -and $text) { Write-Host $text }
            $inTime -and $ok -and ("$($s1.Output)" -match '^\d+$') -and (Test-Run)
        }
    },

    @{
        Name = 'RealCleanup'; ExpectedOutcome = 'ExpectFixed'; Variables = @{}; Run = $CleanupScript
        Apply    = {
            if (Test-DismRunning) { throw 'DISM is running on this host; wait for it to finish before this test.' }
            Remove-ItemProperty -Path $CachePath -Name 'LastComponentCleanupStatus' -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $CleanupLog) { Remove-Item -LiteralPath $CleanupLog -Force }
            $script:reportBefore = if (Test-Path -LiteralPath $AnalyzeLog) { [IO.File]::GetLastWriteTime($AnalyzeLog) } else { [datetime]::MinValue }
        }
        Verify   = { -not (Test-DismRunning) }
        Validate = {
            $started = (Test-Run -Contains 'started in the background') -and ((Get-CacheText 'LastComponentCleanupStatus') -eq 'Started')
            Write-DexNote -Name 'Validate RealCleanup' -Message "started=$started; waiting up to 60 minutes for DISM (cleanup, then analysis)"
            if (-not $started) { return $false }
            $inTime = Wait-Dism -Minutes 60 -File $CleanupLog
            $clean = (Test-Path -LiteralPath $CleanupLog) -and ([IO.File]::ReadAllText($CleanupLog) -match 'The operation completed successfully')
            $fresh = (Test-Path -LiteralPath $AnalyzeLog) -and ([IO.File]::GetLastWriteTime($AnalyzeLog) -gt $script:reportBefore)
            $close = Invoke-Script -Path $CleanupScript -Variables @{ WhatIf = 'true' }
            $closed = $close.Output -like '*ended: Completed*'
            $s1 = Invoke-Script -Path $SensorScript
            Write-DexNote -Name 'Validate RealCleanup' -Message "finished in time=$inTime cleanup log success=$clean fresh analysis=$fresh closed out as Completed=$closed freedMb='$(Get-CacheText 'LastComponentCleanupFreedMb')' sensor='$($s1.Output)'"
            if (-not $closed) { Write-Host $close.Output }
            $inTime -and $clean -and $fresh -and $closed -and ("$($s1.Output)" -match '^\d+$')
        }
    }
)

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList
Write-DexBanner -Title 'Start-ComponentStoreCleanup_BreakTest' -Detail "Environment: $Environment"

if ($Resume) { throw 'This harness has no reboot resume; nothing here reboots.' }

if ($Restore) {
    Restore-HostState
    Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'the host''s own analysis report is back in place'
    $stateFile = "$ReportDir\state.json"
    if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force }
    exit 0
}

$state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Seed $Seed -Environment $Environment
$state.RemediationTest = [bool]$RemediationTest
Write-DexStep -Status 'Info' -Name 'Context' -Message "TestId $($state.TestId)  Seed $($state.Seed)"

$exitCode = 0; $restoreFailed = $false; $anyBreakFailed = $false
$runs = @(); $validation = @()
$hadCache = Test-Path -LiteralPath $CachePath

try {
    foreach ($s in @($CleanupScript, $AnalysisScript, $SensorScript)) {
        if (-not (Test-Path -LiteralPath $s)) { throw "Script under test not found at $s" }
    }
    if (-not $hadCache) { New-Item -Path $CachePath -Force | Out-Null }
    Save-HostState

    $selected = if ($BreakName) {
        @($BreakCatalog | Where-Object { @($BreakName -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Name })
    } else { @($BreakCatalog) }
    if ($selected.Count -eq 0) { throw 'No scenario matched the requested selection.' }

    foreach ($def in $selected) {
        $b = @{ Name = $def.Name; Method = 'ReportFileState'; ExpectedOutcome = $def.ExpectedOutcome; RequiresReboot = $false
                Applied = $false; BreakVerified = $false; OriginalState = @{ Fixtures = 'component-analyze.log' } }
        $state.Breaks = @($state.Breaks) + @($b)
        Save-DexTestState -State $state

        try {
            & $def.Apply
            $b.Applied = $true
            Write-DexStep -Status 'Info' -Name "Scenario $($def.Name)" -Message 'state applied'

            $b.BreakVerified = [bool](& $def.Verify)
            if (-not $b.BreakVerified) {
                $anyBreakFailed = $true
                Write-DexStep -Status 'Failed' -Name "Verify $($def.Name)" -Message 'state did not land; the run would prove nothing'
                $validation += @{ Name = $def.Name; Expected = 'state in place'; Actual = 'NOT as expected'; Result = 'Fail' }
                continue
            }
            Write-DexStep -Status 'Passed' -Name "Verify $($def.Name)" -Message 'state is in place'
            if (-not $RemediationTest) { continue }

            $runPath = if ($def.Run -is [scriptblock]) { [string](& $def.Run) } else { [string]$def.Run }
            $script:currentRun = Invoke-Script -Path $runPath -Variables $def.Variables
            $script:currentRun.Scenario = $def.Name
            $runs += $script:currentRun
            Write-DexStep -Status 'Info' -Name "Run $($def.Name)" -Message "$($script:currentRun.Script) exit $($script:currentRun.ExitCode) in $($script:currentRun.DurationSec) s"

            $passed   = [bool](& $def.Validate)
            $expected = if ($def.ExpectedOutcome -eq 'ExpectFixed') { 'cleanup ran in the background and was recorded' } else { 'reported, nothing started' }
            $validation += @{ Name = $def.Name; Expected = $expected; Actual = $(if ($passed) { 'as expected' } else { 'NOT as expected' }); Result = $(if ($passed) { 'Pass' } else { 'Fail' }) }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) -Name "Validate $($def.Name)" -Message $expected
            if (-not $passed) { Write-Host $script:currentRun.Output }
        } catch {
            $anyBreakFailed = $true
            Write-DexStep -Status 'Failed' -Name "Scenario $($def.Name)" -Message $_.Exception.Message
            $validation += @{ Name = $def.Name; Expected = 'scenario completes'; Actual = $_.Exception.Message; Result = 'Fail' }
        } finally {
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
            Output      = (($runs | ForEach-Object { "== $($_.Scenario) [$($_.Script)] (exit $($_.ExitCode))`n$($_.Output)" }) -join "`n`n")
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
    try {
        [void](Wait-Dism -Minutes 20)
        Restore-HostState
        Get-ChildItem -LiteralPath $ReportDir -Filter 'variant-*.ps1' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $state.Phase = 'Restored'
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'analysis report restored (a real cleanup, when it ran, is not undone)'
    } catch {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message "$($_.Exception.Message) -- run with -Restore -Force"
    }
}

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) -Name 'Overall' -Message $state.Overall
Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state
exit $exitCode
