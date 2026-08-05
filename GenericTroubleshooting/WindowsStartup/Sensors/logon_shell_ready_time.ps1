#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_shell_ready_time
    Data Type    : Date Time
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDuration.ps1 (DeployMode RunNow or DeployScheduledTask)

    Local time the user's shell became ready (Winlogon EID 7001). This is the end
    point for TotalLogonDurationSec -- the moment the desktop was usable.

    Date Time sensors have no safe sentinel value, so this returns nothing at all
    when unavailable.
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "ShellReadyTime" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { return }

    $raw = [string]$prop.ShellReadyTime
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    if ($raw -eq 'Unknown' -or $raw -eq 'N/A' -or $raw -eq 'LogDisabled') { return }

    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($raw, 'yyyy-MM-dd HH:mm:ss',
              [Globalization.CultureInfo]::InvariantCulture,
              [Globalization.DateTimeStyles]::None, [ref]$parsed)

    if (-not $ok) {
        $ok = [datetime]::TryParse($raw, [ref]$parsed)
    }
    if (-not $ok) { return }

    Write-Output $parsed.ToString('s')
    return
}
catch {
    return
}
