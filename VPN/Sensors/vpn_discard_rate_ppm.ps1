#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_discard_rate_ppm
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-04
    Timeout      : < 5 seconds
    Requires     : Invoke-VpnStateCollection.ps1 scheduled every 15-30 minutes

    Discarded packets per million on the active tunnel adapter. -1 means no active
    tunnel or no statistics available.

    Read from cache so it agrees with the deduction applied by vpn_health_score.

    Parts per million is used because tunnel discard rates are small enough that a
    whole-number percentage rounds every real problem to 0. A healthy tunnel sits
    near 0; sustained values above roughly 1000 ppm (0.1%) indicate an MTU mismatch,
    a saturated link, or an unstable path.

    The underlying counters are cumulative since adapter initialisation, so this is
    a lifetime average, not an instantaneous rate. On a long-lived tunnel it lags
    behind a problem that started recently.
#>

try {
    $cached = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\VPN" `
                  -Name "DiscardRatePpm" -ErrorAction SilentlyContinue

    if ($null -eq $cached -or [string]::IsNullOrEmpty($cached.DiscardRatePpm)) {
        Write-Output -1
        return
    }

    Write-Output ([int]$cached.DiscardRatePpm)
    return
}
catch {
    Write-Output -1
    return
}
