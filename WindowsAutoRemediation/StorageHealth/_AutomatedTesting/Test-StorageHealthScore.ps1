<#
.SYNOPSIS
    Test-StorageHealthScore -- unit tests for the storage health deduction table, and the
    parity check between the script's and the sensor's copy of the shared block.

.DESCRIPTION
    Non-destructive and needs no elevation. Lab devices are virtual machines with a healthy
    virtual disk, so a failing drive, a worn SSD or bad blocks cannot be produced there;
    this test feeds Get-StorageScore synthetic facts instead.

      1. Parity: Get-StorageFacts and Get-StorageScore must be text-identical in
         Invoke-AutoRemediateStorageHealth.ps1 and OneTimeSensor\storage_health.ps1.
      2. Score table: one case per deduction, plus combinations, the floor at 0, the
         virtual-machine gate and the NextStep rules.
      3. Live facts: Get-StorageFacts runs on this machine and returns every key with a
         usable type.
      4. Sensor: the one-time sensor returns valid JSON under 1,000 bytes whose Score and
         Reason match Get-StorageScore over the live facts.
      5. Size: a payload carrying every deduction still fits after the Ded trim.

    Exit 0 when every assertion passes, 1 otherwise.

.NOTES
    Script Name  : Test-StorageHealthScore.ps1
    Version      : 1.0.0
    Context      : Any user (elevation only adds wear, temperature and SMART prediction)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-16

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
#Requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
$Root       = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ScriptPath = Join-Path $Root 'Invoke-AutoRemediateStorageHealth.ps1'
$SensorPath = Join-Path $Root 'OneTimeSensor\storage_health.ps1'

$script:Pass = 0
$script:Fail = 0
function Assert-That {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { $script:Pass++; Write-Host "  [PASS] $Name" }
    else { $script:Fail++; Write-Host "  [FAIL] $Name  $Detail" -ForegroundColor Red }
}

function Get-FunctionText {
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has $($errors.Count) parse error(s)" }
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1
    if (-not $fn) { throw "$Name not found in $Path" }
    return ($fn.Extent.Text -replace "`r`n", "`n")
}

Write-Host "`nTest-StorageHealthScore on $env:COMPUTERNAME  PowerShell $($PSVersionTable.PSVersion)  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# -- 1. Parity -----------------------------------------------------------------
Write-Host "`n== 1. Shared block parity"
$text = @{}
foreach ($name in 'Get-StorageFacts', 'Get-StorageScore') {
    $a = Get-FunctionText -Path $ScriptPath -Name $name
    $b = Get-FunctionText -Path $SensorPath -Name $name
    Assert-That ($a -ceq $b) "$name is identical in the script and the sensor" "script $($a.Length) chars, sensor $($b.Length) chars"
    $text[$name] = $a
}
. ([scriptblock]::Create($text['Get-StorageFacts']))
. ([scriptblock]::Create($text['Get-StorageScore']))

# -- 2. Score table ------------------------------------------------------------
Write-Host "`n== 2. Score table (synthetic facts)"
function New-Facts {
    param([hashtable]$Override = @{})
    $f = [ordered]@{
        Virtual = $false; ConfigChecks = $true; SysDisk = 0; Model = 'Test SSD'; Media = 'SSD'; Bus = 'NVMe'; SizeGB = 512
        Health = 0; PredictFail = $false; Wear = 5; TempC = 38; MediaErrors = 0; PowerOnHours = 1200
        OtherDisks = 0; OtherBad = 0; VolHealth = 0
        EventDays = 7; BadBlocks = 0; IoErrors = 0; FsErrors = 0
        TrimDisabled = $false; OptimizeTask = 'Enabled'; DaysSinceOptimize = 3
    }
    foreach ($k in $Override.Keys) { $f[$k] = $Override[$k] }
    return $f
}

