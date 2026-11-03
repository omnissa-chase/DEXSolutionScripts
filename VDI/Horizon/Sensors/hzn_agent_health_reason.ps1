#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : hzn_agent_health_reason
    Data Type    : String
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 2 seconds
    Requires     : Invoke-HorizonAgentStateCollection.ps1 scheduled every 15-30 minutes

    The single largest deduction from hzn_agent_health_score. One of: Healthy,
    NotInstalled, AgentServiceStopped, NotPaired, BrokerUnresolvable, BrokerUnreachable,
    BlastServiceStopped, HighPacketLoss, HighRtt, BlastTcpFallback, FirewallRulesDisabled,
    NoBrokerKnown, AgentErrorsElevated, StaleDisconnectedSessions, FeatureServiceStopped,
    TimeSyncStale, CollectionError (VDI/Horizon/SPEC.md 5.1).

    Suffix ';ImageFault' means the collector found this reason already present on its
    first run after the machine booted (FaultPresentAtBoot = 1): the fault came with the
    image or provisioning, not with anything that happened in a session. On a
    non-persistent clone that is the signal to fix the parent image; remediation on the
    clone is relief only. Filter DEX on the suffix to list the whole affected pool.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $p = Get-ItemProperty -Path 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Agent' -ErrorAction SilentlyContinue
    if ($null -eq $p -or [string]::IsNullOrEmpty($p.HealthReason)) { Write-Output ''; return }
    $reason = [string]$p.HealthReason
    $atBoot = 0
    if ($null -ne $p.FaultPresentAtBoot) { try { $atBoot = [int]$p.FaultPresentAtBoot } catch { $atBoot = 0 } }
    if ($atBoot -eq 1 -and $reason -ne 'Healthy') { $reason = "$reason;ImageFault" }
    Write-Output $reason
    return
}
catch {
    Write-Output ''
    return
}
