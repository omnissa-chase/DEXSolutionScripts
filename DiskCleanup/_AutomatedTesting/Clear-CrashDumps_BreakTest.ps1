<#
.SYNOPSIS
    Clear-CrashDumps_BreakTest -- plants dump files of known size in every crash dump
    location, then verifies Clear-CrashDumps.ps1 removes them, keeps the newest
    minidumps, and that the disk_crashdump_mb sensor follows.

.DESCRIPTION
    Covers Clear-CrashDumps.ps1 and Sensors\disk_crashdump_mb.ps1 (with
    Invoke-DiskStateCollection.ps1 as the sensor's source). Each scenario is its own
    cycle: remove fixtures -> plant -> verify -> run -> validate -> remove fixtures.
    Writes the uniform JSON result to C:\Temp\FixReport\Clear-CrashDumps\.

    THE FIXTURES (about 35 MB)
      %windir%\MEMORY.DMP                          20 MB (only when the host has none)
      %windir%\Minidump\DEXTEST_1..5.dmp           1 MB each, dated 2000-01-01..05
      %windir%\LiveKernelReports\DEXTest\DEXTEST.dmp   5 MB
      %windir%\LiveKernelReports\DEXTest\DEXTEST.txt   1 MB, not a dump: must survive
      %LOCALAPPDATA%\CrashDumps\DEXTEST_app.dmp    5 MB

    THE HOST'S OWN DUMPS
    The script under test is the real one: the host's own crash dumps are deleted by the
    live scenarios, except the newest three minidumps. That is the script working, and
    it is not put back. A host with a real MEMORY.DMP is refused (move it away first).

    SCENARIOS
      DumpsRemoved           live run -> memory dump, kernel report dump and application
                             dump gone, the .txt kept, exactly the newest three files
                             left in Minidump, freed at least 30 MB, Status Completed
      WhatIfNoChange         WhatIf=true -> "would free", every fixture still there
      DumpInUseSkipped       MEMORY.DMP held open -> it stays and is counted as left
      CleanupRefreshesSensor collector, then the cleanup -> cached CrashDumpMb drops by
                             at least 30 and disk_crashdump_mb returns the new value
      BelowMinimumNoChange   a copy with MinTotalMb = 999999 -> "Below the", nothing deleted
      KeepDaysKeepsRecent    a copy with KeepDays = 30 -> the dumps written today stay

    Not covered: a memory dump at a custom CrashControl\DumpFile path, other users'
    CrashDumps folders, the SYSTEM profile's CrashDumps folder, SkipLocations.

.PARAMETER RemediationTest
    Run the scripts after each scenario's fixtures are in place and validate.
.PARAMETER Environment
    Physical (default) removes the fixtures when the run ends. Snapshot leaves them.
.PARAMETER Seed
    Replays an earlier run's scenario order. Recorded in the result.
.PARAMETER BreakName
    Run specific scenarios instead of a random selection.
.PARAMETER BreakCount
    How many scenarios to run when selecting randomly. Default 6 (all).
.PARAMETER Restore
    Remove the fixtures after an interrupted run.
.PARAMETER Force
    Required acknowledgement.

.NOTES
    Script Name  : Clear-CrashDumps_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Reporting    : C:\Temp\FixReport\Clear-CrashDumps\

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

$ScriptUnderTest = 'Clear-CrashDumps'
$CleanupScript   = Join-Path $PSScriptRoot '..\Clear-CrashDumps.ps1'
$CollectorScript = Join-Path $PSScriptRoot '..\Invoke-DiskStateCollection.ps1'
$SensorScript    = Join-Path $PSScriptRoot '..\Sensors\disk_crashdump_mb.ps1'
$CachePath       = 'HKLM:\Software\AirWatch\Extensions\DiskState'
$ReportDir       = "C:\Temp\FixReport\$ScriptUnderTest"
$MemDmp          = "$env:windir\MEMORY.DMP"
$MemDmpBytes     = 20MB
$MiniDir         = "$env:windir\Minidump"
$LkrDir          = "$env:windir\LiveKernelReports\DEXTest"
$UserDmp         = "$env:LOCALAPPDATA\CrashDumps\DEXTEST_app.dmp"
$PlantedMb       = 30   # memory dump 20 + kernel report 5 + application dump 5 (minidumps depend on the host)

$modulePath = Join-Path $PSScriptRoot '..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "DEXTestFramework.psm1 not found at $modulePath" }
Import-Module $modulePath -Force

# -- Helpers ------------------------------------------------------------------

function Write-DexNote {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Message = '')
    Write-Host "  [Info   ] $Name$(if ($Message) { ": $Message" })" -ForegroundColor Gray
}

