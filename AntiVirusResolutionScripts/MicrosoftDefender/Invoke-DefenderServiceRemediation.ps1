<#
.SYNOPSIS
    Invoke-DefenderServiceRemediation -- Ensures Microsoft Defender services are running and Real-Time Protection is enabled.

.DESCRIPTION
    Sets the core Defender services (MDCoreSvc, WinDefend, WdNisSvc, mpssvc) to Automatic
    startup and starts any that are not running. Also re-enables Real-Time Protection if it
    has been disabled. Safe to run on a healthy device -- exits cleanly if everything is
    already in the correct state.

.NOTES
    Script Name  : Invoke-DefenderServiceRemediation.ps1
    Version      : 1.6.1.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-20
    Timeout      : 30 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>


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