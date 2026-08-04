#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_last_connect_time
    Data Type    : Date Time
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-04
    Timeout      : < 5 seconds
    Requires     : Invoke-VpnStateCollection.ps1 scheduled every 15-30 minutes

    Timestamp of the most recent tunnel connect within the last 24 hours, sourced
    from the NetworkProfile operational log by the collection script.

    No value is emitted when the tunnel has not connected in the collection window.
    There is no safe sentinel date, so a missing sample is the honest answer.
#>

try {
    $cached = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\VPN" `
                  -Name "LastConnectTime" -ErrorAction SilentlyContinue

    if ($null -eq $cached -or [string]::IsNullOrEmpty($cached.LastConnectTime)) {
        return
    }

    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($cached.LastConnectTime, [ref]$parsed)) {
        return
    }

    # ISO format is required for date-time sensors.
    Write-Output ($parsed.ToString('s'))
    return
}
catch {
    return
}
