#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_data_collected_at
    Data Type    : Date Time
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDuration.ps1 (DeployMode RunNow or DeployScheduledTask)

    Local time the collector last wrote its results.

    This is the freshness sensor: every other value in this set is a cached reading,
    and without this one you cannot tell a fast logon from a stale record. Alert on
    this being old before you trust anything else in the group.

    Date Time sensors have no safe sentinel value, so this returns nothing at all
    when the collector has never run.
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "DataCollectedAt" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { return }

    $raw = [string]$prop.DataCollectedAt
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
