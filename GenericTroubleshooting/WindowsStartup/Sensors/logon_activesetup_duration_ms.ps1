#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_activesetup_duration_ms
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDuration.ps1 (DeployMode RunNow or DeployScheduledTask)

    ActiveSetup duration (Shell-Core EID 62170 -> EID 62171): per-user COM component
    registration run at logon.

    Typically near zero, and typically only significant on a user's first logon after
    an application deployment. A fleet showing this consistently high is running
    ActiveSetup work it should have completed once.

    Negative values are sentinels, not measurements:
      -1  Unknown -- collector has not run, or the phase could not be measured
      -2  Not applicable -- no ActiveSetup work ran for this user
      -3  Log disabled -- required event log is off; run DeployMode ConfigureLogging
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "ActiveSetupDurationSec" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.ActiveSetupDurationSec
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
