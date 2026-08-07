<#
.SYNOPSIS
    Invoke-AllBreakTests -- discovers and runs every *_BreakTest.ps1, then analyses the results.

.DESCRIPTION
    Finds break tests in any _AutomatedTesting folder beneath the repo root, runs each
    in sequence, and hands off to Invoke-FixReportAnalysis.ps1.

    REBOOT-REQUIRING BREAKS ARE EXCLUDED HERE BY DESIGN. A break that reboots the
    machine terminates this orchestrator mid-run, and the resumed test would complete
    without it. Run those individually with -IncludeRebootBreaks on the break test
    itself, then re-run the analyser to pick the results up.

.PARAMETER Force
    Required. Acknowledges that every discovered test is destructive.

.PARAMETER RemediationTest
    Pass -RemediationTest through to each break test. Without it they break and report only.

.PARAMETER Environment
    Physical (default) restores after each run. Snapshot assumes the host reverts.

.PARAMETER Include
    Wildcard filter on break-test file name, e.g. '*Printer*'.

.NOTES
    Script Name  : Invoke-AllBreakTests.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-07

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [switch]$Force,
    [switch]$RemediationTest,
    [ValidateSet('Snapshot', 'Physical')][string]$Environment = 'Physical',
    [string]$Include = '*',
    [int]$BreakCount = 2,
    [string]$FixReportPath = 'C:\Temp\FixReport',
    [string[]]$ProductionDomainDenyList = @()
)

if (-not $Force) {
    Write-Host 'REFUSING TO RUN. Every discovered break test is destructive; pass -Force to acknowledge.' -ForegroundColor Red
    exit 1
}

$repoRoot = Split-Path -Parent $PSScriptRoot

$tests = @(Get-ChildItem -LiteralPath $repoRoot -Filter '*_BreakTest.ps1' -Recurse -ErrorAction SilentlyContinue |
           Where-Object { $_.Directory.Name -eq '_AutomatedTesting' -and $_.Name -like $Include })

Write-Host ''
Write-Host '-- Invoke-AllBreakTests '.PadRight(64, '-') -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Discovered: $($tests.Count)   Environment: $Environment"
Write-Host ('-' * 64) -ForegroundColor Cyan

if ($tests.Count -eq 0) {
    Write-Host "  No *_BreakTest.ps1 found under $repoRoot." -ForegroundColor Yellow
    exit 0
}

foreach ($test in $tests) {

    Write-Host ''
    Write-Host "  >> $($test.Name)" -ForegroundColor White

    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$($test.FullName)`"",
        '-Force',
        '-Environment', $Environment,
        '-BreakCount', $BreakCount
    )
    if ($RemediationTest) { $argList += '-RemediationTest' }
    if ($ProductionDomainDenyList.Count -gt 0) {
        $argList += @('-ProductionDomainDenyList', ($ProductionDomainDenyList -join ','))
    }

    # Each test runs in its own process so one crashing cannot abort the sweep.
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Wait -PassThru -NoNewWindow
    Write-Host "     exit $($proc.ExitCode)" -ForegroundColor DarkCyan
}

Write-Host ''
& (Join-Path $PSScriptRoot 'Invoke-FixReportAnalysis.ps1') -Path $FixReportPath
exit $LASTEXITCODE
