#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_management_group_count_standalone
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-25
    Timeout      : < 2 seconds
    Requires     : nothing -- measures the device directly, no cache, no sweep script

    Number of management groups this agent is assigned to. There is no cached twin --
    the sweep records ManagementGroupCount but exposes it only through the health
    score -- so this is new here rather than a replacement.

    Read it as three distinct populations, not as a magnitude:

      0   Agent installed but unassigned. It is running and monitoring nothing. This
          is the 20-point NoManagementGroup deduction, and on an endpoint fleet it is
          usually a Log Analytics / Azure Monitor install of the same binary rather
          than a broken SCOM agent -- cross-reference scom_agent_version_standalone
          before raising it with the SCOM team.
      1   Normal.
      2+  Multi-homed. Legitimate, and deliberately only a 5-point deduction, but
          each management group runs its own full workflow set: doubled CPU, memory,
          and state-folder growth for the same monitoring. Worth confirming on a
          laptop or a shared VDI host, where the user pays for it directly.

    -1 means not measured -- no agent, or the registry was not readable. It is not 0,
    and the difference matters: 0 is a finding, -1 is an absence of data.

    A group counted here has a key, which is not the same as having a parent
    management server assigned. An agent that was configured but never approved shows
    1 here and still cannot report. That distinction needs the sweep or the run-once
    sensor (OneTimeSensor/scom_agent_health.ps1), which walk the Parent Health
    Services subkeys.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $agentRoot = $null
    foreach ($candidate in @('HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0',
                             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft Operations Manager\3.0')) {
        if (Test-Path $candidate -ErrorAction SilentlyContinue) { $agentRoot = $candidate; break }
    }
    if (-not $agentRoot) { Write-Output -1; return }

    $mgRoot = Join-Path $agentRoot 'Agent Management Groups'
    if (-not (Test-Path $mgRoot -ErrorAction SilentlyContinue)) { Write-Output 0; return }

    # @() is required: exactly one management group is the normal case, and
    # (pipeline).Count on a single object is empty in PowerShell 5.1.
    Write-Output (@(Get-ChildItem -Path $mgRoot -ErrorAction SilentlyContinue).Count)
    return
}
catch {
    Write-Output -1
    return
}
