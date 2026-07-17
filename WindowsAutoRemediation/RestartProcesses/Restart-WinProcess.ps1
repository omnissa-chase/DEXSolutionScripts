<#
.NOTES
    Script Name  : Restart-WinProcess.ps1
    Data Type    : String 
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-10
    Timeout      : 30 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$FileDescription=$env:FileDescription,
    [bool]$StartService=$env:StartService
)

$proc = Get-Process -ErrorAction SilentlyContinue | Where Description -like "*FileDescription*"

if ($proc) {
    Write-Host "Stopping process '$ProcessName' (PID: $($proc.Id))..."
    Stop-Process -Name $ProcessName -Force
    Start-Sleep -Seconds 5
    if($StartService){
        Write-Host "Starting process '$ProcessName'..."
        Start-Process $ProcessName
    }
} else {
    Write-Host "Process '$ProcessName' not currently running."
}

