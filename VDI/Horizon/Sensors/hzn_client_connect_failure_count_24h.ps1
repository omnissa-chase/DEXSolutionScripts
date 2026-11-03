#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : hzn_client_connect_failure_count_24h
    Data Type    : Integer
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 2 seconds
    Requires     : Invoke-HorizonClientStateCollection.ps1 scheduled every 30-60 minutes

    Connection failures in the console user's Horizon Client log over the last 24 h, as
    at the last collection. -1 when the log could not be read (no console user, no log
    file, parse error; the collector's LogParseResult says which). The failure line
    patterns are a KB resolution point (VDI/Horizon/SPEC.md KB-HZN-16): a count of 0
    on a client that is visibly failing means the pattern needs the internal answer,
    not that the client is healthy.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $p = Get-ItemProperty -Path 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Client' -Name 'ConnectFailureCount24h' -ErrorAction SilentlyContinue
    if ($null -eq $p) { Write-Output -1; return }
    $raw = [string]$p.ConnectFailureCount24h
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output -1; return }
    $v = 0.0; $st = [System.Globalization.NumberStyles]::Float
    if (-not [double]::TryParse($raw, $st, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v) -and
        -not [double]::TryParse($raw, $st, [System.Globalization.CultureInfo]::CurrentCulture, [ref]$v)) { Write-Output -1; return }
    Write-Output ([int][math]::Round($v))
    return
}
catch {
    Write-Output -1
    return
}
