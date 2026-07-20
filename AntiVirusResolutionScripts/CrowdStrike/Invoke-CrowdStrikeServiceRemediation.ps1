<#
.SYNOPSIS
    Remediates CrowdStrike services by ensuring they are running and that real-time protection is enabled.

    .DESCRIPTION
    Note: I would not normally force CrowdStrike services to Automatic/start unless your security team confirms it is supported 
    for your environment. Falcon is tamper-protected and cloud-managed, so service remediation may fail or be blocked by design
    This script attempts to remediate CrowdStrike services by ensuring they are running and set to Automatic startup.

.NOTES
    Name: Invoke-CrowdStrikeServiceRemediation
    Version: 1.0.0.0
    Context: System
    Timeout: 30 seconds 
    User impact: None 
    Trigger: On-Demand - designed to be used in conjunction with freestyle

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$SCRIPT_VERSION="1.0.0.0"

$WhatIfPreference=$false

$RunEventId = ([Random]::new()).Next(1000,9999)
Write-Host "[$RunEventId] Executing script, $SCRIPT_VERSION.  Started @ '$((Get-Date).ToString("yyyy-MM-dd hh:mm:ss"))'"
$HEAD="`r`n[$RunEventId]"

# Enable Windows Defender services
$services = @(
    "ntrtscan",      # Trend Micro Security Agent Real-time Scan
    "tmlisten",      # Trend Micro listener/service framework
    "ofcservice",    # OfficeScan / Apex One service
    "TmCCSF",        # Trend Micro Common Client Solution Framework
    "TmWSCSvc",      # Trend Micro WSC service
    "TmPfw"          # Trend Micro Firewall service, if installed/enabled
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

Exit 0

