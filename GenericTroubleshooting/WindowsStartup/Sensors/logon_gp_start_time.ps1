#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_gp_start_time
    Data Type    : Date Time
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-05
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDuration.ps1 (DeployMode RunNow or DeployScheduledTask)

    Local time Group Policy user processing began (GP EID 4001).

    Useful for placing GP within the logon timeline: GP starting late is a different
    problem from GP running long, and only the start time distinguishes them.

    Date Time sensors have no safe sentinel value, so this returns nothing at all
    when unavailable.
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "GPStartTime" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { return }

    $raw = [string]$prop.GPStartTime
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
