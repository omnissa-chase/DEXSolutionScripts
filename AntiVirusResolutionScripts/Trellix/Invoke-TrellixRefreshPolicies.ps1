<#
.SYNOPSIS
    Forces a policy refresh for Trellix (formerly McAfee) Endpoint Security.

    .NOTES
    Name: Invoke-TrellixRefreshPolicies
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

function Get-TrellixCmdAgentPath {
    $paths = @(
        "$env:ProgramFiles\McAfee\Agent\CmdAgent.exe",
        "${env:ProgramFiles(x86)}\McAfee\Agent\CmdAgent.exe",
        "$env:ProgramFiles\McAfee\Common Framework\CmdAgent.exe",
        "${env:ProgramFiles(x86)}\McAfee\Common Framework\CmdAgent.exe",
        "$env:ProgramFiles\Trellix\Agent\CmdAgent.exe",
        "${env:ProgramFiles(x86)}\Trellix\Agent\CmdAgent.exe"
    )

    foreach ($path in $paths) {
        if ($path -and (Test-Path $path)) {
            return $path
        }
    }

    return $null
}

function Invoke-TrellixPolicyRefresh {
    $cmdAgent = Get-TrellixCmdAgentPath

    if (-not $cmdAgent) {
        throw "CmdAgent.exe was not found."
    }

    $steps = @(
        "/p", # Collect and send properties
        "/c", # Check for new policies
        "/e", # Enforce policies locally
        "/f"  # Forward events
    )

    foreach ($step in $steps) {
        Write-Host "Running CmdAgent.exe $step"
        Start-Process -FilePath $cmdAgent -ArgumentList $step -Wait -WindowStyle Hidden
        Start-Sleep -Seconds 10
    }
}

Invoke-TrellixPolicyRefresh