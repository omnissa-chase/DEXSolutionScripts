<#
.SYNOPSIS
    Clear-PreviousWindowsInstall_BreakTest -- plants a stand-in Windows.old and
    $Windows.~BT, then verifies Clear-PreviousWindowsInstall.ps1 leaves young ones alone,
    removes old ones through Disk Cleanup, and that disk_previous_windows_mb follows.

.DESCRIPTION
    Covers Clear-PreviousWindowsInstall.ps1 and Sensors\disk_previous_windows_mb.ps1
    (with Invoke-DiskStateCollection.ps1 as the sensor's source). Each scenario is its
    own cycle: remove fixtures -> plant -> verify -> run -> validate -> remove fixtures.
    Writes the uniform JSON result to C:\Temp\FixReport\Clear-PreviousWindowsInstall\.

    THE FIXTURES (about 30 MB), each with a DEXTEST.marker file at its top
      C:\Windows.old\Windows\System32\DEXTEST.bin          20 MB
      C:\Windows.old\Users\DEXTest\DEXTEST.bin              1 MB
      C:\$Windows.~BT\Sources\DEXTEST.bin                  10 MB
      C:\$Windows.~BT\Sources\Panther\setupact.log         a few bytes
    "Old" fixtures are dated 40 days back, top folder and children alike.

    A host that has a real Windows.old or $Windows.~BT (no marker) is refused: this
    test never touches a real previous installation.

    THE STAND-IN IS NOT A REAL PREVIOUS INSTALLATION
    The fixtures are plain folders an administrator owns. A real Windows.old is owned
    by TrustedInstaller and far larger. OldFoldersRemoved proves the script drives Disk
    Cleanup and reports the outcome; that Disk Cleanup removes a real one within the
    wait is proven only on a device that has just taken a feature update.

    SCENARIOS
      NothingPresent        no folders -> "Nothing to do", PreviousWindowsMb 0, sensor 0
      YoungFoldersKept      folders dated today -> "inside the 10-day roll-back period",
                            both still there, Status NothingEligible
      WhatIfNoChange        old folders, WhatIf=true -> "would remove", both still there
      RecentSetupLogKept    old folders but setupact.log written today, WhatIf=true ->
                            $Windows.~BT is "left", Windows.old is "to be removed"
      SensorFollowsCollector old folders, collector run -> disk_previous_windows_mb
                            returns the cached PreviousWindowsMb, at least 30
      OldFoldersRemoved     old folders, live run -> both folders gone, Status Completed,
                            PreviousWindowsMb 0 (Status Running is reported as a failure
                            here: the stand-in is small enough to finish in the wait)

    Not covered: the Setup-running and Disk-Cleanup-already-running guards, MinTotalMb,
    IncludeSetupFolders, $Windows.~WS and $GetCurrent.

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
    Script Name  : Clear-PreviousWindowsInstall_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Reporting    : C:\Temp\FixReport\Clear-PreviousWindowsInstall\

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

$ScriptUnderTest = 'Clear-PreviousWindowsInstall'
$CleanupScript   = Join-Path $PSScriptRoot '..\Clear-PreviousWindowsInstall.ps1'
$CollectorScript = Join-Path $PSScriptRoot '..\Invoke-DiskStateCollection.ps1'
$SensorScript    = Join-Path $PSScriptRoot '..\Sensors\disk_previous_windows_mb.ps1'
$CachePath       = 'HKLM:\Software\AirWatch\Extensions\DiskState'
$ReportDir       = "C:\Temp\FixReport\$ScriptUnderTest"
$OldDir          = "$env:SystemDrive\Windows.old"
$BtDir           = "$env:SystemDrive\`$Windows.~BT"
$SetupLog        = "$BtDir\Sources\Panther\setupact.log"
$Marker          = 'DEXTEST.marker'
$PlantedMb       = 30

$modulePath = Join-Path $PSScriptRoot '..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "DEXTestFramework.psm1 not found at $modulePath" }
Import-Module $modulePath -Force

# -- Helpers ------------------------------------------------------------------

function Write-DexNote {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Message = '')
    Write-Host "  [Info   ] $Name$(if ($Message) { ": $Message" })" -ForegroundColor Gray
}

function Assert-NoRealFolders {
    foreach ($d in @($OldDir, $BtDir)) {
        if ([IO.Directory]::Exists($d) -and -not [IO.File]::Exists("$d\$Marker")) { throw "This host has a real $d (no $Marker in it). This test will not run here." }
    }
}

