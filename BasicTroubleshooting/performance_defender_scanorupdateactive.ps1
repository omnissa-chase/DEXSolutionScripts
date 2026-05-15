try {
    $isBusy = $false

    $mp = Get-MpComputerStatus -ErrorAction Stop

    # Scan indicators
    $scanRunning = $false
    if ($mp.QuickScanRunning -or $mp.FullScanRunning) {
        $scanRunning = $true
    }

    # Update indicators
    $updateProcesses = Get-Process -Name 'MpCmdRun','MpSigStub' -ErrorAction SilentlyContinue
    $isUpdating = $false
    if ($updateProcesses) {
        $isUpdating = $true
    }

    if ($scanRunning -or $isUpdating) {
        $isBusy = $true
    }

    Write-Output $isBusy
}
catch {
    Write-Output $false
}