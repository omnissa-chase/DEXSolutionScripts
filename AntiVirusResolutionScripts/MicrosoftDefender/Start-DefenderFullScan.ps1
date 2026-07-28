# ScriptName: Defender_FullScan_1.0.3.1
# Context: System
# 
#
$SCRIPT_VERSION = "1.0.3.1"
# Enable WhatIfPreference to $true if you want to test this sample
$WhatIfPreference=$false

$RunEventId = ([Random]::new()).Next(1000,9999)
$MaxFullScanHours = 12
Write-Host "[$RunEventId] Executing script, $SCRIPT_VERSION.  Started @ '$((Get-Date).ToString("yyyy-MM-dd hh:mm:ss"))'"
$HEAD="`r`n[$RunEventId]"

if ($PSVersionTable.PSVersion.Major -ge 7) {
    Import-Module -Name ConfigDefender -SkipEditionCheck -ErrorAction Stop
}

$defendermonitor = Get-ScheduledTask -TaskPath "\WorkspaceOneEx\Defender\" -TaskName FullScanDetection -ErrorAction SilentlyContinue
if(($defendermonitor | Measure).Count -eq 0){
    Write-Host "$HEAD Defender monitoring task not detected.  Manually detecting for existing scan..."

    $healthDetectionPath="HKLM:\SOFTWARE\AIRWATCH\Extensions\HealthDetection"
    If(-not (Test-Path $healthDetectionPath)) { New-Item -Path $healthDetectionPath -Force | Out-Null } 

    $fullScanRunning=$false
    # Attempt to gather from the 
    $startEvt = Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 100 |
        Where-Object { $_.Id -eq 1000 -and $_.Message -match 'Scan Parameters:\s*Full scan' } |
        Select-Object -First 1

    $endEvt = Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 100 |
        Where-Object { $_.Id -eq 1001 -and $_.Message -match 'Scan Parameters:\s*Full scan' } |
        Select-Object -First 1
    
    if(-not ($startEvt)){
        $stats = (Get-MpComputerStatus)
        $startEvt = $stats.FullScanStartTime
        $endEvt = $stats.FullScanEndTime
    }


    if($startEvt){
        if(-not $endEvt){
            $fullScanRunning = $true
        }elseif($startEvt.TimeCreated -lt $endEvt.TimeCreated){
            $fullScanRunning = $false
        }elseif($startEvt.TimeCreated -ge $endEvt.TimeCreated){
            $fullScanRunning = $true
        }
    }
    
}Else{
    Write-Host "$HEAD Defender monitoring task detected.  Checking registry entry..."
    $currentDetectedStatus=Get-ItemProperty -Path $healthDetectionPath -ErrorAction SilentlyContinue | Select-Object -Property FullScanInProgress -ExpandProperty FullScanInProgress -ErrorAction SilentlyContinue
    $fullScanRunning = ($currentDetectedStatus -eq 1)
}

If($fullScanRunning){
    Write-Host "$HEAD Full scan is already running. Exiting..."
    Exit 0
}


# Start Full Defender scan
$Scan=$null
Try{
    Write-Host "$HEAD Starting Defender scan (Full Scan)."
    If(-not $WhatIfPreference){
        $Scan=Start-MpScan -ScanType FullScan -AsJob
    } Else { 
        Write-Host "`r`nWhat if: Performing the operation 'Start-MpScan' on target 'HOST' with option 'ScanType=FullScan', as new job" 
    }
}Catch{
    Write-Host "$HEAD An error has occured running Full Scan: $($_.Exception.Message)"
    Exit 1
}
Exit 0