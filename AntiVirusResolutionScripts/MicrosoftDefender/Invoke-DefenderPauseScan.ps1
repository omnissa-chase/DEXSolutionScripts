<#
.SYNOPSIS
    Invoke-DefenderPauseScan -- Cancels any active Microsoft Defender antivirus scan.

.DESCRIPTION
    Locates the highest available version of MpCmdRun.exe from the Defender platform
    directory and issues a scan cancel command. Safe to run while no scan is in progress.

.NOTES
    Script Name  : Invoke-DefenderPauseScan.ps1
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-20

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

& $mpCmdRun.FullName -Scan -Cancel