#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_monitoringhost_memory_mb
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-21
    Timeout      : < 2 seconds
    Requires     : Invoke-AutoRemediateSCOMAgent.ps1 (scheduled, writes the cache this reads)

    Combined working set in MB of HealthService.exe plus every MonitoringHost.exe
    child, as measured at the last sweep. This is the metric that matters on VDI and
    Horizon/AVD hosts, where the same agent footprint is multiplied by session count
    and shows up as host memory pressure rather than as a SCOM problem.

    -1 means not measured -- no agent installed, or the process read failed. It is
    not a low reading. Filter it out before averaging or the fleet number is fiction.

    A single high value is not a fault. Management packs legitimately spike the agent
    during discovery and on-demand tasks. Sustained growth across consecutive samples
    on the same device is the signal, which is exactly why
    Invoke-AutoRemediateSCOMMonitoringHost.ps1 takes two independent samples of its
    own rather than trusting one reading -- from this sensor or anywhere else.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\SCOM" `
                -Name "RuntimeMemoryMB" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.RuntimeMemoryMB
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output -1; return }

    $value = 0
    if (-not [int]::TryParse($raw, [ref]$value)) { Write-Output -1; return }

    Write-Output $value
    return
}
catch {
    Write-Output -1
    return
}
