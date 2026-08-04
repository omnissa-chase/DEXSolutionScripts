#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_flap_count_24h
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-04
    Timeout      : < 5 seconds
    Requires     : Invoke-VpnStateCollection.ps1 scheduled every 15-30 minutes

    Tunnel disconnect events in the last 24 hours. -1 means unknown.

    This is the sensor that finds the users nobody files a ticket about. A tunnel
    that drops and silently re-establishes twenty times a day is connected whenever
    anyone checks, yet every drop tears down in-flight sessions.

    Sourced from the NetworkProfile operational log rather than RasClient, so it
    covers third-party clients and not just the Windows built-in VPN stack.
#>

try {
    $cached = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\VPN" `
                  -Name "FlapCount24h" -ErrorAction SilentlyContinue

    if ($null -eq $cached -or [string]::IsNullOrEmpty($cached.FlapCount24h)) {
        Write-Output -1
        return
    }

    Write-Output ([int]$cached.FlapCount24h)
    return
}
catch {
    Write-Output -1
    return
}
