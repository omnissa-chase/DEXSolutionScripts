<#
.SYNOPSIS
    Remediates CrowdStrike Falcon sensor services by ensuring they are running and set to Automatic startup.

.DESCRIPTION
    Note: I would not normally force CrowdStrike services to Automatic/start unless your security team confirms it is supported
    for your environment. Falcon is tamper-protected and cloud-managed, so service remediation may fail or be blocked by design.
    This script attempts to remediate CrowdStrike services by ensuring they are running and set to Automatic startup.
    Exits 1 when a Falcon service is present but could not be brought to Running, so the caller can see the failure.

.NOTES
    Name: Invoke-CrowdStrikeServiceRemediation
    Version: 1.0.1.0
    Last Modified: 2026-10-28 (1.0.1.0: service list was a copy of the Trend Micro list and never touched Falcon; now
                   targets CSFalconService. Exit code reflects the post-remediation state. 24-hour timestamp.)
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

$SCRIPT_VERSION="1.0.1.0"

$RunEventId = ([Random]::new()).Next(1000,9999)
Write-Output "[$RunEventId] Executing script, $SCRIPT_VERSION.  Started @ '$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))'"
$HEAD="`r`n[$RunEventId]"

# CrowdStrike Falcon sensor services. CSFalconService is the user-mode sensor service; the
# CSAgent / CSBoot / CSDeviceControl entries are kernel drivers and are not managed here.
$services = @(
    "CSFalconService"   # CrowdStrike Falcon Sensor Service
)

$failures = 0
$found    = 0
ForEach ($service in $services) {
    $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
    If ($svc) {
        $found++
        If ($svc.Status -ne 'Running') {
            Set-Service -Name $service -StartupType Automatic -ErrorAction Continue
            Start-Service -Name $service -ErrorAction Continue
            $svc.Refresh()
            If ($svc.Status -eq 'Running') {
                Write-Output "$HEAD $service has been started and set to Automatic."
            } Else {
                $failures++
                Write-Output "$HEAD $service is still $($svc.Status) after remediation. Falcon tamper protection may be blocking the change; use a maintenance token."
            }
        } Else {
            Write-Output "$HEAD $service is already running."
        }
    } Else {
        Write-Warning "$HEAD $service not found on this system."
    }
}

If ($found -eq 0) {
    Write-Output "$HEAD No CrowdStrike Falcon services are installed on this device. Nothing to remediate."
}

If ($failures -gt 0) { Exit 1 }
Exit 0

