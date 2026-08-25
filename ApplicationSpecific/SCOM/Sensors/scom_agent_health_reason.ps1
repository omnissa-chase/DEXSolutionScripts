#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_agent_health_reason
    Data Type    : String
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-21
    Timeout      : < 2 seconds
    Requires     : Invoke-AutoRemediateSCOMAgent.ps1 (scheduled, writes the cache this reads)

    The single largest deduction from scom_agent_health_score -- the one thing to fix
    first, not a list of everything wrong. Pair the two: the score tells you how bad,
    this tells you what.

    Values, highest deduction first:
      HealthServiceStopped (40), ManagementServerUnreachable (25),
      AgentNotRegistered (25), NoManagementGroup (20),
      ConnectorAuthenticationFailure (20), HealthServiceStoreCorruption (20),
      ConfigurationCacheStale (15), AgentRuntimeFootprintHigh (15),
      ChannelCertificateProblem (15), TimeSkew (15), WorkflowsUnloaded (10),
      HealthServiceStateOversized (10), MultiHomedAgent (5),
      IntermittentConnectivity (5), Healthy, NoAgentInstalled, IncompleteSweep.

    NoAgentInstalled is not a fault -- it is the sweep confirming this device was
    never in scope. Exclude it before ranking anything.

    IncompleteSweep is not a fault either, and not a health finding: it means Part 1 or
    Part 2 of the sweep has not run inside 26 hours, so Part 3 refused to publish a score
    computed from a fraction of the metrics. It is a scheduling problem -- check
    Part1RunTime / Part2RunTime, or the ScoreComplete DWORD. The agent may be perfectly
    healthy.

    Several of these are management-group problems the device merely observes.
    ManagementServerUnreachable, AgentNotRegistered, ConnectorAuthenticationFailure
    and ChannelCertificateProblem appearing across many devices at once is a server-
    side or PKI incident; no agent-side script will clear it.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\SCOM" `
                -Name "HealthReason" -ErrorAction SilentlyContinue

    if ($null -eq $prop -or [string]::IsNullOrWhiteSpace([string]$prop.HealthReason)) {
        Write-Output ""
        return
    }

    Write-Output ([string]$prop.HealthReason)
    return
}
catch {
    Write-Output ""
    return
}
