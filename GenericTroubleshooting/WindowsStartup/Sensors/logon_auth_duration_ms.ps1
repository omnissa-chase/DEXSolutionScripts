#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_auth_duration_ms
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDurationMultiSession.ps1 2.1+ (DeployMode RunNow or DeployScheduledTask)

    Authentication time (Winlogon/Operational EID 1 -> EID 2): credential provider,
    LSA / Kerberos, domain controller reachability. Happens before the session's logon
    event, so it is not inside TotalLogonDurationSec; a slow value here with a normal
    total means the delay is before the desktop even starts to build.

    Negative values are sentinels, not measurements:
      -1  Unknown -- collector has not run, or the phase could not be measured
      -2  Not applicable -- the Winlogon Operational log is absent on this build
      -3  Log disabled -- the Winlogon Operational log is switched off
      -4  Ambiguous -- concurrent logons; the events carry no user field to attribute by
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "AuthenticationDurationSec" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.AuthenticationDurationSec
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
