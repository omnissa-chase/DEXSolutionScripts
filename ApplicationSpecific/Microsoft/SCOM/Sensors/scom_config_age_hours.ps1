#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_config_age_hours
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-21
    Timeout      : < 2 seconds
    Requires     : Invoke-AutoRemediateSCOMAgent.ps1 (scheduled, writes the cache this reads)

    Hours since the agent's connector configuration cache was last written, as at the
    last sweep. A healthy agent rewrites this whenever the management server sends it
    new configuration; a number that keeps climbing means the agent is running on a
    stale copy of what it is supposed to monitor -- alerting on yesterday's rules,
    silent about anything added since.

    -1 means not measured -- no agent, or the cache file was absent. Not "fresh".

    Two cautions before acting on a high value:
      - Age alone is not corruption. A stable management group that has not changed a
        management pack in a week will legitimately show a week-old cache. That is why
        Invoke-AutoRemediateSCOMHealthServiceCache.ps1 refuses to act on age by
        itself and requires a corroborating signal (ESENT store errors or an
        oversized state folder).
      - This value is only as fresh as the sweep. It advances in sweep-sized steps,
        not continuously, so read it against the sweep schedule rather than as a
        live clock.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\SCOM" `
                -Name "ConfigAgeHours" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.ConfigAgeHours
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output -1; return }

    # The sweep writes this with one decimal place ("412.7"). [int]::TryParse rejects
    # a decimal point outright, so parse as a double and round instead -- an int parse
    # here reported -1 for every device whose value was not a whole number, which on
    # this metric is nearly all of them.
    $value = 0.0
    $style = [System.Globalization.NumberStyles]::Float
    if (-not [double]::TryParse($raw, $style, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value) -and
        -not [double]::TryParse($raw, $style, [System.Globalization.CultureInfo]::CurrentCulture, [ref]$value)) {
        Write-Output -1
        return
    }

    Write-Output ([int][math]::Round($value))
    return
}
catch {
    Write-Output -1
    return
}
