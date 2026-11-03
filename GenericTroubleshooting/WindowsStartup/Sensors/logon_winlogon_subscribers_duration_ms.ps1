#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_winlogon_subscribers_duration_ms
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDurationMultiSession.ps1 2.1+ (DeployMode RunNow or DeployScheduledTask)

    Total time spent in Winlogon notification subscribers for the Logon notification
    (Winlogon/Operational EID 811 -> 812, summed across subscribers). This is where
    profile load, the Group Policy client hand-off, Terminal Services, SENS, and every
    third-party agent that registers with Winlogon (antivirus, VPN, VDI and SSO
    products) run, one after another, before userinit starts.

    This is the largest named slice of what older collectors left as "other". Pair
    with logon_slowest_winlogon_subscriber to see which one, and
    logon_winlogon_subscriber_detail for the full list.

    Negative values are sentinels, not measurements:
      -1  Unknown -- collector has not run, or the phase could not be measured
      -2  Not applicable -- the Winlogon Operational log is absent on this build
      -3  Log disabled -- the Winlogon Operational log is switched off
      -4  Ambiguous -- events exist but could not be attributed to this session
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "WinlogonSubscribersDurationSec" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.WinlogonSubscribersDurationSec
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output -1; return }
    if ($raw -eq 'LogDisabled')             { Write-Output -3; return }
    if ($raw -eq 'N/A')                     { Write-Output -2; return }
    if ($raw -eq 'Ambiguous')               { Write-Output -4; return }
    if ($raw -eq 'Unknown')                 { Write-Output -1; return }

    $value = 0.0
    $ok = [double]::TryParse(($raw -replace ',', '.'),
              [Globalization.NumberStyles]::Float,
              [Globalization.CultureInfo]::InvariantCulture, [ref]$value)
    if (-not $ok) { Write-Output -1; return }

    Write-Output ([int][math]::Round($value * 1000))
    return
}
catch {
    Write-Output -1
    return
}
