<#
.SYNOPSIS
    Test-HorizonScoreParity -- asserts the collector and the all-in-one sensor score a
    host identically.

.DESCRIPTION
    The deduction table lives in two places on purpose (the one-time sensor must stay
    self-contained). This test is what keeps them honest: it runs the collector, then the
    matching OneTimeSensor within the same minute, and compares HealthScore and
    HealthReason, printing both deduction lists side by side. Non-destructive: the
    collector writes its normal cache, the sensor writes nothing.

    Run on a host with the Horizon Agent (-Component Agent), the Horizon Client
    (-Component Client), or both. Needs elevation for the collector's HKLM write.

    Known, accepted divergence (VDI/Horizon/SPEC.md 7.1): the agent sensor's
    TimeSyncStale uses the W32Time registry while the collector uses w32tm.exe, so a
    host whose clock skew exceeds the threshold while its last sync is recent can differ
    by exactly that 5-point rule. The test reports it as TOLERATED, not FAIL.

    Exit 0 when every compared component matches (or differs only by the tolerated rule),
    1 otherwise. Writes C:\Temp\FixReport\Test-HorizonScoreParity\<timestamp>.json.

.NOTES
    Script Name  : Test-HorizonScoreParity.ps1
    Version      : 1.0.0
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
param(
    [ValidateSet('Agent', 'Client', 'Both')][string]$Component = 'Both',
    [string]$ReportRoot = 'C:\Temp\FixReport\Test-HorizonScoreParity'
)

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
$report = New-Object System.Collections.Generic.List[object]
$anyFail = $false

function Invoke-Child { param([string]$Path) $out = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path 2>&1 | ForEach-Object { [string]$_ }); return @{ Output = $out; Exit = $LASTEXITCODE } }

$plan = @()
if ($Component -in @('Agent', 'Both'))  { $plan += @{ Name = 'Agent';  Collector = 'Invoke-HorizonAgentStateCollection.ps1';  Sensor = 'OneTimeSensor\hzn_agent_health.ps1';  Key = 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Agent' } }
if ($Component -in @('Client', 'Both')) { $plan += @{ Name = 'Client'; Collector = 'Invoke-HorizonClientStateCollection.ps1'; Sensor = 'OneTimeSensor\hzn_client_health.ps1'; Key = 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Client' } }

Write-Host "`nTest-HorizonScoreParity on $env:COMPUTERNAME  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"

foreach ($p in $plan) {
    Write-Host "== $($p.Name)"
    $c = Invoke-Child (Join-Path $Root $p.Collector)
    $cache = Get-ItemProperty -Path $p.Key -ErrorAction SilentlyContinue
    $s = Invoke-Child (Join-Path $Root $p.Sensor)
    $j = $null; try { $j = $s.Output[0] | ConvertFrom-Json } catch { }

    $cScore = if ($cache) { [int][double]$cache.HealthScore } else { $null }
    $cReason = if ($cache) { [string]$cache.HealthReason } else { '' }
    $cDed = if ($cache -and $cache.Deductions) { @([string]$cache.Deductions -split ';') } else { @() }
    # Schema 2 compact keys (SPEC section 7 rev 2): Score, Reason, Ded rows [Reason, Points], TO.
    $sScore = if ($j) { [int]$j.Score } else { $null }
    $sReason = if ($j) { [string]$j.Reason } else { '' }
    $sDed = if ($j) { @($j.Ded | ForEach-Object { "$($_[0]):$($_[1])" }) } else { @() }

    "  {0,-28} {1,-30} {2,-30}" -f '', 'Collector', 'One-time sensor' | Write-Host
    "  {0,-28} {1,-30} {2,-30}" -f 'Exit / lines', "$($c.Exit)", "$($s.Exit) / $($s.Output.Count)" | Write-Host
    "  {0,-28} {1,-30} {2,-30}" -f 'HealthScore', "$cScore", "$sScore" | Write-Host
    "  {0,-28} {1,-30} {2,-30}" -f 'HealthReason', $cReason, $sReason | Write-Host
    $n = [math]::Max($cDed.Count, $sDed.Count)
    for ($i = 0; $i -lt $n; $i++) { "  {0,-28} {1,-30} {2,-30}" -f $(if ($i -eq 0) { 'Deductions' } else { '' }), $(if ($i -lt $cDed.Count) { $cDed[$i] } else { '' }), $(if ($i -lt $sDed.Count) { $sDed[$i] } else { '' }) | Write-Host }
    if ($j -and $j.TO) { Write-Host '  note: sensor TO (timed out) = true; its score is a floor' -ForegroundColor Yellow }

    $verdict = 'FAIL'
    if ($null -ne $cScore -and $null -ne $sScore) {
        if ($cScore -eq $sScore -and $cReason -eq $sReason) { $verdict = 'PASS' }
        else {
            $diff = @(Compare-Object $cDed $sDed | ForEach-Object { $_.InputObject })
            if ($diff.Count -eq 1 -and $diff[0] -eq 'TimeSyncStale:5' -and [math]::Abs($cScore - $sScore) -eq 5) { $verdict = 'TOLERATED' }
        }
    }
    if ($verdict -eq 'FAIL') { $anyFail = $true }
    Write-Host "  Verdict: $verdict`n" -ForegroundColor $(switch ($verdict) { 'PASS' { 'Green' } 'TOLERATED' { 'Yellow' } default { 'Red' } })
    $report.Add([ordered]@{ Component = $p.Name; Verdict = $verdict; CollectorScore = $cScore; CollectorReason = $cReason; CollectorDeductions = $cDed; SensorScore = $sScore; SensorReason = $sReason; SensorDeductions = $sDed; SensorTimedOut = $(if ($j) { [bool]$j.TO } else { $null }) })
}

if (-not (Test-Path $ReportRoot)) { New-Item -ItemType Directory -Path $ReportRoot -Force | Out-Null }
$file = Join-Path $ReportRoot "$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
[ordered]@{ Machine = $env:COMPUTERNAME; RanAt = (Get-Date).ToString('o'); Components = $report } | ConvertTo-Json -Depth 5 | Set-Content -Path $file -Encoding UTF8
Write-Host "  [Result] $file`n"
if ($anyFail) { exit 1 }
exit 0
