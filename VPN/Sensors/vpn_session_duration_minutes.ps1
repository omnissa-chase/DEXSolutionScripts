#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_session_duration_minutes
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-04
    Timeout      : < 5 seconds
    Requires     : Invoke-VpnStateCollection.ps1 scheduled every 15-30 minutes

    Minutes elapsed since the current tunnel connected. -1 means no active tunnel,
    or a connect event that predates the collection window.

    Pairs with vpn_flap_count_24h: a fleet whose sessions are consistently short
    is reconnecting, even when each individual reconnect looks successful.

    The value is as stale as the last collection run, so it under-reports by up to
    one collection interval. Treat it as a floor on true session age.
#>

try {
    $cached = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\VPN" `
                  -Name "SessionDurationMinutes" -ErrorAction SilentlyContinue

    if ($null -eq $cached -or [string]::IsNullOrEmpty($cached.SessionDurationMinutes)) {
        Write-Output -1
        return
    }

    Write-Output ([int]$cached.SessionDurationMinutes)
    return
}
catch {
    Write-Output -1
    return
}
