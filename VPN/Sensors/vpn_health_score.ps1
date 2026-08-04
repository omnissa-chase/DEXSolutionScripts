#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_health_score
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-03
    Timeout      : < 5 seconds
    Requires     : Invoke-VpnStateCollection.ps1 scheduled every 15-30 minutes

    Composite VPN health, 0-100. Higher is healthier.
    -1 means no VPN client is present on the device (not the same as unhealthy).
#>

try {
    $cached = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\VPN" `
                  -Name "HealthScore" -ErrorAction SilentlyContinue

    if ($null -eq $cached -or [string]::IsNullOrEmpty($cached.HealthScore)) {
        Write-Output -1
        return
    }

    Write-Output ([int]$cached.HealthScore)
    return
}
catch {
    Write-Output -1
    return
}
