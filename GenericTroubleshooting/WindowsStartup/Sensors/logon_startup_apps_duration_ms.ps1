#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_startup_apps_duration_ms
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDurationMultiSession.ps1 2.1+ (DeployMode RunNow or DeployScheduledTask)

    Time explorer spent launching Run / RunOnce commands after the desktop appeared:
    the sum of each command's Shell-Core EID 9707 -> 9708 span. Explorer launches
    them one at a time, so this is time the user spends with a desktop that is still
    "loading".

    Not part of TotalLogonDurationSec, which stops at explorer.exe start. Pair with
    logon_startup_app_detail to see which app, and logon_desktop_ready_ms for the
    logon-to-last-launch figure users actually experience.

    Negative values are sentinels, not measurements:
      -1  Unknown -- collector has not run, or the phase could not be measured
      -2  Not applicable -- the Shell-Core Operational log is absent on this build
      -3  Log disabled -- the Shell-Core Operational log is switched off
      -4  Ambiguous -- events exist but could not be attributed to this session
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "StartupAppsDurationSec" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.StartupAppsDurationSec
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
