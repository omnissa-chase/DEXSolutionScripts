#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_startup_app_count
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDurationMultiSession.ps1 2.1+ (DeployMode RunNow or DeployScheduledTask)

    Number of Run / RunOnce commands explorer launched after the desktop appeared
    (Shell-Core EID 9707 -> 9708 pairs for this user's logon).

    Negative values are sentinels, not measurements:
      -1  Unknown -- collector has not run, or the phase could not be measured
      -2  Not applicable -- the Shell-Core Operational log is absent on this build
      -3  Log disabled -- the Shell-Core Operational log is switched off
      -4  Ambiguous -- events exist but could not be attributed to this session
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "StartupAppCount" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.StartupAppCount
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output -1; return }
    if ($raw -eq 'LogDisabled')             { Write-Output -3; return }
    if ($raw -eq 'N/A')                     { Write-Output -2; return }
    if ($raw -eq 'Ambiguous')               { Write-Output -4; return }
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
