try {
    $status = 'Idle'

    # Check if Windows Update is installing
    $wuInstalling = $false
    try {
        $installProcesses = Get-Process -Name 'TiWorker','TrustedInstaller' -ErrorAction SilentlyContinue
        if ($installProcesses) {
            $wuInstalling = $true
        }
    }
    catch {}

    # Check if Windows Update is downloading
    $wuDownloading = $false
    try {
        $bitsJobs = Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Where-Object {
            $_.JobState -in @('Connecting','Transferring')
        }

        $wuProcesses = Get-Process -Name 'MoUsoCoreWorker','usoclient','wuauclt' -ErrorAction SilentlyContinue

        if ($bitsJobs -or $wuProcesses) {
            $wuDownloading = $true
        }
    }
    catch {}

    # Final status precedence
    if ($wuInstalling) {
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