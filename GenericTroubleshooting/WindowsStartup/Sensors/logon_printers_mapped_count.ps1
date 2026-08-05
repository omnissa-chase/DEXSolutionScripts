#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_printers_mapped_count
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDuration.ps1 (DeployMode RunNow or DeployScheduledTask)
    Requires     : PrintService/Operational event log enabled

    Number of network printer connections established at logon (PrintService EID 300).

    Pair with logon_printer_mapping_duration_ms: many printers mapping quickly is fine,
    few printers mapping slowly points at an unreachable or overloaded print server.

    Negative values are sentinels, not measurements:
      -1  Unknown -- collector has not run, or the count could not be determined
      -2  Not applicable -- the feature is not present on this device
      -3  Log disabled -- PrintService/Operational is off; run DeployMode ConfigureLogging
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "PrintersMappedCount" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.PrintersMappedCount
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output -1; return }
    if ($raw -eq 'LogDisabled')             { Write-Output -3; return }
    if ($raw -eq 'N/A')                     { Write-Output -2; return }
    if ($raw -eq 'Unknown')                 { Write-Output -1; return }

    $value = 0
    if (-not [int]::TryParse($raw, [ref]$value)) { Write-Output -1; return }

    Write-Output $value
    return
}
catch {
    Write-Output -1
    return
}
