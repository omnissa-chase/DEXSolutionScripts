<#
.SYNOPSIS
    Invoke-DefenderPauseScan -- Cancels any active Microsoft Defender antivirus scan.

.DESCRIPTION
    Locates the highest available version of MpCmdRun.exe from the Defender platform
    directory and issues a scan cancel command. Safe to run while no scan is in progress.

    The cancel command stops quick and full scans only. A custom scan (a folder or file
    scan) keeps running, and Defender reports "No on-going quick or full scan found."
    in that case, the same line it prints when nothing is running. The script prints a
    WARNING block whenever that line appears.

.NOTES
    Script Name  : Invoke-DefenderPauseScan.ps1
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-16

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$possiblePaths = @(
    "$env:ProgramFiles\Windows Defender\MpCmdRun.exe",
    "$env:ProgramData\Microsoft\Windows Defender\Platform\*\MpCmdRun.exe"
)

$mpCmdRun = Get-Item $possiblePaths -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending |
    Select-Object -First 1

if (-not $mpCmdRun) {
    throw "MpCmdRun.exe was not found."
}

$output = & $mpCmdRun.FullName -Scan -Cancel 2>&1 | ForEach-Object { "$_" }
$output

# The tool prints this same line when nothing is running and when a custom scan is running.
if ($output -match 'No on-going quick or full scan found') {
    Write-Output ''
    Write-Output '======================== WARNING ========================'
    Write-Output 'WARNING: No scan was cancelled.'
    Write-Output 'WARNING: This command stops quick and full scans only.'
    Write-Output 'WARNING: A custom scan (a folder or file scan) is NOT supported.'
    Write-Output 'WARNING: If a custom scan is running, it is STILL RUNNING.'
    Write-Output '========================================================='
}