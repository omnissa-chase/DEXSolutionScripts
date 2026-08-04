#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_health_reason
    Data Type    : String
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-03
    Timeout      : < 5 seconds
    Requires     : Invoke-VpnStateCollection.ps1 scheduled every 15-30 minutes

    The single largest deduction from vpn_health_score. One of:
    Healthy, NoVpnClient, TunnelDown, MtuNotReducedForTunnel, MtuBelowMinimum,
    NoDnsOnTunnel, HighPacketDiscardRate, FrequentReconnects,
    IntermittentReconnects, RepeatedConnectFailures, MultipleVpnClients,
    CollectionError.
#>

try {
    $cached = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\VPN" `
                  -Name "HealthReason" -ErrorAction SilentlyContinue

    if ($null -eq $cached -or [string]::IsNullOrEmpty($cached.HealthReason)) {
        Write-Output ""
        return
    }

    Write-Output $cached.HealthReason
    return
}
catch {
    Write-Output ""
    return
}
