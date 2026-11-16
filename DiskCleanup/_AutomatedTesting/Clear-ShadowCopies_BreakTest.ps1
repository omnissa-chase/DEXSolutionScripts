<#
.SYNOPSIS
    Clear-ShadowCopies_BreakTest -- creates three shadow copies of the system drive, then
    verifies Clear-ShadowCopies.ps1 deletes all but the newest and that the
    disk_shadowcopy_mb sensor follows.

.DESCRIPTION
    Covers Clear-ShadowCopies.ps1 and Sensors\disk_shadowcopy_mb.ps1 (with
    Invoke-DiskStateCollection.ps1 as the sensor's source). Each scenario is its own
    cycle: remove fixtures -> create -> verify -> run -> validate -> remove fixtures.
    Writes the uniform JSON result to C:\Temp\FixReport\Clear-ShadowCopies\.

    THE FIXTURES
    Three persistent, client-accessible shadow copies of the system drive, created
    through Win32_ShadowCopy.Create two seconds apart: the same kind System Restore
    makes. They hold almost no data, so MB figures are checked for consistency, not size.

    THE HOST'S OWN RESTORE POINTS
    The script under test is the real one: the live scenarios delete the host's own
    restore points too, except the newest copy on the drive (which is the last fixture,
    and is removed with the fixtures). That is not put back.

    SCENARIOS
      OldCopiesDeleted       live run -> exactly one copy left on the drive, the newest
                             fixture; Status Completed; at least two deleted
      WhatIfNoChange         WhatIf=true -> "Would delete", every copy still there
      BelowMinimumNoChange   a copy with MinTotalMb = 99999999 -> "Below the", unchanged
      KeepAllNoChange        a copy with KeepNewest = 99 -> Status NothingToDelete, unchanged
      CleanupRefreshesSensor collector, then the cleanup -> disk_shadowcopy_mb returns
                             the cached ShadowCopyMb before and after

    Not covered: MaxStoragePercent (it changes the device's storage limit), a snapshot
    held by a backup product, shadow copies of other drives.

.PARAMETER RemediationTest
    Run the scripts after each scenario's fixtures are in place and validate.
.PARAMETER Environment
    Physical (default) removes the fixtures when the run ends. Snapshot leaves them.
.PARAMETER Seed
    Replays an earlier run's scenario order. Recorded in the result.
.PARAMETER BreakName
    Run specific scenarios instead of a random selection.
.PARAMETER BreakCount
    How many scenarios to run when selecting randomly. Default 5 (all).
.PARAMETER Restore
    Remove the fixtures after an interrupted run.
.PARAMETER Force
    Required acknowledgement.

.NOTES
    Script Name  : Clear-ShadowCopies_BreakTest.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Reporting    : C:\Temp\FixReport\Clear-ShadowCopies\

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
    [int]$BreakCount = 5,
    [switch]$IncludeRebootBreaks,
    [switch]$Restore,
    [switch]$Resume,
    [switch]$Force,
    [string[]]$ProductionDomainDenyList = @()
)

$ErrorActionPreference = 'Stop'

$ScriptUnderTest = 'Clear-ShadowCopies'
$CleanupScript   = Join-Path $PSScriptRoot '..\Clear-ShadowCopies.ps1'
$CollectorScript = Join-Path $PSScriptRoot '..\Invoke-DiskStateCollection.ps1'
$SensorScript    = Join-Path $PSScriptRoot '..\Sensors\disk_shadowcopy_mb.ps1'
$CachePath       = 'HKLM:\Software\AirWatch\Extensions\DiskState'
$ReportDir       = "C:\Temp\FixReport\$ScriptUnderTest"
$IdFile          = "$ReportDir\fixture-ids.txt"
$Sys             = [string]$env:SystemDrive

$modulePath = Join-Path $PSScriptRoot '..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "DEXTestFramework.psm1 not found at $modulePath" }
Import-Module $modulePath -Force

# -- Helpers ------------------------------------------------------------------

function Write-DexNote {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Message = '')
    Write-Host "  [Info   ] $Name$(if ($Message) { ": $Message" })" -ForegroundColor Gray
}

function Get-Copies {
    # Persistent, client-accessible shadow copies of the system drive, newest first. Emits them one by one.
    $vol = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$Sys'"
    Get-CimInstance -ClassName Win32_ShadowCopy | Where-Object { $_.VolumeName -eq $vol.DeviceID -and $_.Persistent -and $_.ClientAccessible } | Sort-Object InstallDate -Descending
}

function Get-FixtureIds {
    if (Test-Path -LiteralPath $IdFile) { return @(Get-Content -LiteralPath $IdFile | Where-Object { $_ }) }
    return @()
}

function Remove-Fixtures {
    $ids = @(Get-FixtureIds)
    foreach ($c in @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction SilentlyContinue)) {
        if ($ids -contains $c.ID) { try { Remove-CimInstance -InputObject $c -ErrorAction Stop } catch { } }
    }
    if (Test-Path -LiteralPath $IdFile) { Remove-Item -LiteralPath $IdFile -Force }
}

