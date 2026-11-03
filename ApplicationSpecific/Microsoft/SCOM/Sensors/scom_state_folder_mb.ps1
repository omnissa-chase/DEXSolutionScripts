#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : scom_state_folder_mb
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-21
    Timeout      : < 2 seconds
    Requires     : Invoke-AutoRemediateSCOMAgent.ps1 (scheduled, writes the cache this reads)

    Size in MB of the agent's "Health Service State" folder at the last sweep. Cached
    rather than measured here on purpose: walking that tree is far too slow for a
    recurring sensor, which is why the sweep sizes it with Scripting.FileSystemObject
    once and every sensor reads the answer.

    -1 means not measured -- no agent, or the folder could not be read. Not zero, and
    not small. Exclude it before ranking devices by size.

    This is the primary targeting metric for
    Invoke-AutoRemediateSCOMHealthServiceCache.ps1. Sort descending, take the top of
    the fleet, and deploy the flush to those devices only -- never fleet-wide, because
    every flushed agent re-downloads its full configuration and enough of them at once
    is a synchronised load spike on the management group and its database.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\SCOM" `
                -Name "StateFolderMB" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output -1; return }

    $raw = [string]$prop.StateFolderMB
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output -1; return }

    # The sweep writes this with one decimal place ("412.7"). [int]::TryParse rejects
    # a decimal point outright, so parse as a double and round instead -- an int parse
    # here reported -1 for every device whose value was not a whole number, which on
    # this metric is nearly all of them.
    $value = 0.0
    $style = [System.Globalization.NumberStyles]::Float
    if (-not [double]::TryParse($raw, $style, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value) -and
        -not [double]::TryParse($raw, $style, [System.Globalization.CultureInfo]::CurrentCulture, [ref]$value)) {
        Write-Output -1
        return
    }

    Write-Output ([int][math]::Round($value))
    return
}
catch {
    Write-Output -1
    return
}
