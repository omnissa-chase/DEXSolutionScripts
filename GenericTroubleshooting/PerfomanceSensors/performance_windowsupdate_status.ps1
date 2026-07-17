<#
.NOTES
    Script Name  : performance_windowsupdate_status.ps1
    Data Type    : String 
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-10

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

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