function New-Fixtures {
    Remove-Fixtures
    if (-not (Test-Path -LiteralPath $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
    $ids = @()
    foreach ($n in 1..3) {
        $r = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{ Volume = "$Sys\"; Context = 'ClientAccessible' }
        if ([int]$r.ReturnValue -ne 0) { throw "Win32_ShadowCopy.Create returned $($r.ReturnValue) (is the Volume Shadow Copy service available on this host?)" }
        $ids += [string]$r.ShadowID
        Add-Content -LiteralPath $IdFile -Value ([string]$r.ShadowID)
        Start-Sleep -Seconds 2
    }
    $script:newestId = $ids[-1]
    $script:countBefore = @(Get-Copies).Count
}

function Get-FixtureCount {
    $ids = @(Get-FixtureIds)
    return @(Get-Copies | Where-Object { $ids -contains $_.ID }).Count
}

function Test-AllPlanted {
    $n = Get-FixtureCount
    Write-DexNote -Name 'Verify' -Message "fixture shadow copies=$n of 3; copies on $Sys in all=$($script:countBefore)"
    $n -eq 3
}

function Test-Unchanged {
    $now = @(Get-Copies).Count
    Write-DexNote -Name 'Validate' -Message "copies on $Sys before=$($script:countBefore) now=$now fixtures=$(Get-FixtureCount)"
    ($now -eq $script:countBefore) -and ((Get-FixtureCount) -eq 3)
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
        Name = 'OldCopiesDeleted'; ExpectedOutcome = 'ExpectFixed'; Variables = @{}; Run = $CleanupScript
        Apply    = { New-Fixtures }
        Verify   = { Test-AllPlanted }
        Validate = {
            $left = @(Get-Copies); $st = Get-CacheText 'LastShadowCopyCleanupStatus'; $del = Get-CacheInt 'LastShadowCopyDeleted'
            Write-DexNote -Name 'Validate OldCopiesDeleted' -Message "copies left=$($left.Count) newest fixture kept=$($left.Count -eq 1 -and $left[0].ID -eq $script:newestId) deleted=$del status=$st"
            ($left.Count -eq 1) -and ($left[0].ID -eq $script:newestId) -and ($del -ge 2) -and ($st -eq 'Completed') -and (Test-Run -Contains 'Deleted ')
        }
    },

    @{
        Name = 'WhatIfNoChange'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{ WhatIf = 'true' }; Run = $CleanupScript
        Apply    = { New-Fixtures }
        Verify   = { Test-AllPlanted }
        Validate = { (Test-Unchanged) -and ((Get-CacheText 'LastShadowCopyCleanupStatus') -eq 'WhatIf') -and (Test-Run -Contains 'Would delete') }
    },

    @{
        Name = 'BelowMinimumNoChange'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{}; Run = { New-Variant -Name 'MinTotalMb' -Setting 'MinTotalMb' -Value '99999999' }
        Apply    = { New-Fixtures }
        Verify   = { Test-AllPlanted }
        Validate = { (Test-Unchanged) -and (Test-Run -Contains 'Below the 99999999 MB minimum') }
    },

    @{
        Name = 'KeepAllNoChange'; ExpectedOutcome = 'ExpectReportedOnly'; Variables = @{}; Run = { New-Variant -Name 'KeepNewest' -Setting 'KeepNewest' -Value '99' }
        Apply    = { New-Fixtures }
        Verify   = { Test-AllPlanted }
        Validate = { (Test-Unchanged) -and ((Get-CacheText 'LastShadowCopyCleanupStatus') -eq 'NothingToDelete') -and (Test-Run -Contains 'to delete: 0') }
    },

    @{
        Name = 'CleanupRefreshesSensor'; ExpectedOutcome = 'ExpectFixed'; Variables = @{}; Run = $CleanupScript
        Apply    = {
            New-Fixtures
            $r = Invoke-Script -Path $CollectorScript
            if ($r.ExitCode -ne 0) { throw "The collector exited $($r.ExitCode): $($r.Output)" }
            $script:before = Get-CacheInt 'ShadowCopyMb'
            $script:sensorBefore = (Invoke-Script -Path $SensorScript).Output
        }
        Verify   = {
            Write-DexNote -Name 'Verify' -Message "collector ShadowCopyMb=$($script:before) sensor='$($script:sensorBefore)'"
            (Test-AllPlanted) -and ($script:before -ge 0) -and ("$($script:sensorBefore)" -eq "$($script:before)")
        }
        Validate = {
            $after = Get-CacheInt 'ShadowCopyMb'; $s1 = Invoke-Script -Path $SensorScript; $left = @(Get-Copies).Count
            Write-DexNote -Name 'Validate CleanupRefreshesSensor' -Message "ShadowCopyMb before=$($script:before) after=$after sensor='$($s1.Output)' copies left=$left"
            ($after -ge 0) -and ($after -le $script:before) -and ("$($s1.Output)" -eq "$after") -and ($left -eq 1) -and (Test-Run)
        }
    }
)

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList
Write-DexBanner -Title 'Clear-ShadowCopies_BreakTest' -Detail "Environment: $Environment"

if ($Resume) { throw 'This harness has no reboot resume; nothing here reboots.' }

if ($Restore) {
    Remove-Fixtures
    Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'fixture shadow copies removed'
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
        $b = @{ Name = $def.Name; Method = 'ShadowCopiesCreated'; ExpectedOutcome = $def.ExpectedOutcome; RequiresReboot = $false
                Applied = $false; BreakVerified = $false; OriginalState = @{ Fixtures = 'three shadow copies' } }
        $state.Breaks = @($state.Breaks) + @($b)
        Save-DexTestState -State $state

        try {
            & $def.Apply
            $b.Applied = $true
            Write-DexStep -Status 'Info' -Name "Scenario $($def.Name)" -Message 'shadow copies created'

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
            $expected = if ($def.ExpectedOutcome -eq 'ExpectFixed') { 'old copies deleted, newest kept' } else { 'reported, left unmodified' }
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
    if ($restoreFailed) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'fixtures not fully removed -- run with -Restore -Force'
    } else {
        $state.Phase = 'Restored'
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'fixture shadow copies removed (the host''s own old restore points stay deleted)'
    }
}

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) -Name 'Overall' -Message $state.Overall
Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state
exit $exitCode
