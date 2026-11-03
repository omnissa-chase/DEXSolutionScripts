#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : hzn_agent_health_score
    Data Type    : Integer
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 2 seconds
    Requires     : Invoke-HorizonAgentStateCollection.ps1 scheduled every 15-30 minutes

    Composite Horizon Agent health, 0-100. -1 means no agent installed, the collector has
    not run, or the last collection failed; read hzn_agent_health_reason alongside it
    (NotInstalled vs CollectionError). Deduction table: VDI/Horizon/SPEC.md section 5.1.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $p = Get-ItemProperty -Path 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Agent' -Name 'HealthScore' -ErrorAction SilentlyContinue
    if ($null -eq $p) { Write-Output -1; return }
    $raw = [string]$p.HealthScore
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output -1; return }
    # Parsed as double then rounded: collectors may write decimals, and [int]::TryParse rejects them.
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
