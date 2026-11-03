#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_management_server_reachable
    Data Type    : Boolean
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-21
    Timeout      : < 2 seconds
    Requires     : Invoke-AutoRemediateSCOMAgent.ps1 (scheduled, writes the cache this reads)

    Whether the agent's configured management server answered on its configured port
    (5723 by default) at the last sweep. Read from cache, never probed live -- a
    recurring sensor must not make network calls, and the cached answer is the same
    one the health score was calculated from, so the two can never disagree.

    Deliberately has no fallback value. A missing or unparseable cache means the
    sweep has not run, not that the management server is down; emitting $false there
    would manufacture a fleet-wide outage out of a scheduling problem. No sample is
    the honest answer. Same for a device with no agent installed -- "unreachable" is
    meaningless when nothing is trying to reach anything.

    False across many devices at once is a management-group or network incident, not
    a device fault. No agent-side script fixes it, and the Tier 2 HealthServiceCache
    flush is actively dangerous while it is true -- an agent that cannot reach its MS
    cannot re-download the configuration you just deleted.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $key = "HKLM:\Software\AirWatch\Extensions\SCOM"

    # AgentInstalled is checked first: on a device with no agent the sweep writes
    # that flag but never writes MsReachable at all.
    $installed = Get-ItemProperty -Path $key -Name "AgentInstalled" -ErrorAction SilentlyContinue
    if ($null -eq $installed) { return }

    $installedValue = 0
    if (-not [int]::TryParse([string]$installed.AgentInstalled, [ref]$installedValue)) { return }
    if ($installedValue -ne 1) { return }

    $prop = Get-ItemProperty -Path $key -Name "MsReachable" -ErrorAction SilentlyContinue
    if ($null -eq $prop) { return }

    $value = 0
    if (-not [int]::TryParse([string]$prop.MsReachable, [ref]$value)) { return }

    Write-Output ($value -eq 1)
    return
}
catch {
    return
}