$cases = @(
    @{ Name = 'Healthy SSD';                      Facts = @{};                                              Score = 100; Reason = 'Healthy';                Next = 'NONE' },
    @{ Name = 'SMART predicts failure';           Facts = @{ PredictFail = $true };                         Score = 40;  Reason = 'DriveFailing';           Next = 'ADMIN' },
    @{ Name = 'Drive Unhealthy';                  Facts = @{ Health = 2 };                                  Score = 40;  Reason = 'DriveFailing';           Next = 'ADMIN' },
    @{ Name = 'Predicted and Unhealthy count once'; Facts = @{ PredictFail = $true; Health = 2 };           Score = 40;  Reason = 'DriveFailing';           Next = 'ADMIN' },
    @{ Name = 'Drive Warning';                    Facts = @{ Health = 1 };                                  Score = 70;  Reason = 'DriveWarning';           Next = 'ADMIN' },
    @{ Name = 'Bad blocks';                       Facts = @{ BadBlocks = 2 };                               Score = 75;  Reason = 'BadBlocks';              Next = 'ADMIN' },
    @{ Name = 'Wear 90';                          Facts = @{ Wear = 90 };                                   Score = 75;  Reason = 'WearHigh';               Next = 'ADMIN' },
    @{ Name = 'Wear 89 is not flagged';           Facts = @{ Wear = 89 };                                   Score = 100; Reason = 'Healthy';                Next = 'NONE' },
    @{ Name = 'Wear unknown (-1) is not flagged'; Facts = @{ Wear = -1; TempC = -1; MediaErrors = -1 };     Score = 100; Reason = 'Healthy';                Next = 'NONE' },
    @{ Name = 'Media errors';                     Facts = @{ MediaErrors = 3 };                             Score = 80;  Reason = 'MediaErrors';            Next = 'ADMIN' },
    @{ Name = 'File system errors';               Facts = @{ FsErrors = 1 };                                Score = 80;  Reason = 'FileSystemErrors';       Next = 'ADMIN' },
    @{ Name = 'I/O errors, 5 or more';            Facts = @{ IoErrors = 5 };                                Score = 85;  Reason = 'IoErrors';               Next = 'ADMIN' },
    @{ Name = 'I/O errors, 1 to 4';               Facts = @{ IoErrors = 4 };                                Score = 95;  Reason = 'IoErrors';               Next = 'ADMIN' },
    @{ Name = 'Second drive unhealthy';           Facts = @{ OtherDisks = 1; OtherBad = 1 };                Score = 85;  Reason = 'SecondaryDriveUnhealthy'; Next = 'ADMIN' },
    @{ Name = 'Drive hot at 70 C';                Facts = @{ TempC = 70 };                                  Score = 90;  Reason = 'DriveHot';               Next = 'ADMIN' },
    @{ Name = '69 C is not flagged';              Facts = @{ TempC = 69 };                                  Score = 100; Reason = 'Healthy';                Next = 'NONE' },
    @{ Name = 'Spinning boot disk';               Facts = @{ Media = 'HDD' };                               Score = 85;  Reason = 'SpinningBootDrive';      Next = 'ADMIN' },
    @{ Name = 'Volume scan needed';               Facts = @{ VolHealth = 1 };                               Score = 85;  Reason = 'VolumeScanNeeded';       Next = 'AUTO' },
    @{ Name = 'Volume spot fix needed';           Facts = @{ VolHealth = 2 };                               Score = 80;  Reason = 'VolumeRepairAtRestart';  Next = 'USER' },
    @{ Name = 'Volume full repair needed';        Facts = @{ VolHealth = 3 };                               Score = 80;  Reason = 'VolumeRepairAtRestart';  Next = 'USER' },
    @{ Name = 'TRIM off on SSD';                  Facts = @{ TrimDisabled = $true };                        Score = 90;  Reason = 'TrimDisabled';           Next = 'AUTO' },
    @{ Name = 'TRIM off on HDD is only the HDD';  Facts = @{ TrimDisabled = $true; Media = 'HDD' };         Score = 85;  Reason = 'SpinningBootDrive';      Next = 'ADMIN' },
    @{ Name = 'Optimize task disabled';           Facts = @{ OptimizeTask = 'Disabled' };                   Score = 90;  Reason = 'OptimizeDisabled';       Next = 'AUTO' },
    @{ Name = 'Disabled and stale count once';    Facts = @{ OptimizeTask = 'Disabled'; DaysSinceOptimize = 400 }; Score = 90; Reason = 'OptimizeDisabled'; Next = 'AUTO' },
    @{ Name = 'Optimize stale';                   Facts = @{ DaysSinceOptimize = 46 };                      Score = 95;  Reason = 'OptimizeStale';          Next = 'AUTO' },
    @{ Name = '45 days is not stale';             Facts = @{ DaysSinceOptimize = 45 };                      Score = 100; Reason = 'Healthy';                Next = 'NONE' },
    @{ Name = 'Missing task is not graded';       Facts = @{ OptimizeTask = 'Missing'; DaysSinceOptimize = -1 }; Score = 100; Reason = 'Healthy';           Next = 'NONE' },
    @{ Name = 'VM: config findings not graded';   Facts = @{ Virtual = $true; ConfigChecks = $false; Media = 'HDD'; TrimDisabled = $true; OptimizeTask = 'Disabled' }; Score = 100; Reason = 'Healthy'; Next = 'NONE' },
    @{ Name = 'VM: hardware findings still graded'; Facts = @{ Virtual = $true; ConfigChecks = $false; Health = 1; VolHealth = 1 }; Score = 55; Reason = 'DriveWarning'; Next = 'ADMIN' },
    @{ Name = 'VM included: config graded';       Facts = @{ Virtual = $true; ConfigChecks = $true; TrimDisabled = $true; OptimizeTask = 'Disabled' }; Score = 80; Reason = 'TrimDisabled'; Next = 'AUTO' },
    @{ Name = 'Hardware beats fixable for NextStep'; Facts = @{ IoErrors = 1; VolHealth = 2 };              Score = 75;  Reason = 'VolumeRepairAtRestart';  Next = 'ADMIN' },
    @{ Name = 'Restart beats AUTO';               Facts = @{ VolHealth = 2; TrimDisabled = $true };         Score = 70;  Reason = 'VolumeRepairAtRestart';  Next = 'USER' },
    @{ Name = 'Everything wrong floors at 0';     Facts = @{ PredictFail = $true; BadBlocks = 9; Wear = 99; MediaErrors = 9; FsErrors = 9; IoErrors = 9; OtherBad = 1; TempC = 80; Media = 'HDD'; VolHealth = 3; OptimizeTask = 'Disabled' }; Score = 0; Reason = 'DriveFailing'; Next = 'ADMIN' }
)
foreach ($c in $cases) {
    $s = Get-StorageScore -Facts (New-Facts $c.Facts) -StaleDays 45
    $ok = ($s.Score -eq $c.Score -and $s.Reason -eq $c.Reason -and $s.NextStep -eq $c.Next)
    Assert-That $ok $c.Name "expected $($c.Score)/$($c.Reason)/$($c.Next), got $($s.Score)/$($s.Reason)/$($s.NextStep)"
}
$s = Get-StorageScore -Facts (New-Facts @{ DaysSinceOptimize = 10 }) -StaleDays 7
Assert-That ($s.Reason -eq 'OptimizeStale') 'StaleDays parameter is honoured' "got $($s.Reason)"
$s = Get-StorageScore -Facts (New-Facts @{ IoErrors = 1; VolHealth = 2 }) -StaleDays 45
Assert-That ($s.Detail -match 'I/O errors') 'ADMIN detail names the hardware finding, not the larger fixable one' "got '$($s.Detail)'"
$s = Get-StorageScore -Facts (New-Facts @{ TrimDisabled = $true }) -StaleDays 45
Assert-That ($s.Detail -eq 'Invoke-AutoRemediateStorageHealth.ps1') 'AUTO detail names the script' "got '$($s.Detail)'"
$all = Get-StorageScore -Facts (New-Facts @{ PredictFail = $true; BadBlocks = 9; Wear = 99; MediaErrors = 9; FsErrors = 9; IoErrors = 9; OtherBad = 1; TempC = 80; Media = 'HDD'; VolHealth = 3; OptimizeTask = 'Disabled' }) -StaleDays 45
$noAngle = -not (@($all.Detail) + @((Get-StorageScore -Facts (New-Facts @{ VolHealth = 2 })).Detail) | Where-Object { $_ -match '[<>&]' })
Assert-That $noAngle 'Detail strings carry no characters Windows PowerShell 5.1 escapes in JSON'

