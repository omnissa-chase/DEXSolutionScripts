<#
.SYNOPSIS
    Remediates Trellix (formerly McAfee) services by setting their CPU priority to BelowNormal.

    .NOTES
    Name: Invoke-TrellixCPUPriority
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

$trellixProcesses = @(
    "mcshield",
    "mfemms",
    "mfevtps",
    "macmnsvc",
    "masvc",
    "mfeesp",
    "mfeann",
    "mfehcs",
    "mfetp"
)

foreach ($name in $trellixProcesses) {
    Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $_.PriorityClass = "BelowNormal"

            [pscustomobject]@{
                ProcessName = $_.ProcessName
                PID         = $_.Id
                Priority    = $_.PriorityClass
                Result      = "Priority changed to BelowNormal"
            }
        }
        catch {
            [pscustomobject]@{
                ProcessName = $_.ProcessName
                PID         = $_.Id
                Priority    = $null
                Result      = "Failed: $($_.Exception.Message)"
            }
        }
    }
}
