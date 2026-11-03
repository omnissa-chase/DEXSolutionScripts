#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_desktop_ready_ms
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDurationMultiSession.ps1 2.1+ (DeployMode RunNow or DeployScheduledTask)

    Logon to the moment explorer finished launching the last Run / RunOnce command
    (Shell-Core EID 9708). Where logon_total_duration_ms stops when the desktop first
    appears, this one stops when the desktop has stopped loading things -- which is
    what users mean when they say logon is slow.

    Windows deliberately defers Run-key processing after the shell starts, so this is
    normally tens of seconds larger than the total even on a healthy device. Compare
    devices to each other, not to the total.

    Negative values are sentinels, not measurements:
      -1  Unknown -- collector has not run, or the phase could not be measured
      -2  Not applicable -- the Shell-Core Operational log is absent on this build
      -3  Log disabled -- the Shell-Core Operational log is switched off
      -4  Ambiguous -- events exist but could not be attributed to this session
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "DesktopReadyDurationSec" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.DesktopReadyDurationSec
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
