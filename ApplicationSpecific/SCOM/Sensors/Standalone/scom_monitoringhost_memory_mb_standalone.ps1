#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_monitoringhost_memory_mb_standalone
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-25
    Timeout      : < 2 seconds
    Requires     : nothing -- measures the device directly, no cache, no sweep script

    Standalone twin of scom_monitoringhost_memory_mb. Deploy one or the other, not
    both.

    Combined working set in MB of HealthService.exe plus every MonitoringHost.exe
    child, measured live at sample time. This is the metric that matters on VDI and
    Horizon/AVD hosts, where the same agent footprint is multiplied by session count
    and shows up as host memory pressure rather than as a SCOM problem.

    -1 means not measured -- no agent process is running. It is not a low reading.
    Filter it out before averaging or the fleet number is fiction. Note the
    difference from the cached twin: there, -1 also covers "the sweep did not run".
    Here the only cause is that no agent process exists, which usually means
    HealthService is stopped -- confirm with scom_healthservice_running_standalone.

    A single high value is not a fault. Management packs legitimately spike the agent
    during discovery and on-demand tasks, and sampling live makes this sensor MORE
    likely to catch one of those spikes than the cached twin, not less. Sustained
    growth across consecutive samples on the same device is the signal, which is why
    Invoke-AutoRemediateSCOMMonitoringHost.ps1 takes two independent samples of its
    own rather than trusting one reading -- from this sensor or anywhere else.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    # @() is required: a device running HealthService with no MonitoringHost child
    # returns a single object, and (pipeline).Count on one object is empty in 5.1.
    $procs = @(Get-Process -Name 'HealthService', 'MonitoringHost' -ErrorAction SilentlyContinue)

    if ($procs.Count -eq 0) { Write-Output -1; return }

    $sum = ($procs | Measure-Object -Property WorkingSet64 -Sum).Sum
    if ($null -eq $sum) { Write-Output -1; return }

    Write-Output ([int][math]::Round($sum / 1MB))
    return
}
catch {
    Write-Output -1
    return
}
