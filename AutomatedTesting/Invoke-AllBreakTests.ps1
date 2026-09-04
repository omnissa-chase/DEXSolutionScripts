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
    Write-Output 'REFUSING TO RUN. Every discovered break test is destructive; pass -Force to acknowledge.'
    exit 1
}

$repoRoot = Split-Path -Parent $PSScriptRoot

$tests = @(Get-ChildItem -LiteralPath $repoRoot -Filter '*_BreakTest.ps1' -Recurse -ErrorAction SilentlyContinue |
           Where-Object { $_.Directory.Name -eq '_AutomatedTesting' -and $_.Name -like $Include })

Write-Output ''
Write-Output '-- Invoke-AllBreakTests '.PadRight(64, '-')
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Discovered: $($tests.Count)   Environment: $Environment"
Write-Output ('-' * 64)

if ($tests.Count -eq 0) {
    Write-Output "  No *_BreakTest.ps1 found under $repoRoot."
    exit 0
}

foreach ($test in $tests) {

    Write-Output ''
    Write-Output "  >> $($test.Name)"

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
    Write-Output "     exit $($proc.ExitCode)"
}

Write-Output ''
& (Join-Path $PSScriptRoot 'Invoke-FixReportAnalysis.ps1') -Path $FixReportPath
exit $LASTEXITCODE