function Test-FixtureMemDmp {
    # The planted memory dump is recognised by its exact size.
    return ([IO.File]::Exists($MemDmp) -and (New-Object System.IO.FileInfo $MemDmp).Length -eq $MemDmpBytes)
}

function Remove-Fixtures {
    if ($script:lock) { try { $script:lock.Dispose() } catch { }; $script:lock = $null }
    if (Test-FixtureMemDmp) { Remove-Item -LiteralPath $MemDmp -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $MiniDir) { Get-ChildItem -LiteralPath $MiniDir -Filter 'DEXTEST_*.dmp' -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $LkrDir) { Remove-Item -LiteralPath $LkrDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $UserDmp) { Remove-Item -LiteralPath $UserDmp -Force -ErrorAction SilentlyContinue }
}

function New-Fixtures {
    Remove-Fixtures
    if ([IO.File]::Exists($MemDmp)) { throw "This host has a real $MemDmp. Move it away before running this test." }
    [IO.File]::WriteAllBytes($MemDmp, (New-Object byte[] $MemDmpBytes))
    foreach ($d in @($MiniDir, $LkrDir, (Split-Path $UserDmp -Parent))) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    foreach ($n in 1..5) {
        $p = Join-Path $MiniDir "DEXTEST_$n.dmp"
        [IO.File]::WriteAllBytes($p, (New-Object byte[] 1MB))
        $when = Get-Date -Year 2000 -Month 1 -Day $n -Hour 12 -Minute 0 -Second 0
        $i = Get-Item -LiteralPath $p; $i.CreationTime = $when; $i.LastWriteTime = $when
    }
    [IO.File]::WriteAllBytes("$LkrDir\DEXTEST.dmp", (New-Object byte[] 5MB))
    [IO.File]::WriteAllBytes("$LkrDir\DEXTEST.txt", (New-Object byte[] 1MB))
    [IO.File]::WriteAllBytes($UserDmp, (New-Object byte[] 5MB))
    # What a live run must leave in Minidump: the newest three dump files, whoever made them.
    $script:expectMini = @(Get-ChildItem -LiteralPath $MiniDir -File -Force | Where-Object { $_.Extension -match '^(?i)\.(dmp|mdmp|hdmp|kdmp)$' } | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object { $_.Name } | Sort-Object)
}

