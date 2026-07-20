<#
.NOTES
    Script Name  : Restart-WinService.ps1
    Data Type    : String 
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-10
    Timeout      : 15 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

param([string]$ServiceName=$env:ServiceName)
$SCRIPT_VERSION="1.6.1.0"

$WhatIfPreference=$false

$RunEventId = ([Random]::new()).Next(1000,9999)
Write-Host "[$RunEventId] Executing script, $SCRIPT_VERSION.  Started @ '$((Get-Date).ToString("yyyy-MM-dd hh:mm:ss"))'"
$HEAD="`r`n[$RunEventId]"

$services = @("wuauserv")

ForEach ($service in $services) {
    $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
    If ($svc) {
        If ($svc.Status -ne 'Running') {
            #Set-Service -Name $service -StartupType Automatic -ErrorAction Continue
            Start-Service -Name $service -ErrorAction Continue
            Write-Output "$HEAD $service has been started."
        } Else {
            Write-Output "$HEAD $service is already running."
        }
    } Else {
        Write-Warning "$HEAD $service not found on this system."
    }
}
Exit 0