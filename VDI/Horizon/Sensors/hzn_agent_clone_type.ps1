#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : hzn_agent_clone_type
    Data Type    : String
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 2 seconds
    Requires     : Invoke-HorizonAgentStateCollection.ps1 scheduled every 15-30 minutes

    InstantClone, FullClone, Physical or Unknown, as at the last collection. The public
    build uses a heuristic (ClonePrep artifacts under the agent log directory mean
    InstantClone; nothing else is proven, so everything else is Unknown) until KB-HZN-10
    is settled. Drives the collector's Persistence value and the relief-only wording in
    the remediation: fixes on an InstantClone revert at the next refresh.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $p = Get-ItemProperty -Path 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Agent' -Name 'CloneType' -ErrorAction SilentlyContinue
    if ($null -eq $p -or [string]::IsNullOrEmpty($p.CloneType)) { Write-Output ''; return }
    Write-Output ([string]$p.CloneType)
    return
}
catch {
    Write-Output ''
    return
}