function Get-MiniNames {
    return @(Get-ChildItem -LiteralPath $MiniDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^(?i)\.(dmp|mdmp|hdmp|kdmp)$' } | ForEach-Object { $_.Name } | Sort-Object)
}

function Get-FixtureState {
    return @{
        Mem  = (Test-FixtureMemDmp)
        Lkr  = (Test-Path -LiteralPath "$LkrDir\DEXTEST.dmp")
        Txt  = (Test-Path -LiteralPath "$LkrDir\DEXTEST.txt")
        User = (Test-Path -LiteralPath $UserDmp)
        Mini = @(Get-ChildItem -LiteralPath $MiniDir -Filter 'DEXTEST_*.dmp' -Force -ErrorAction SilentlyContinue).Count
    }
}

function Test-AllPlanted {
    $s = Get-FixtureState
    Write-DexNote -Name 'Verify' -Message "memory dump=$($s.Mem) kernel report=$($s.Lkr) txt=$($s.Txt) application dump=$($s.User) minidump fixtures=$($s.Mini)"
    $s.Mem -and $s.Lkr -and $s.Txt -and $s.User -and ($s.Mini -eq 5)
}

function Get-CacheInt {
    param([string]$Name)
    try { $v = (Get-ItemProperty -Path $CachePath -Name $Name -ErrorAction Stop).$Name; if ("$v" -match '^-?\d+$') { return [int]$v } } catch { }
    return -1
}

function Get-CacheText {
    param([string]$Name)
    try { return [string](Get-ItemProperty -Path $CachePath -Name $Name -ErrorAction Stop).$Name } catch { return '' }
}

function New-Variant {
    # A copy of the script under test with one SETTINGS constant changed.
    param([string]$Name, [string]$Setting, [string]$Value)
    $text = [IO.File]::ReadAllText($CleanupScript)
    $rx = '(?m)^\$' + [regex]::Escape($Setting) + '(\s*)=\s*\S+'
    if (-not [regex]::IsMatch($text, $rx)) { throw "Setting `$$Setting not found in the script under test." }
    $text = [regex]::Replace($text, $rx, ('$$' + $Setting + '$1= ' + $Value), 1)
    if (-not (Test-Path -LiteralPath $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
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

# -- Scenario definitions ------------------------------------------------------
# Run is a script path, or a script block that returns one (for the variants).
$BreakCatalog = @(

    @{
        Name = 'DumpsRemoved'; ExpectedOutcome = 'ExpectFixed'; Variables = @{}; Run = $CleanupScript
        Apply    = { New-Fixtures }
        Verify   = { Test-AllPlanted }
        Validate = {
            $s = Get-FixtureState; $mini = Get-MiniNames; $freed = Get-CacheInt 'LastCrashDumpFreedMb'; $st = Get-CacheText 'LastCrashDumpCleanupStatus'
            $miniOk = (($mini -join '|') -eq ($script:expectMini -join '|'))
            Write-DexNote -Name 'Validate DumpsRemoved' -Message "memory dump left=$($s.Mem) kernel report left=$($s.Lkr) txt kept=$($s.Txt) application dump left=$($s.User); Minidump now [$($mini -join ', ')] expected [$($script:expectMini -join ', ')]; freedMb=$freed status=$st"
            (-not $s.Mem) -and (-not $s.Lkr) -and $s.Txt -and (-not $s.User) -and $miniOk -and ($freed -ge $PlantedMb) -and ($st -eq 'Completed') -and (Test-Run -Contains 'Freed ')
        }
    },

    @{
        Name = 'WhatIfNoChange'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{ WhatIf = 'true' }; Run = $CleanupScript
        Apply    = { New-Fixtures }
        Verify   = { Test-AllPlanted }
        Validate = {
            $would = Get-CacheInt 'LastCrashDumpWouldFreeMb'; $st = Get-CacheText 'LastCrashDumpCleanupStatus'
            Write-DexNote -Name 'Validate WhatIfNoChange' -Message "wouldFreeMb=$would status=$st"
            (Test-AllPlanted) -and ($would -ge $PlantedMb) -and ($st -eq 'WhatIf') -and (Test-Run -Contains 'would free')
        }
    },

    @{
        Name = 'DumpInUseSkipped'; ExpectedOutcome = 'ExpectFixed'; Variables = @{}; Run = $CleanupScript
        Apply    = { New-Fixtures; $script:lock = [IO.File]::Open($MemDmp, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None) }
        Verify   = { (Test-AllPlanted) -and ($null -ne $script:lock) }
        Validate = {
            $s = Get-FixtureState
            Write-DexNote -Name 'Validate DumpInUseSkipped' -Message "held memory dump still there=$($s.Mem) kernel report left=$($s.Lkr) application dump left=$($s.User)"
            $s.Mem -and (-not $s.Lkr) -and (-not $s.User) -and (Test-Run -Contains 'in use or protected')
        }
    },

    @{
        Name = 'CleanupRefreshesSensor'; ExpectedOutcome = 'ExpectFixed'; Variables = @{}; Run = $CleanupScript
        Apply    = {
            New-Fixtures
            $r = Invoke-Script -Path $CollectorScript
            if ($r.ExitCode -ne 0) { throw "The collector exited $($r.ExitCode): $($r.Output)" }
            $script:before = Get-CacheInt 'CrashDumpMb'
            $script:sensorBefore = (Invoke-Script -Path $SensorScript).Output
        }
        Verify   = {
            Write-DexNote -Name 'Verify' -Message "collector CrashDumpMb=$($script:before) sensor='$($script:sensorBefore)'"
            (Test-AllPlanted) -and ($script:before -ge $PlantedMb) -and ("$($script:sensorBefore)" -eq "$($script:before)")
        }
        Validate = {
            $after = Get-CacheInt 'CrashDumpMb'; $s1 = Invoke-Script -Path $SensorScript
            Write-DexNote -Name 'Validate CleanupRefreshesSensor' -Message "CrashDumpMb before=$($script:before) after=$after sensor='$($s1.Output)'"
            ($after -ge 0) -and (($script:before - $after) -ge $PlantedMb) -and ("$($s1.Output)" -eq "$after") -and (Test-Run)
        }
    },

    @{
        Name = 'BelowMinimumNoChange'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{}; Run = { New-Variant -Name 'MinTotalMb' -Setting 'MinTotalMb' -Value '999999' }
        Apply    = { New-Fixtures }
        Verify   = { Test-AllPlanted }
        Validate = { (Test-AllPlanted) -and (Test-Run -Contains 'Below the 999999 MB minimum') }
    },

    @{
        Name = 'KeepDaysKeepsRecent'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{}; Run = { New-Variant -Name 'KeepDays' -Setting 'KeepDays' -Value '30' }
        Apply    = { New-Fixtures }
        Verify   = { Test-AllPlanted }
        Validate = {
            $s = Get-FixtureState
            Write-DexNote -Name 'Validate KeepDaysKeepsRecent' -Message "written today and still there: memory dump=$($s.Mem) kernel report=$($s.Lkr) application dump=$($s.User)"
            $s.Mem -and $s.Lkr -and $s.User -and $s.Txt -and (Test-Run -Contains 'kept')
        }
    }
)

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList
Write-DexBanner -Title 'Clear-CrashDumps_BreakTest' -Detail "Environment: $Environment"

if ($Resume) { throw 'This harness has no reboot resume; nothing here reboots.' }
$script:lock = $null

if ($Restore) {
    Remove-Fixtures
    Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'fixture files and folders removed'
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
    foreach ($s in @($CleanupScript, $CollectorScript, $SensorScript)) {
        if (-not (Test-Path -LiteralPath $s)) { throw "Script under test not found at $s" }
    }

    $candidates = if ($BreakName) {
        @($BreakCatalog | Where-Object { @($BreakName -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Name })
    } else { @($BreakCatalog) }
    if ($candidates.Count -eq 0) { throw 'No scenario matched the requested selection.' }
    $selected = if ($BreakName) { $candidates } else { Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount }

    foreach ($def in $selected) {
        $b = @{ Name = $def.Name; Method = 'FixturesPlanted'; ExpectedOutcome = $def.ExpectedOutcome; RequiresReboot = $false
                Applied = $false; BreakVerified = $false; OriginalState = @{ Fixtures = 'DEXTEST dump files' } }
        $state.Breaks = @($state.Breaks) + @($b)
        Save-DexTestState -State $state

        try {
            & $def.Apply
            $b.Applied = $true
            Write-DexStep -Status 'Info' -Name "Scenario $($def.Name)" -Message 'fixtures planted'

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
            $expected = if ($def.ExpectedOutcome -eq 'ExpectFixed') { 'dumps removed, newest minidumps kept' } else { 'reported, left unmodified' }
            $validation += @{ Name = $def.Name; Expected = $expected; Actual = $(if ($passed) { 'as expected' } else { 'NOT as expected' }); Result = $(if ($passed) { 'Pass' } else { 'Fail' }) }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) -Name "Validate $($def.Name)" -Message $expected
            if (-not $passed) { Write-Host $script:currentRun.Output }
        } catch {
            $anyBreakFailed = $true
            Write-DexStep -Status 'Failed' -Name "Scenario $($def.Name)" -Message $_.Exception.Message
            $validation += @{ Name = $def.Name; Expected = 'scenario completes'; Actual = $_.Exception.Message; Result = 'Fail' }
        } finally {
            try { Remove-Fixtures } catch { $restoreFailed = $true; Write-DexStep -Status 'Failed' -Name "Reset $($def.Name)" -Message $_.Exception.Message }
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
    try { Remove-Fixtures } catch { $restoreFailed = $true }
    Get-ChildItem -LiteralPath $ReportDir -Filter 'variant-*.ps1' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    # The cache key is the scripts' own product; it goes only when this run created it.
    if (-not $hadCache -and (Test-Path -LiteralPath $CachePath)) { Remove-Item -LiteralPath $CachePath -Recurse -Force -ErrorAction SilentlyContinue }
    $s = Get-FixtureState
    if ($restoreFailed -or $s.Mem -or $s.Lkr -or $s.Txt -or $s.User -or $s.Mini -gt 0) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'fixtures not fully removed -- run with -Restore -Force'
    } else {
        $state.Phase = 'Restored'
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'fixtures removed (the host''s own old dumps stay deleted)'
    }
}

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) -Name 'Overall' -Message $state.Overall
Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state
exit $exitCode
