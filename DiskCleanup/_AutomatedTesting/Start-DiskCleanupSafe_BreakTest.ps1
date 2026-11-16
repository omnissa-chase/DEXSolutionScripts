<#
.SYNOPSIS
    Start-DiskCleanupSafe_BreakTest -- plants old and new files of known size in the safe
    cleanup categories, then verifies Start-DiskCleanupSafe.ps1 frees the old ones and
    only those, and that the collector and the disk sensors report the same figures.

.DESCRIPTION
    Covers the step-1 disk cleanup set: Start-DiskCleanupSafe.ps1,
    Invoke-DiskStateCollection.ps1, Sensors\disk_reclaimable_safe_mb.ps1,
    Sensors\disk_top_consumer.ps1 and OneTimeSensor\disk_space_health.ps1.
    Each scenario is its own cycle: remove fixtures -> plant -> verify -> run -> validate
    -> remove fixtures. Writes the uniform JSON result to
    C:\Temp\FixReport\Start-DiskCleanupSafe\ for Invoke-FixReportAnalysis.ps1.

    THE FIXTURES
    In five category locations, one 5 MB file created and written 40 days ago (old) and
    one 1 MB file dated now (new), 25 MB of old files in all:
      %windir%\Temp\DEXTestCleanup\                          old.bin, new.bin
      %LOCALAPPDATA%\Temp\DEXTestCleanup\                    old.bin, new.bin
      %ProgramData%\Microsoft\Windows\WER\ReportArchive\DEXTestCleanup\   old.bin, new.bin
      %windir%\SoftwareDistribution\Download\DEXTestCleanup\ old.bin, new.bin
      %windir%\Logs\CBS\                                     CbsPersist_DEXTEST_old.log, CbsPersist_DEXTEST_new.log

    THE HOST'S OWN FILES
    The script under test is the real one and clears the real categories: the host's own
    temp files, error reports, update leftovers and servicing logs that are past their
    age are deleted by the live scenarios. That is the script working, and it is not
    put back. Run it only on a disposable VM or a marked test host.

    SCENARIOS
      OldFilesRemoved         live run -> the five old files gone, the five new ones
                              kept, "Freed" at least 25 MB, exit 0, Status Completed
      WhatIfNoChange          WhatIf=true -> "would free", every fixture still there
      FileInUseSkipped        one old file held open -> it stays and is counted as
                              left; the other four go; exit 0
      CollectorCountsFixtures collector run -> ReclaimableSafeMb at least 25, files
                              untouched; disk_reclaimable_safe_mb returns the cached
                              value and disk_top_consumer a known key
      CleanupRefreshesCache   collector, then the cleanup -> the cached
                              ReclaimableSafeMb drops by at least 20 without another
                              collector run
      HealthSensorJson        disk_space_health -> one line of JSON that parses, at
                              most 1,000 characters, SafeMb at least 25, files untouched

    Not covered: the Delivery Optimization and Defender history categories (no fixture
    can be planted safely), other users' temp folders, the time budgets, the report-only
    figures (sized by the collector, checked by eye in the health sensor's output).

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
    Script Name  : Start-DiskCleanupSafe_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Reporting    : C:\Temp\FixReport\Start-DiskCleanupSafe\

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

$ScriptUnderTest = 'Start-DiskCleanupSafe'
$CleanupScript   = Join-Path $PSScriptRoot '..\Start-DiskCleanupSafe.ps1'
$CollectorScript = Join-Path $PSScriptRoot '..\Invoke-DiskStateCollection.ps1'
$SensorSafe      = Join-Path $PSScriptRoot '..\Sensors\disk_reclaimable_safe_mb.ps1'
$SensorTop       = Join-Path $PSScriptRoot '..\Sensors\disk_top_consumer.ps1'
$SensorHealth    = Join-Path $PSScriptRoot '..\OneTimeSensor\disk_space_health.ps1'
$CachePath       = 'HKLM:\Software\AirWatch\Extensions\DiskState'
$OldMb = 5; $NewMb = 1; $PlantedOldMb = 25
$TopKeys = @('None', 'SafeCleanup', 'CrashDumps', 'PreviousWindows', 'RecycleBin', 'ShadowCopies', 'HibernationFile', 'PageFile', 'OutlookData', 'OneDriveLocal', 'VirtualDisks', 'Downloads', 'UserFolders')

$modulePath = Join-Path $PSScriptRoot '..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "DEXTestFramework.psm1 not found at $modulePath" }
Import-Module $modulePath -Force

# Old and new fixture file per category location.
$Fixtures = @(
    @{ Key = 'WinTemp';      Dir = "$env:windir\Temp\DEXTestCleanup";                                   Old = 'old.bin'; New = 'new.bin'; OwnDir = $true },
    @{ Key = 'UserTemp';     Dir = "$env:LOCALAPPDATA\Temp\DEXTestCleanup";                             Old = 'old.bin'; New = 'new.bin'; OwnDir = $true },
    @{ Key = 'ErrorReports'; Dir = "$env:ProgramData\Microsoft\Windows\WER\ReportArchive\DEXTestCleanup"; Old = 'old.bin'; New = 'new.bin'; OwnDir = $true },
    @{ Key = 'UpdateCache';  Dir = "$env:windir\SoftwareDistribution\Download\DEXTestCleanup";          Old = 'old.bin'; New = 'new.bin'; OwnDir = $true },
    @{ Key = 'ServicingLogs'; Dir = "$env:windir\Logs\CBS";                                             Old = 'CbsPersist_DEXTEST_old.log'; New = 'CbsPersist_DEXTEST_new.log'; OwnDir = $false }
)

# -- Helpers ------------------------------------------------------------------

function Write-DexNote {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Message = '')
    Write-Host "  [Info   ] $Name$(if ($Message) { ": $Message" })" -ForegroundColor Gray
}

