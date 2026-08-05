#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_gp_duration_ms
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDuration.ps1 (DeployMode RunNow or DeployScheduledTask)

    Total Group Policy user processing time (GP EID 4001 -> EID 8001).

    Usually the single largest contributor to a slow logon on a domain-joined fleet,
    and the one most often fixed by policy consolidation rather than hardware.

    Negative values are sentinels, not measurements:
      -1  Unknown -- collector has not run, or the phase could not be measured
      -2  Not applicable -- the feature is not present on this device
      -3  Log disabled -- required event log is off; run DeployMode ConfigureLogging
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "GPDurationSec" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.GPDurationSec
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output -1; return }
    if ($raw -eq 'LogDisabled')             { Write-Output -3; return }
    if ($raw -eq 'N/A')                     { Write-Output -2; return }
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
