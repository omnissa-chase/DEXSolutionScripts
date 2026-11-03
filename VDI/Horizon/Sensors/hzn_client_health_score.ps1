#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : hzn_client_health_score
    Data Type    : Integer
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 2 seconds
    Requires     : Invoke-HorizonClientStateCollection.ps1 scheduled every 30-60 minutes

    Composite Horizon Client health on this endpoint, 0-100. -1 means no client
    installed, the collector has not run, or the last collection failed; read
    hzn_client_health_reason alongside it. Deduction table: VDI/Horizon/SPEC.md 5.2.
    Most deductions are network facts (server unresolvable or unreachable, Blast port
    blocked, VPN degraded), so a low score here with a healthy desktop points at the
    endpoint or its path, not at Horizon.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $p = Get-ItemProperty -Path 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Client' -Name 'HealthScore' -ErrorAction SilentlyContinue
    if ($null -eq $p) { Write-Output -1; return }
    $raw = [string]$p.HealthScore
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
