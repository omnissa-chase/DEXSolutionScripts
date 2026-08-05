#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_task_total_duration_ms
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDuration.ps1 (DeployMode RunNow or DeployScheduledTask)
    Requires     : TaskScheduler/Operational event log enabled

    Span from the first scheduled task start (EID 100) to the last completion (EID 102)
    within five minutes of logon.

    This is contention, not a logon phase: these tasks run alongside the user's first
    actions and compete for the same CPU and disk. A high value here explains a device
    that reaches the desktop quickly but feels unusable for the next minute.

    Negative values are sentinels, not measurements:
      -1  Unknown -- collector has not run, or the phase could not be measured
      -2  Not applicable -- the feature is not present on this device
      -3  Log disabled -- TaskScheduler/Operational is off; run DeployMode ConfigureLogging
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "LogonTaskTotalDurationSec" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.LogonTaskTotalDurationSec
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
