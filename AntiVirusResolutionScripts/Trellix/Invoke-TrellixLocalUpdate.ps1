<#
.SYNOPSIS
    Forces a local content update for Trellix (formerly McAfee) Endpoint Security, then triggers a policy refresh.

    .NOTES
    Name: Invoke-TrellixLocalUpdate
    Version: 1.0.0.0
    Context: System
    Timeout: 30 seconds 
    User impact: None 
    Trigger: On-Demand - designed to be used in conjunction with freestyle

.DISCLAIMER
    This script has only been tested in lab environments and will need to be thoroughly 
    tested in production environments before deployment.

    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$amcfgPaths = @(
    "$env:ProgramFiles\McAfee\Endpoint Security\Threat Prevention\amcfg.exe",
    "${env:ProgramFiles(x86)}\McAfee\Endpoint Security\Threat Prevention\amcfg.exe",
    "$env:ProgramFiles\Trellix\Endpoint Security\Threat Prevention\amcfg.exe",
    "${env:ProgramFiles(x86)}\Trellix\Endpoint Security\Threat Prevention\amcfg.exe"
)

$cmdAgentPaths = @(
    "$env:ProgramFiles\McAfee\Agent\CmdAgent.exe",
    "${env:ProgramFiles(x86)}\McAfee\Agent\CmdAgent.exe",
    "$env:ProgramFiles\McAfee\Common Framework\CmdAgent.exe",
    "${env:ProgramFiles(x86)}\McAfee\Common Framework\CmdAgent.exe",
    "$env:ProgramFiles\Trellix\Agent\CmdAgent.exe",
    "${env:ProgramFiles(x86)}\Trellix\Agent\CmdAgent.exe"
)

$amcfg = $amcfgPaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
$cmdAgent = $cmdAgentPaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if ($amcfg) {
    Write-Output "Running Trellix ENS content update..."
    & $amcfg /update
}
else {
    Write-Output "amcfg.exe not found. Skipping ENS content update."
}

if ($cmdAgent) {
    Write-Output "Running Trellix Agent policy refresh..."
    foreach ($switch in @("/p", "/c", "/e", "/f")) {
        Write-Output "Running CmdAgent.exe $switch"
        & $cmdAgent $switch
        Start-Sleep -Seconds 10
    }
}
else {
    Write-Output "CmdAgent.exe not found. Skipping policy refresh."
}