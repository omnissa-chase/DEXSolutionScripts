#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_agent_version_standalone
    Data Type    : String
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-25
    Timeout      : < 2 seconds
    Requires     : nothing -- measures the device directly, no cache, no sweep script

    Standalone twin of scom_agent_version. Same value, read straight from the agent's
    own registry instead of from the sweep cache, so it works on a fleet where
    Invoke-AutoRemediateSCOMAgentPart1/2/3.ps1 are not deployed. Deploy one or the
    other, not both -- two sensors reporting the same attribute under different names
    doubles the sensor queue for one number.

    Four-part file version of the installed agent binary, e.g. "10.19.10552.0".
    Empty string means no agent installed or the version could not be read -- not
    distinguishable here, because a String sensor has no second sentinel. Use
    scom_agent_health_reason_standalone (NoAgentInstalled) to tell those apart.

    Read order is CurrentVersion, then ProductVersion (some builds expose only the
    latter), then the FileVersion of HealthService.exe. The binary is the last resort
    rather than the first: it reports the version of the file on disk, which after a
    failed or partial upgrade is not necessarily the version that is registered.

    Returned as a String, not a version type, so UEM records it verbatim. String
    comparison does NOT order versions correctly -- "10.19.10552.0" sorts below
    "10.19.1082.0" lexically. Group by exact value to find the outliers rather than
    filtering on greater-than.

    Rough mapping: 8.x = SCOM 2012 R2, 10.19.x = 2019, 10.22.x = 2022, 10.23.x = 2025.
    The Microsoft Monitoring Agent binary is also the Log Analytics agent, so a device
    can carry a version here while reporting to Azure Monitor rather than to a SCOM
    management group -- cross-reference scom_management_group_count_standalone before
    treating a version-only device as an unhealthy SCOM agent.

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
    if (-not $agentRoot) { Write-Output ""; return }

    $setup   = Get-ItemProperty -Path (Join-Path $agentRoot 'Setup') -ErrorAction SilentlyContinue
    $version = ''

    if ($setup) {
        if     ($setup.CurrentVersion) { $version = [string]$setup.CurrentVersion }
        elseif ($setup.ProductVersion) { $version = [string]$setup.ProductVersion }

        if ([string]::IsNullOrWhiteSpace($version) -and $setup.InstallDirectory) {
            $exe = Join-Path ([string]$setup.InstallDirectory) 'HealthService.exe'
            if (Test-Path -LiteralPath $exe -ErrorAction SilentlyContinue) {
                $version = [string](Get-Item -LiteralPath $exe -ErrorAction SilentlyContinue).VersionInfo.FileVersion
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($version)) { Write-Output ""; return }

    Write-Output $version
    return
}
catch {
    Write-Output ""
    return
}
