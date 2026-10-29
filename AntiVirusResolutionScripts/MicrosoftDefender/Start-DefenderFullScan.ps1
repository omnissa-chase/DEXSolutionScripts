# ScriptName: Defender_FullScan_1.0.3.2
# Context: System
#
# 1.0.3.2 (2026-10-28): $healthDetectionPath was only assigned in the "no monitoring task"
# branch, so the task-present branch read a $null path and FullScanInProgress=1 never
# suppressed a scan. The Get-MpComputerStatus fallback stored DateTime values but compared
# .TimeCreated on them, which is $null, so a finished scan was reported as running.
# Start-MpScan now uses -ErrorAction Stop so the catch block is reachable. 24-hour timestamp.
$SCRIPT_VERSION = "1.0.3.2"
# Enable WhatIfPreference to $true if you want to test this sample
$WhatIfPreference=$false

$RunEventId = ([Random]::new()).Next(1000,9999)
Write-Output "[$RunEventId] Executing script, $SCRIPT_VERSION.  Started @ '$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))'"
$HEAD="`r`n[$RunEventId]"

if ($PSVersionTable.PSVersion.Major -ge 7) {
    Import-Module -Name ConfigDefender -SkipEditionCheck -ErrorAction Stop
}

$healthDetectionPath="HKLM:\SOFTWARE\AIRWATCH\Extensions\HealthDetection"
If(-not (Test-Path $healthDetectionPath)) { New-Item -Path $healthDetectionPath -Force | Out-Null }

$defendermonitor = Get-ScheduledTask -TaskPath "\WorkspaceOneEx\Defender\" -TaskName FullScanDetection -ErrorAction SilentlyContinue
if(@($defendermonitor).Count -eq 0){
    Write-Output "$HEAD Defender monitoring task not detected.  Manually detecting for existing scan..."

    $fullScanRunning=$false

    # Newest full-scan start (1000) and finish (1001) events. Normalise both to [DateTime]
    # so the comparison below works whether the value came from an event or from
    # Get-MpComputerStatus.
    $startEvt = Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 100 -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -eq 1000 -and $_.Message -match 'Scan Parameters:\s*Full scan' } |
        Select-Object -First 1

    $endEvt = Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 100 -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -eq 1001 -and $_.Message -match 'Scan Parameters:\s*Full scan' } |
        Select-Object -First 1

    $startTime = $null
    $endTime   = $null
    if($startEvt){
        $startTime = $startEvt.TimeCreated
        if($endEvt){ $endTime = $endEvt.TimeCreated }
    } else {
        $stats = (Get-MpComputerStatus)
        $startTime = $stats.FullScanStartTime
        $endTime   = $stats.FullScanEndTime
    }

    if($startTime){
        if(-not $endTime){
            $fullScanRunning = $true
        }elseif($startTime -ge $endTime){
            $fullScanRunning = $true
        }
    }

}Else{
    Write-Output "$HEAD Defender monitoring task detected.  Checking registry entry..."
    $currentDetectedStatus=Get-ItemProperty -Path $healthDetectionPath -ErrorAction SilentlyContinue | Select-Object -Property FullScanInProgress -ExpandProperty FullScanInProgress -ErrorAction SilentlyContinue
    $fullScanRunning = ($currentDetectedStatus -eq 1)
}

If($fullScanRunning){
    Write-Output "$HEAD Full scan is already running. Exiting..."
    Exit 0
}


# Start Full Defender scan
$Scan=$null
Try{
    Write-Output "$HEAD Starting Defender scan (Full Scan)."
    If(-not $WhatIfPreference){
        $Scan=Start-MpScan -ScanType FullScan -AsJob -ErrorAction Stop
    } Else { 
        Write-Output "`r`nWhat if: Performing the operation 'Start-MpScan' on target 'HOST' with option 'ScanType=FullScan', as new job" 
    }
}Catch{
    Write-Output "$HEAD An error has occured running Full Scan: $($_.Exception.Message)"
    Exit 1
}
Exit 0