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