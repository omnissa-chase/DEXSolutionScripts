<#
.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    $status = 'Idle'

    $defenderScanning = $false
    $defenderUpdating = $false

    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop

        if ($mp.QuickScanRunning -or $mp.FullScanRunning) {
            $defenderScanning = $true
        }

        $updateProcesses = Get-Process -Name 'MpCmdRun','MpSigStub' -ErrorAction SilentlyContinue
        if ($updateProcesses) {
            $defenderUpdating = $true
        }
    }
    catch {
        # Fallback if Defender module is unavailable
        try {
            $updateProcesses = Get-Process -Name 'MpCmdRun','MpSigStub' -ErrorAction SilentlyContinue
            if ($updateProcesses) {
                $defenderUpdating = $true
            }
        }
        catch {}
    }

    # Final status precedence
    if ($defenderScanning) {
        $status = 'Scanning'
    }
    elseif ($defenderUpdating) {
        $status = 'Updating'
    }
    else {
        $status = 'Idle'
    }

    Write-Host $status
}
catch {
    Write-Host 'Idle'
}
``