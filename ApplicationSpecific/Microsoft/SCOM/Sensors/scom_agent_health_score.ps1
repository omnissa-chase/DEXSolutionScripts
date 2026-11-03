#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_agent_health_score
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-21
    Timeout      : < 2 seconds
    Requires     : Invoke-AutoRemediateSCOMAgent.ps1 (scheduled, writes the cache this reads)

    Composite Operations Manager agent health, 0-100. Computed once by the sweep
    script so every SCOM sensor agrees on a single value rather than each one
    re-deriving its own.

    -1 covers two conditions, both meaning "no score was obtained": no agent installed on
    this device, or the sweep is incomplete because Part 1 or Part 2 has not run inside
    26 hours (Part 3 publishes -1 / IncompleteSweep rather than a partial score, since
    missing metrics cannot deduct and a partial score is always too high). Read
    scom_agent_health_reason alongside this to tell them apart.

    -1 is not a low score. It means no score exists for this device, which is a
    different fact entirely -- collapsing the two would make fleet reporting
    meaningless, because a machine that was never meant to be monitored would drag
    the average down alongside genuinely broken agents. Filter on -1 first, then
    trend the rest.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\SCOM" `
                -Name "HealthScore" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.HealthScore
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
