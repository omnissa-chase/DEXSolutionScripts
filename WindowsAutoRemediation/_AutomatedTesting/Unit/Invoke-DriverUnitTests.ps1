<#
.SYNOPSIS
    Invoke-DriverUnitTests -- runs the non-destructive driver remediation unit tests.

.DESCRIPTION
    Thin wrapper around Invoke-Pester for every *.Tests.ps1 in this folder. Works with
    the Pester 3.4 that ships in-box on Windows 10/11 and with Pester 5. Needs no
    elevation, no snapshot and no real hardware: every test runs the script under test
    in a child process with WMI and pnputil stubbed (see DriverTestKit.ps1).

    Run these BEFORE the destructive *_BreakTest.ps1 harnesses. A failure here is a
    logic or scoping defect and there is no point breaking a lab machine to find it.

.PARAMETER OutputFile
    NUnit XML result path. Defaults under C:\Temp\FixReport so it sits next to the
    break-test results.

.EXAMPLE
    .\Invoke-DriverUnitTests.ps1
    Exit code is the number of failed tests (0 = all green).

.NOTES
    Script Name  : Invoke-DriverUnitTests.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : Any (no elevation required)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-10-28

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
#Requires -Version 5.1

param(
    [string]$OutputFile = 'C:\Temp\FixReport\Unit\DriverUnitTests.xml'
)

Import-Module Pester -ErrorAction Stop
$pesterVersion = (Get-Module Pester).Version

$outDir = Split-Path -Parent $OutputFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

Write-Output ''
Write-Output '-- Invoke-DriverUnitTests '.PadRight(64, '-')
Write-Output "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Pester $pesterVersion   PS $($PSVersionTable.PSVersion)"
Write-Output ('-' * 64)

if ($pesterVersion.Major -ge 5) {
    $cfg = New-PesterConfiguration
    $cfg.Run.Path            = $PSScriptRoot
    $cfg.Run.PassThru        = $true
    $cfg.TestResult.Enabled  = $true
    $cfg.TestResult.OutputPath   = $OutputFile
    $cfg.TestResult.OutputFormat = 'NUnitXml'
    $cfg.Output.Verbosity    = 'Detailed'
    $result = Invoke-Pester -Configuration $cfg
} else {
    $result = Invoke-Pester -Script $PSScriptRoot -PassThru -OutputFile $OutputFile -OutputFormat NUnitXml
}

Write-Output ''
Write-Output ('-' * 64)
Write-Output "  Passed: $($result.PassedCount)  |  Failed: $($result.FailedCount)  |  Skipped: $($result.SkippedCount)  |  Results: $OutputFile"
Write-Output ('-' * 64)
Write-Output ''

exit [int]$result.FailedCount
