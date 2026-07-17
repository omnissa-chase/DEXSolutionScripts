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