#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_printer_mapping_duration_ms
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDuration.ps1 (DeployMode RunNow or DeployScheduledTask)
    Requires     : PrintService/Operational event log enabled

    Time spent mapping network printers at logon (PrintService/Operational
    EID 300 -> EID 306).

    PrintService/Operational is disabled by default in Windows, so -3 is the expected
    first result on any fleet. Run Measure-LogonDuration.ps1 with $env:DeployMode set to
    ConfigureLogging (or $env:ConfigureLoggingFirst = 'true') before relying on this sensor.

    Negative values are sentinels, not measurements:
      -1  Unknown -- collector has not run, or the phase could not be measured
      -2  Not applicable -- the feature is not present on this device
      -3  Log disabled -- PrintService/Operational is off; run DeployMode ConfigureLogging
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "PrinterMappingDurationSec" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.PrinterMappingDurationSec
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
