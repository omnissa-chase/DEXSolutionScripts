#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_config_age_hours_standalone
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-25
    Timeout      : < 2 seconds
    Requires     : nothing -- measures the device directly, no cache, no sweep script

    Standalone twin of scom_config_age_hours. Deploy one or the other, not both.

    Hours since the agent's connector configuration cache was last written, measured
    live at sample time rather than as at the last sweep. A healthy agent rewrites
    this whenever the management server sends it new configuration; a number that
    keeps climbing means the agent is running on a stale copy of what it is supposed
    to monitor -- alerting on yesterday's rules, silent about anything added since.

    Because this reads the file directly, the value is continuous rather than
    advancing in sweep-sized steps. That is the one respect in which it is strictly
    better than the cached sensor, and the reason it is worth deploying even where
    the sweep scripts are in place -- though not alongside them, see above.

    -1 means not measured -- no agent, or the cache file was absent. Not "fresh".

    Rounded to whole hours. The sweep records one decimal place; a device will
    therefore show at most a one-hour difference between the two sensors, which is
    well inside the 24h staleness threshold either reads against.

    Age alone is not corruption. A stable management group that has not changed a
    management pack in a week will legitimately show a week-old cache. That is why
    Invoke-AutoRemediateSCOMHealthServiceCache.ps1 refuses to act on age by itself
    and requires a corroborating signal (ESENT store errors or an oversized state
    folder) -- neither of which this sensor can see.

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

    $setup = Get-ItemProperty -Path (Join-Path $agentRoot 'Setup') -ErrorAction SilentlyContinue
    if (-not $setup -or -not $setup.InstallDirectory) { Write-Output -1; return }

    $configDir = Join-Path ([string]$setup.InstallDirectory) 'Health Service State\Connector Configuration Cache'
    if (-not (Test-Path -LiteralPath $configDir -ErrorAction SilentlyContinue)) { Write-Output -1; return }

    # One file per management group, each in its own subfolder. Newest wins: on a
    # multi-homed agent the freshest configuration is the one worth reporting, and
    # the stale-group case is scom_management_group_count_standalone's problem.
    $config = Get-ChildItem -Path $configDir -Filter 'OpsMgrConnector.Config.xml' -Recurse -File -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $config) { Write-Output -1; return }

    Write-Output ([int][math]::Round(((Get-Date) - $config.LastWriteTime).TotalHours))
    return
}
catch {
    Write-Output -1
    return
}
