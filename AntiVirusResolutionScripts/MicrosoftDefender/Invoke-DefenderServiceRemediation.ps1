# Name: Defender_ServiceRemediation_1.6.1.0
# Context: System
# Timeout: 30 seconds 
# User impact: None 
# Trigger: On-Demand - designed to be used in conjunction with freestyle


$SCRIPT_VERSION="1.6.1.0"

$WhatIfPreference=$false

$RunEventId = ([Random]::new()).Next(1000,9999)
Write-Host "[$RunEventId] Executing script, $SCRIPT_VERSION.  Started @ '$((Get-Date).ToString("yyyy-MM-dd hh:mm:ss"))'"
$HEAD="`r`n[$RunEventId]"

If($PSVersionTable.PSVersion.Major -ge 7){
    # Added PowerShell 7 support
    Import-Module -Name ConfigDefender -SkipEditionCheck
}

# Enable Windows Defender services
$services = @(
    "MDCoreSvc",       #Windows Defender Core Service
    "WinDefend",       # Windows Defender Antivirus Service
    "WdNisSvc",          # Windows Defender Network Inspection Service
    "mpssvc"       # Windows Defender Firewall
    #"Sense"        # Windows Defender Advanced Threat Protection
)

ForEach ($service in $services) {
    $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
    If ($svc) {
        If ($svc.Status -ne 'Running') {
            Set-Service -Name $service -StartupType Automatic -ErrorAction Continue
            Start-Service -Name $service -ErrorAction Continue
            Write-Output "$HEAD $service has been started and set to Automatic."
        } Else {
            Write-Output "$HEAD $service is already running."
        }
    } Else {
        Write-Warning "$HEAD $service not found on this system."
    }
}


# Enable Real-Time Protection
$CurrentRtStatus=(Get-MpComputerStatus).RealTimeProtectionEnabled
If($CurrentRtStatus){
    Write-Output "$HEAD Real Time Protection is already enabled."
}Else{
    If(!$WhatIfPreference){
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Continue
        Write-Output "$HEAD Real Time Protection enabled.  Status is $((Get-MpComputerStatus).RealTimeProtectionEnabled)."
    }
}

Exit 0