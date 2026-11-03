#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_preshell_gap_ms
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDurationMultiSession.ps1 2.1+ (DeployMode RunNow or DeployScheduledTask)

    Time from the last Winlogon Logon-notification subscriber finishing to explorer.exe
    starting. This is userinit's work: network provider notification (mpnotify),
    the user-object logon script, drive mappings, then launching the shell. Nothing in
    the default Windows logs brackets it, so it is reported as the gap it is.

    On domain-joined devices, Group Policy events 5017 (account lookup), 5326 (DC
    discovery) and 5311 (LDAP bind) usually explain a large value here.

    Negative values are sentinels, not measurements:
      -1  Unknown -- collector has not run, or shell-ready / subscriber times were unavailable
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "PreShellGapDurationSec" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.PreShellGapDurationSec
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