# -- 3. Live facts -------------------------------------------------------------
Write-Host "`n== 3. Live facts on this machine"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$live = Get-StorageFacts -EventDays 7 -IncludeVirtual $false
$sw.Stop()
$expected = (New-Facts).Keys
$missing = @($expected | Where-Object { -not $live.Contains($_) })
Assert-That ($missing.Count -eq 0) 'Get-StorageFacts returns every key' "missing: $($missing -join ', ')"
Assert-That ($live.SysDisk -ge 0) 'The drive behind the system volume was found' "SysDisk=$($live.SysDisk)"
Assert-That ($live.Media -in 'SSD', 'HDD', 'SCM', 'Unknown') 'Media is one of the documented values' "Media=$($live.Media)"
Assert-That ($live.VolHealth -in 0, 1, 2, 3) 'System volume health was read' "VolHealth=$($live.VolHealth)"
# A VMware virtual NVMe disk reports 254 C under SYSTEM (UEM run 74690e, 2026-11-16); only 1 to 110 is a reading.
Assert-That ($live.TempC -eq -1 -or ($live.TempC -ge 1 -and $live.TempC -le 110)) 'Temperature is unknown or plausible' "TempC=$($live.TempC)"
Assert-That ($text['Get-StorageFacts'] -match 'Temperature -gt 0 -and \$r\.Temperature -le 110') 'Get-StorageFacts bounds the temperature reading'
Assert-That ($live.OptimizeTask -in 'Enabled', 'Disabled', 'Missing') 'Optimize Drives task state was read' "OptimizeTask=$($live.OptimizeTask)"
Assert-That ($sw.Elapsed.TotalSeconds -lt 20) 'Get-StorageFacts finished inside the 25 s sensor budget' "$([int]$sw.Elapsed.TotalSeconds) s"
Write-Host ("  facts: " + ((@($live.Keys | ForEach-Object { "$_=$($live[$_])" })) -join ' '))

