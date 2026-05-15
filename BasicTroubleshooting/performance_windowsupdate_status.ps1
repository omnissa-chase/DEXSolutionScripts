try {
    $status = 'Idle'

    # -----------------------------
    # Windows Update - Downloading
    # -----------------------------
    $wuDownloading = $false
    try {
        $bitsJobs = Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Where-Object {
            $_.JobState -in @('Connecting', 'Transferring')
        }

        $wuProcesses = Get-Process -Name 'MoUsoCoreWorker','usoclient','wuauclt' -ErrorAction SilentlyContinue

        if ($bitsJobs -or $wuProcesses) {
            $wuDownloading = $true
        }
    }
    catch {}

    # -----------------------------
    # Windows Update - Installing
    # -----------------------------
    $wuInstalling = $false
    try {
        $installProcesses = Get-Process -Name 'TiWorker','TrustedInstaller' -ErrorAction SilentlyContinue

        if ($installProcesses) {
            $wuInstalling = $true
        }
    }
    catch {}

    # -----------------------------
    # Defender - Scanning / Updating
    # -----------------------------
    $defenderScanning = $false
    $defenderUpdating = $false

    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop

        if ($mp.QuickScanRunning -or $mp.FullScanRunning) {
            $defenderScanning = $true
        }

        $defenderUpdateProcesses = Get-Process -Name 'MpCmdRun','MpSigStub' -ErrorAction SilentlyContinue
        if ($defenderUpdateProcesses) {
            $defenderUpdating = $true
        }
    }
    catch {
        # Fallback if Get-MpComputerStatus is unavailable
        try {
            $defenderUpdateProcesses = Get-Process -Name 'MpCmdRun','MpSigStub' -ErrorAction SilentlyContinue
            if ($defenderUpdateProcesses) {
                $defenderUpdating = $true
            }
        }
        catch {}
    }

    # -----------------------------
    # Final status precedence
    # -----------------------------
    if ($defenderScanning) {
        $status = 'Scanning'
    }
    elseif ($wuInstalling -or $defenderUpdating) {
        $status = 'Updating'
    }
    elseif ($wuDownloading) {
        $status = 'Downloading'
    }
    else {
        $status = 'Idle'
    }

    Write-Host $status
}
catch {
    Write-Host 'Idle'
}