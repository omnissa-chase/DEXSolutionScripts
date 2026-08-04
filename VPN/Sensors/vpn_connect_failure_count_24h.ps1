#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_connect_failure_count_24h
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-04
    Timeout      : < 5 seconds
    Requires     : Invoke-VpnStateCollection.ps1 scheduled every 15-30 minutes

    Failed VPN connection attempts in the last 24 hours. -1 means unknown.

    Counted from RasClient event 20227, which only the Windows built-in RAS stack
    writes. Third-party clients log failures in vendor-specific locations, so 0 on
    a device running a third-party client means "none observed", not "none
    occurred". Treat this as a floor, and pair it with vpn_flap_count_24h, which
    is vendor-agnostic.
#>

try {
    $cached = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\VPN" `
                  -Name "ConnectFailureCount24h" -ErrorAction SilentlyContinue

    if ($null -eq $cached -or [string]::IsNullOrEmpty($cached.ConnectFailureCount24h)) {
        Write-Output -1
        return
    }

    Write-Output ([int]$cached.ConnectFailureCount24h)
    return
}
catch {
    Write-Output -1
    return
}