# -- 4. Sensor -----------------------------------------------------------------
Write-Host "`n== 4. One-time sensor"
$engine = (Get-Process -Id $PID).Path
$out = @(& $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $SensorPath 2>&1 | ForEach-Object { [string]$_ })
Assert-That ($out.Count -eq 1) 'The sensor writes exactly one value' "$($out.Count) line(s)"
$json = "$($out[0])"
$obj = $null
try { $obj = $json | ConvertFrom-Json } catch { }
Assert-That ($null -ne $obj) 'The value is valid JSON' $json
Assert-That ($json.Length -le 1000) 'The value is under 1,000 bytes' "$($json.Length) bytes"
if ($obj) {
    $liveScore = Get-StorageScore -Facts $live -StaleDays 45
    Assert-That ($obj.Score -eq $liveScore.Score -and $obj.Reason -eq $liveScore.Reason) 'Sensor Score and Reason match the shared table over live facts' "sensor $($obj.Score)/$($obj.Reason), table $($liveScore.Score)/$($liveScore.Reason)"
    Assert-That ($obj.Schema -eq 1 -and $null -ne $obj.NextStep) 'Schema and NextStep are present'
    Write-Host "  sensor: $json"
}

# -- 5. Worst-case size --------------------------------------------------------
Write-Host "`n== 5. Worst-case payload size"
$worst = [ordered]@{
    Schema = 1; Collected = (Get-Date -Format 's'); ElapsedMs = 24999; Virtual = $false
    Model = ('M' * 28); Media = 'Unknown'; Bus = 'Spaces'; SizeGB = 16000
    Health = 'Unhealthy'; PredictFail = $false; Wear = 100; TempC = 100; MediaErrors = 999999; PowerOnHours = 1999999
    OtherDisks = 12; OtherBad = 12; Volume = 'FullRepairNeeded'
    EventDays = 30; BadBlocks = 5000; IoErrors = 5000; FsErrors = 5000
    Trim = 'Off'; OptimizeTask = 'Disabled'; DaysSinceOptimize = 99999
    Score = 0; Reason = 'SecondaryDriveUnhealthy'; NextStep = 'ADMIN'; Detail = ('D' * 70)
    Ded = @($all.Deductions.Keys | ForEach-Object { "${_}:$($all.Deductions[$_])" })
}
$full = (ConvertTo-Json -InputObject $worst -Compress -Depth 3).Length
$worst.Ded = @()
$bare = (ConvertTo-Json -InputObject $worst -Compress -Depth 3).Length
Assert-That ($bare -le 1000) 'A worst-case payload fits once Ded is trimmed away' "$bare bytes without Ded"
Write-Host "  worst case: $full bytes with all $($all.Deductions.Count) deductions listed, $bare bytes with none"

Write-Host "`n$($script:Pass) passed, $($script:Fail) failed`n"
if ($script:Fail -gt 0) { exit 1 }
exit 0
