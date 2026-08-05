#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_task_count
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDuration.ps1 (DeployMode RunNow or DeployScheduledTask)
    Requires     : TaskScheduler/Operational event log enabled

    Number of scheduled tasks that started within five minutes of logon (EID 100).

    A high count is a direct, actionable finding: these are tasks an administrator
    chose to schedule, and they can be rescheduled away from the logon window.

    Negative values are sentinels, not measurements:
      -1  Unknown -- collector has not run, or the count could not be determined
      -2  Not applicable -- the feature is not present on this device
      -3  Log disabled -- TaskScheduler/Operational is off; run DeployMode ConfigureLogging
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "LogonTaskCount" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.LogonTaskCount
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
