#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_fslogix_attach_duration_ms
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDuration.ps1 (DeployMode RunNow or DeployScheduledTask)

    FSLogix profile container attach time, measured as the span of FSLogix Operational
    log activity in the window following logon.

    Returns -2 (not applicable) on any device without FSLogix installed, which is the
    expected result on a physical fleet. Only meaningful on VDI / session hosts.

    Negative values are sentinels, not measurements:
      -1  Unknown -- collector has not run, or the phase could not be measured
      -2  Not applicable -- FSLogix is not installed on this device
      -3  Log disabled -- required event log is off; run DeployMode ConfigureLogging
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "FSLogixAttachDurationSec" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.FSLogixAttachDurationSec
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
