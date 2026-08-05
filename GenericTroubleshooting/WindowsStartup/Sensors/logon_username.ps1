#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_username
    Data Type    : String
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDuration.ps1 (DeployMode RunNow or DeployScheduledTask)

    The DOMAIN\User whose logon the recorded timings belong to.

    Present so the timing sensors can be attributed. On a shared or multi-session
    device this tells you which session the numbers describe; without it, a slow
    logon on a kiosk is unattributable.

    Returns "" when the collector has not run.
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "Username" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output ""; return }

    $raw = [string]$prop.Username
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output ""; return }
    if ($raw -eq 'Unknown')                 { Write-Output ""; return }

    Write-Output $raw
    return
}
catch {
    Write-Output ""
    return
}