function Remove-Fixtures {
    if ($script:lock) { try { $script:lock.Dispose() } catch { }; $script:lock = $null }
    foreach ($f in $Fixtures) {
        if ($f.OwnDir) {
            if (Test-Path -LiteralPath $f.Dir) { Remove-Item -LiteralPath $f.Dir -Recurse -Force -ErrorAction SilentlyContinue }
        } else {
            foreach ($n in @($f.Old, $f.New)) { $p = Join-Path $f.Dir $n; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } }
        }
    }
}

function New-FixtureFile {
    param([string]$Path, [int]$Mb, [bool]$Old)
    [IO.File]::WriteAllBytes($Path, (New-Object byte[] ($Mb * 1MB)))
    if ($Old) { $when = (Get-Date).AddDays(-40); $i = Get-Item -LiteralPath $Path; $i.CreationTime = $when; $i.LastWriteTime = $when }
}

function New-Fixtures {
    Remove-Fixtures
    foreach ($f in $Fixtures) {
        if (-not (Test-Path -LiteralPath $f.Dir)) {
            if (-not $f.OwnDir) { throw "Expected folder missing on this host: $($f.Dir)" }
            New-Item -ItemType Directory -Path $f.Dir -Force | Out-Null
        }
        New-FixtureFile -Path (Join-Path $f.Dir $f.Old) -Mb $OldMb -Old $true
        New-FixtureFile -Path (Join-Path $f.Dir $f.New) -Mb $NewMb -Old $false
    }
}

function Get-FixtureCounts {
    # How many old and new fixture files exist right now.
    $old = 0; $new = 0
    foreach ($f in $Fixtures) {
        if (Test-Path -LiteralPath (Join-Path $f.Dir $f.Old)) { $old++ }
        if (Test-Path -LiteralPath (Join-Path $f.Dir $f.New)) { $new++ }
    }
    return @{ Old = $old; New = $new }
}

