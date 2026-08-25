#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_agent_version
    Data Type    : String
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-21
    Timeout      : < 2 seconds
    Requires     : Invoke-AutoRemediateSCOMAgent.ps1 (scheduled, writes the cache this reads)

    Four-part file version of the installed agent binary, e.g. "10.19.10552.0".
    Empty string means no agent installed or the version could not be read -- these
    are not distinguishable here by design, because a String sensor has no second
    sentinel. Use scom_agent_health_reason (NoAgentInstalled) or
    scom_agent_health_score (-1) to tell those apart.

    Returned as a String, not a version type, so UEM records it verbatim. String
    comparison does NOT order versions correctly -- "10.19.10552.0" sorts below
    "10.19.1082.0" lexically. Group by exact value to find the outliers rather than
    filtering on greater-than.

    Rough mapping: 8.x = SCOM 2012 R2, 10.19.x = 2019, 10.22.x = 2022, 10.23.x = 2025.
    The Microsoft Monitoring Agent binary is also the Log Analytics agent, so a device
    can carry a version here while reporting to Azure Monitor rather than to a SCOM
    management group -- cross-reference scom_agent_health_reason before treating a
    version-only device as an unhealthy SCOM agent.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\SCOM" `
                -Name "AgentVersion" -ErrorAction SilentlyContinue

    if ($null -eq $prop -or [string]::IsNullOrWhiteSpace([string]$prop.AgentVersion)) {
        Write-Output ""
        return
    }

    Write-Output ([string]$prop.AgentVersion)
    return
}
catch {
    Write-Output ""
    return
}
