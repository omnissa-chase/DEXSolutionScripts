#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : hzn_client_health_reason
    Data Type    : String
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 2 seconds
    Requires     : Invoke-HorizonClientStateCollection.ps1 scheduled every 30-60 minutes

    The single largest deduction from hzn_client_health_score. One of: Healthy,
    NotInstalled, ServerUnresolvable, ServerUnreachable443, BlastPortUnreachable,
    RepeatedConnectFailures, NoServerKnown, UsbServiceStopped, ClientOutdated,
    CertCheckDisabled, VpnDegraded, CollectionError (VDI/Horizon/SPEC.md 5.2).
    No suffixes on this sensor.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $p = Get-ItemProperty -Path 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Client' -Name 'HealthReason' -ErrorAction SilentlyContinue
    if ($null -eq $p -or [string]::IsNullOrEmpty($p.HealthReason)) { Write-Output ''; return }
    Write-Output ([string]$p.HealthReason)
    return
}
catch {
    Write-Output ''
    return
}