function Test-AllPlanted {
    $c = Get-FixtureCounts
    Write-DexNote -Name 'Verify' -Message "old fixtures=$($c.Old) of $($Fixtures.Count) new fixtures=$($c.New) of $($Fixtures.Count)"
    ($c.Old -eq $Fixtures.Count) -and ($c.New -eq $Fixtures.Count)
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
# Run is the script the scenario puts under validation; Apply may run others first.
$BreakCatalog = @(

    @{
        Name = 'OldFilesRemoved'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false; Variables = @{}; Run = $CleanupScript
        Methods  = @(@{ Name = 'OldAndNewFilesPlanted'; Apply = { New-Fixtures } })
        Verify   = { Test-AllPlanted }
        Validate = {
            $c = Get-FixtureCounts; $freed = Get-CacheInt 'LastCleanupFreedMb'; $st = Get-CacheText 'LastCleanupStatus'
            Write-DexNote -Name 'Validate OldFilesRemoved' -Message "old left=$($c.Old) new left=$($c.New) freedMb=$freed status=$st"
            ($c.Old -eq 0) -and ($c.New -eq $Fixtures.Count) -and ($freed -ge $PlantedOldMb) -and ($st -eq 'Completed') -and (Test-Run -Contains 'Freed ')
        }
    },

    @{
        Name = 'WhatIfNoChange'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{ WhatIf = 'true' }; Run = $CleanupScript
        Methods  = @(@{ Name = 'OldAndNewFilesPlanted'; Apply = { New-Fixtures } })
        Verify   = { Test-AllPlanted }
        Validate = {
            $c = Get-FixtureCounts; $would = Get-CacheInt 'LastCleanupWouldFreeMb'; $st = Get-CacheText 'LastCleanupStatus'
            Write-DexNote -Name 'Validate WhatIfNoChange' -Message "old left=$($c.Old) new left=$($c.New) wouldFreeMb=$would status=$st"
            ($c.Old -eq $Fixtures.Count) -and ($c.New -eq $Fixtures.Count) -and ($would -ge $PlantedOldMb) -and ($st -eq 'WhatIf') -and (Test-Run -Contains 'would free')
        }
    },

    @{
        Name = 'FileInUseSkipped'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false; Variables = @{}; Run = $CleanupScript
        Methods  = @(@{ Name = 'OneOldFileHeldOpen'; Apply = {
            New-Fixtures
            $held = Join-Path $Fixtures[0].Dir $Fixtures[0].Old
            $script:lock = [IO.File]::Open($held, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        } })
        Verify   = { (Test-AllPlanted) -and ($null -ne $script:lock) }
        Validate = {
            $held = Test-Path -LiteralPath (Join-Path $Fixtures[0].Dir $Fixtures[0].Old)
            $c = Get-FixtureCounts
            Write-DexNote -Name 'Validate FileInUseSkipped' -Message "held file still there=$held old left=$($c.Old) new left=$($c.New)"
            $held -and ($c.Old -eq 1) -and ($c.New -eq $Fixtures.Count) -and (Test-Run -Contains 'in use or protected')
        }
    },

    @{
        Name = 'CollectorCountsFixtures'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{}; Run = $CollectorScript
        Methods  = @(@{ Name = 'OldAndNewFilesPlanted'; Apply = { New-Fixtures } })
        Verify   = { Test-AllPlanted }
        Validate = {
            $c = Get-FixtureCounts; $safe = Get-CacheInt 'ReclaimableSafeMb'; $wt = Get-CacheInt 'Safe_WinTempMb'; $top = Get-CacheText 'TopConsumer'
            $s1 = Invoke-Script -Path $SensorSafe; $s2 = Invoke-Script -Path $SensorTop
            Write-DexNote -Name 'Validate CollectorCountsFixtures' -Message "cache safe=$safe winTemp=$wt top=$top; sensors: '$($s1.Output)' / '$($s2.Output)'; old left=$($c.Old)"
            ($c.Old -eq $Fixtures.Count) -and ($safe -ge $PlantedOldMb) -and ($wt -ge $OldMb) -and ("$($s1.Output)" -eq "$safe") -and ("$($s2.Output)" -eq $top) -and ($TopKeys -contains $top) -and (Test-Run -Contains 'Largest item')
        }
    },

    @{
        Name = 'CleanupRefreshesCache'; ExpectedOutcome = 'ExpectFixed'; RequiresReboot = $false; Variables = @{}; Run = $CleanupScript
        Methods  = @(@{ Name = 'CollectorThenCleanup'; Apply = {
            New-Fixtures
            $r = Invoke-Script -Path $CollectorScript
            if ($r.ExitCode -ne 0) { throw "The collector exited $($r.ExitCode): $($r.Output)" }
            $script:safeBefore = Get-CacheInt 'ReclaimableSafeMb'
        } })
        Verify   = {
            Write-DexNote -Name 'Verify' -Message "cached ReclaimableSafeMb before cleanup=$($script:safeBefore)"
            (Test-AllPlanted) -and ($script:safeBefore -ge $PlantedOldMb)
        }
        Validate = {
            $after = Get-CacheInt 'ReclaimableSafeMb'; $s1 = Invoke-Script -Path $SensorSafe
            Write-DexNote -Name 'Validate CleanupRefreshesCache' -Message "ReclaimableSafeMb before=$($script:safeBefore) after=$after sensor='$($s1.Output)'"
            ($after -ge 0) -and (($script:safeBefore - $after) -ge 20) -and ("$($s1.Output)" -eq "$after") -and (Test-Run)
        }
    },

    @{
        Name = 'HealthSensorJson'; ExpectedOutcome = 'ExpectReportedOnly'; RequiresReboot = $false; Variables = @{}; Run = $SensorHealth
        Methods  = @(@{ Name = 'OldAndNewFilesPlanted'; Apply = { New-Fixtures } })
        Verify   = { Test-AllPlanted }
        Validate = {
            $c = Get-FixtureCounts; $raw = [string]$script:currentRun.Output; $j = $null
            try { $j = $raw | ConvertFrom-Json } catch { }
            $lines = @($raw -split "`n" | Where-Object { $_.Trim() }).Count
            Write-DexNote -Name 'Validate HealthSensorJson' -Message "lines=$lines length=$($raw.Length) parsed=$([bool]$j) SafeMb=$($j.SafeMb) WinTemp=$($j.Safe.WinTemp) Top=$($j.Top) TO=$($j.TO) old left=$($c.Old)"
            ($lines -eq 1) -and ($raw.Length -le 1000) -and $j -and ([int]$j.SafeMb -ge $PlantedOldMb) -and ([int]$j.Safe.WinTemp -ge $OldMb) -and ($TopKeys -contains "$($j.Top)") -and ($c.Old -eq $Fixtures.Count) -and (Test-Run)
        }
    }
)

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList
Write-DexBanner -Title 'Start-DiskCleanupSafe_BreakTest' -Detail "Environment: $Environment"

if ($Resume) { throw 'This harness has no reboot resume; nothing here reboots.' }
$script:lock = $null

if ($Restore) {
    Remove-Fixtures
    Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'fixture files and folders removed'
    $stateFile = "C:\Temp\FixReport\$ScriptUnderTest\state.json"
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
    foreach ($s in @($CleanupScript, $CollectorScript, $SensorSafe, $SensorTop, $SensorHealth)) {
        if (-not (Test-Path -LiteralPath $s)) { throw "Script under test not found at $s" }
    }

    $candidates = if ($BreakName) {
        @($BreakCatalog | Where-Object { @($BreakName -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Name })
    } else { @($BreakCatalog) }
    if ($candidates.Count -eq 0) { throw 'No scenario matched the requested selection.' }
    $selected = if ($BreakName) { $candidates } else { Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount }

    foreach ($def in $selected) {
        $method = $def.Methods[0]
        $b = @{ Name = $def.Name; Method = $method.Name; ExpectedOutcome = $def.ExpectedOutcome; RequiresReboot = $false
                Applied = $false; BreakVerified = $false; OriginalState = @{ Fixtures = 'DEXTestCleanup' } }
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

            $script:currentRun = Invoke-Script -Path $def.Run -Variables $def.Variables
            $script:currentRun.Scenario = $def.Name
            $runs += $script:currentRun
            Write-DexStep -Status 'Info' -Name "Run $($def.Name)" -Message "$($script:currentRun.Script) exit $($script:currentRun.ExitCode) in $($script:currentRun.DurationSec) s"

            $passed   = [bool](& $def.Validate)
            $expected = if ($def.ExpectedOutcome -eq 'ExpectFixed') { 'old files freed, new files kept' } else { 'reported, left unmodified' }
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
    # The cache key is the scripts' own product; it goes only when this run created it.
    if (-not $hadCache -and (Test-Path -LiteralPath $CachePath)) { Remove-Item -LiteralPath $CachePath -Recurse -Force -ErrorAction SilentlyContinue }
    $c = Get-FixtureCounts
    if ($restoreFailed -or $c.Old -gt 0 -or $c.New -gt 0) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'fixtures not fully removed -- run with -Restore -Force'
    } else {
        $state.Phase = 'Restored'
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'fixtures removed (the host''s own old temp files stay deleted)'
    }
}

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) -Name 'Overall' -Message $state.Overall
Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state
exit $exitCode
