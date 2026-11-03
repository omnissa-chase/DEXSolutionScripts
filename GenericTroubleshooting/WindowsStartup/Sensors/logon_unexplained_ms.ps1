#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_unexplained_ms
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDurationMultiSession.ps1 2.1+ (DeployMode RunNow or DeployScheduledTask)

    The part of TotalLogonDurationSec that no measured phase covers. The collector
    clips every phase interval to the logon window (logon event to explorer.exe),
    merges the overlaps, and subtracts. This is the honest "other": phases overlap and
    several run past shell-ready, so subtracting their durations from the total was
    never valid.

    What is typically left in here: userinit and network providers (see
    logon_preshell_gap_ms), time between Winlogon notifications, and anything a
    third-party component does without writing an event.

    A fleet whose P95 of this value is small has a logon that is fully instrumented;
    chase the named phases instead. A device where it dominates is the one to trace
    with Windows Performance Recorder.

    Negative values are sentinels, not measurements:
      -1  Unknown -- collector has not run, or the total was unavailable
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "UnexplainedDurationSec" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.UnexplainedDurationSec
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output -1; return }
    if ($raw -in @('Unknown', 'N/A', 'LogDisabled', 'Ambiguous')) { Write-Output -1; return }

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
