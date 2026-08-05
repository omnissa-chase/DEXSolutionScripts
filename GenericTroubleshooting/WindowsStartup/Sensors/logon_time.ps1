#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_time
    Data Type    : Date Time
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDuration.ps1 (DeployMode RunNow or DeployScheduledTask)

    Local time the session logon began (Security EID 4624 / TerminalServices EID 21).
    This is the start point for TotalLogonDurationSec.

    Date Time sensors have no safe sentinel value -- any number we invent would be
    charted as a real date -- so this returns nothing at all when unavailable.
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "LogonTime" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { return }

    $raw = [string]$prop.LogonTime
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    if ($raw -eq 'Unknown' -or $raw -eq 'N/A' -or $raw -eq 'LogDisabled') { return }

    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($raw, 'yyyy-MM-dd HH:mm:ss',
              [Globalization.CultureInfo]::InvariantCulture,
              [Globalization.DateTimeStyles]::None, [ref]$parsed)

    # Fallback covers rows written by an earlier, culture-dependent collector build.
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