function Remove-Fixtures {
    # Only a folder carrying the marker is ever removed.
    foreach ($d in @($OldDir, $BtDir)) {
        if ([IO.Directory]::Exists($d) -and [IO.File]::Exists("$d\$Marker")) {
            Get-ChildItem -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-TreeAge {
    # Dates a folder and everything in it, deepest first, so the folder dates stick.
    param([string]$Path, [datetime]$When)
    $all = @(Get-ChildItem -LiteralPath $Path -Recurse -Force) | Sort-Object { $_.FullName.Length } -Descending
    foreach ($i in $all) { $i.CreationTime = $When; $i.LastWriteTime = $When }
    $root = Get-Item -LiteralPath $Path -Force
    $root.CreationTime = $When; $root.LastWriteTime = $When
}

function New-Fixtures {
    param([bool]$Old = $true)
    Assert-NoRealFolders
    Remove-Fixtures
    foreach ($d in @("$OldDir\Windows\System32", "$OldDir\Users\DEXTest", "$BtDir\Sources\Panther")) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [IO.File]::WriteAllText("$OldDir\$Marker", 'DEX break test fixture')
    [IO.File]::WriteAllText("$BtDir\$Marker", 'DEX break test fixture')
    [IO.File]::WriteAllBytes("$OldDir\Windows\System32\DEXTEST.bin", (New-Object byte[] 20MB))
    [IO.File]::WriteAllBytes("$OldDir\Users\DEXTest\DEXTEST.bin", (New-Object byte[] 1MB))
    [IO.File]::WriteAllBytes("$BtDir\Sources\DEXTEST.bin", (New-Object byte[] 10MB))
    [IO.File]::WriteAllText($SetupLog, 'DEX break test fixture')
    if ($Old) { $when = (Get-Date).AddDays(-40); Set-TreeAge $OldDir $when; Set-TreeAge $BtDir $when }
}

function Get-FixtureState {
    return @{ Old = [IO.Directory]::Exists($OldDir); Bt = [IO.Directory]::Exists($BtDir)
              OldFile = [IO.File]::Exists("$OldDir\Windows\System32\DEXTEST.bin"); BtFile = [IO.File]::Exists("$BtDir\Sources\DEXTEST.bin") }
}

function Test-AllPlanted {
    $s = Get-FixtureState
    Write-DexNote -Name 'Verify' -Message "Windows.old=$($s.OldFile) `$Windows.~BT=$($s.BtFile)"
    $s.OldFile -and $s.BtFile
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

function Wait-CleanmgrGone {
    # A live scenario may leave Disk Cleanup working; nothing else starts until it has gone.
    $deadline = (Get-Date).AddSeconds(300)
    while ((Get-Date) -lt $deadline -and @(Get-Process -Name 'cleanmgr' -ErrorAction SilentlyContinue).Count -gt 0) { Start-Sleep -Seconds 3 }
}

# -- Scenario definitions ------------------------------------------------------
$BreakCatalog = @(

    @{
        Name = 'NothingPresent'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{}; Run = $CleanupScript
        Apply    = { Assert-NoRealFolders; Remove-Fixtures }
        Verify   = { $s = Get-FixtureState; (-not $s.Old) -and (-not $s.Bt) }
        Validate = {
            $mb = Get-CacheInt 'PreviousWindowsMb'; $s1 = Invoke-Script -Path $SensorScript
            Write-DexNote -Name 'Validate NothingPresent' -Message "PreviousWindowsMb=$mb sensor='$($s1.Output)'"
            ($mb -eq 0) -and ("$($s1.Output)" -eq '0') -and (Test-Run -Contains 'Nothing to do')
        }
    },

    @{
        Name = 'YoungFoldersKept'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{}; Run = $CleanupScript
        Apply    = { New-Fixtures -Old $false }
        Verify   = { Test-AllPlanted }
        Validate = {
            $st = Get-CacheText 'LastPreviousWindowsCleanupStatus'
            Write-DexNote -Name 'Validate YoungFoldersKept' -Message "status=$st"
            (Test-AllPlanted) -and ($st -eq 'NothingEligible') -and (Test-Run -Contains 'inside the 10-day roll-back period')
        }
    },

    @{
        Name = 'WhatIfNoChange'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{ WhatIf = 'true' }; Run = $CleanupScript
        Apply    = { New-Fixtures -Old $true }
        Verify   = { Test-AllPlanted }
        Validate = {
            $st = Get-CacheText 'LastPreviousWindowsCleanupStatus'; $would = Get-CacheInt 'LastPreviousWindowsWouldFreeMb'
            Write-DexNote -Name 'Validate WhatIfNoChange' -Message "status=$st wouldFreeMb=$would"
            (Test-AllPlanted) -and ($st -eq 'WhatIf') -and ($would -ge $PlantedMb) -and (Test-Run -Contains 'would remove')
        }
    },

    @{
        Name = 'RecentSetupLogKept'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{ WhatIf = 'true' }; Run = $CleanupScript
        Apply    = { New-Fixtures -Old $true; [IO.File]::SetLastWriteTime($SetupLog, (Get-Date)) }
        Verify   = { Test-AllPlanted }
        Validate = {
            $out = [string]$script:currentRun.Output
            $btLeft  = [bool]($out -match '(?m)\$Windows\.~BT\).*left: last written')
            $oldGoes = [bool]($out -match '(?m)Windows\.old\).*to be removed')
            Write-DexNote -Name 'Validate RecentSetupLogKept' -Message "`$Windows.~BT reported left=$btLeft Windows.old reported to be removed=$oldGoes"
            (Test-AllPlanted) -and $btLeft -and $oldGoes -and (Test-Run)
        }
    },

    @{
        Name = 'SensorFollowsCollector'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{}; Run = $SensorScript
        Apply    = {
            New-Fixtures -Old $true
            $r = Invoke-Script -Path $CollectorScript
            if ($r.ExitCode -ne 0) { throw "The collector exited $($r.ExitCode): $($r.Output)" }
        }
        Verify   = { Test-AllPlanted }
        Validate = {
            $mb = Get-CacheInt 'PreviousWindowsMb'
            Write-DexNote -Name 'Validate SensorFollowsCollector' -Message "collector PreviousWindowsMb=$mb sensor='$($script:currentRun.Output)'"
            (Test-AllPlanted) -and ($mb -ge $PlantedMb) -and ("$($script:currentRun.Output)" -eq "$mb") -and (Test-Run)
        }
    },

    @{
        Name = 'OldFoldersRemoved'; ExpectedOutcome = 'ExpectFixed'; Variables = @{}; Run = $CleanupScript
        Apply    = { New-Fixtures -Old $true }
        Verify   = { Test-AllPlanted }
        Validate = {
            $s = Get-FixtureState; $st = Get-CacheText 'LastPreviousWindowsCleanupStatus'; $mb = Get-CacheInt 'PreviousWindowsMb'; $s1 = Invoke-Script -Path $SensorScript
            Write-DexNote -Name 'Validate OldFoldersRemoved' -Message "Windows.old left=$($s.Old) `$Windows.~BT left=$($s.Bt) status=$st PreviousWindowsMb=$mb sensor='$($s1.Output)'"
            (-not $s.Old) -and (-not $s.Bt) -and ($st -eq 'Completed') -and ($mb -eq 0) -and ("$($s1.Output)" -eq '0') -and (Test-Run -Contains 'Removed.')
        }
    }
)

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList
Write-DexBanner -Title 'Clear-PreviousWindowsInstall_BreakTest' -Detail "Environment: $Environment"

if ($Resume) { throw 'This harness has no reboot resume; nothing here reboots.' }

if ($Restore) {
    Wait-CleanmgrGone
    Remove-Fixtures
    Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'fixture folders removed'
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
    Assert-NoRealFolders

    $candidates = if ($BreakName) {
        @($BreakCatalog | Where-Object { @($BreakName -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Name })
    } else { @($BreakCatalog) }
    if ($candidates.Count -eq 0) { throw 'No scenario matched the requested selection.' }
    $selected = if ($BreakName) { $candidates } else { Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount }

    foreach ($def in $selected) {
        $b = @{ Name = $def.Name; Method = 'FixturesPlanted'; ExpectedOutcome = $def.ExpectedOutcome; RequiresReboot = $false
                Applied = $false; BreakVerified = $false; OriginalState = @{ Fixtures = 'marked Windows.old and $Windows.~BT' } }
        $state.Breaks = @($state.Breaks) + @($b)
        Save-DexTestState -State $state

        try {
            Wait-CleanmgrGone
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

            $script:currentRun = Invoke-Script -Path $def.Run -Variables $def.Variables
            $script:currentRun.Scenario = $def.Name
            $runs += $script:currentRun
            Write-DexStep -Status 'Info' -Name "Run $($def.Name)" -Message "$($script:currentRun.Script) exit $($script:currentRun.ExitCode) in $($script:currentRun.DurationSec) s"

            $passed   = [bool](& $def.Validate)
            $expected = if ($def.ExpectedOutcome -eq 'ExpectFixed') { 'old folders removed' } else { 'reported, left unmodified' }
            $validation += @{ Name = $def.Name; Expected = $expected; Actual = $(if ($passed) { 'as expected' } else { 'NOT as expected' }); Result = $(if ($passed) { 'Pass' } else { 'Fail' }) }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) -Name "Validate $($def.Name)" -Message $expected
            if (-not $passed) { Write-Host $script:currentRun.Output }
        } catch {
            $anyBreakFailed = $true
            Write-DexStep -Status 'Failed' -Name "Scenario $($def.Name)" -Message $_.Exception.Message
            $validation += @{ Name = $def.Name; Expected = 'scenario completes'; Actual = $_.Exception.Message; Result = 'Fail' }
        } finally {
            try { Wait-CleanmgrGone; Remove-Fixtures } catch { $restoreFailed = $true; Write-DexStep -Status 'Failed' -Name "Reset $($def.Name)" -Message $_.Exception.Message }
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
    try { Wait-CleanmgrGone; Remove-Fixtures } catch { $restoreFailed = $true }
    # The cache key is the scripts' own product; it goes only when this run created it.
    if (-not $hadCache -and (Test-Path -LiteralPath $CachePath)) { Remove-Item -LiteralPath $CachePath -Recurse -Force -ErrorAction SilentlyContinue }
    $s = Get-FixtureState
    if ($restoreFailed -or (($s.Old -and [IO.File]::Exists("$OldDir\$Marker")) -or ($s.Bt -and [IO.File]::Exists("$BtDir\$Marker")))) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'fixtures not fully removed -- run with -Restore -Force'
    } else {
        $state.Phase = 'Restored'
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'fixture folders removed'
    }
}

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) -Name 'Overall' -Message $state.Overall
Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state
exit $exitCode
