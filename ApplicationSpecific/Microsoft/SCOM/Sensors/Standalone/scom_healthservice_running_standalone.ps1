#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_healthservice_running_standalone
    Data Type    : Boolean
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-25
    Timeout      : < 2 seconds
    Requires     : nothing -- measures the device directly, no cache, no sweep script

    True when the agent is actually monitoring: HealthService is Running AND its
    start type is Automatic. This is the same test the sweep caches as ServiceRunning
    and the same 40-point deduction behind HealthServiceStopped, so the two datasets
    line up. There is no cached twin of this sensor -- the sweep exposes the fact only
    through the health score -- so it is new here rather than a replacement.

    Start type is part of the test on purpose. A HealthService that is Running but set
    to Manual or Disabled is monitoring right now and will be silently gone after the
    next reboot. Reporting that as True would hide the more useful finding.

    NO VALUE (no sample recorded) means the question does not apply: no service and no
    Operations Manager registry root, i.e. no agent on this device. Any boolean would
    be a lie there -- False reads as a real negative finding. Use
    scom_agent_health_reason_standalone (NoAgentInstalled) to count agentless devices.

    False with the agent present is the one case worth alerting on, and it is what the
    device looks like when it is grey in the Operations console. It is also the case
    Invoke-AutoRemediateSCOMAgentPart1.ps1 repairs automatically -- so a fleet running
    the sweep should rarely show False for two consecutive samples, and a device that
    does has a start failure the sweep could not fix.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $svc = Get-Service -Name 'HealthService' -ErrorAction SilentlyContinue

    if (-not $svc) {
        $agentRoot = $null
        foreach ($candidate in @('HKLM:\SOFTWARE\Microsoft\Microsoft Operations Manager\3.0',
                                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft Operations Manager\3.0')) {
            if (Test-Path $candidate -ErrorAction SilentlyContinue) { $agentRoot = $candidate; break }
        }

        # Registry root but no service: partially installed or partially removed.
        # That is a real False. No root either: no agent, so no safe boolean.
        if ($agentRoot) { Write-Output $false; return }
        return
    }

    if ($svc.Status -ne 'Running') { Write-Output $false; return }

    $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='HealthService'" -ErrorAction SilentlyContinue
    if ($cim -and ($cim.StartMode -eq 'Disabled' -or $cim.StartMode -eq 'Manual')) {
        Write-Output $false
        return
    }

    Write-Output $true
    return
}
catch {
    return
}
