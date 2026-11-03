#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_slowest_winlogon_subscriber
    Data Type    : String
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDurationMultiSession.ps1 2.1+ (DeployMode RunNow or DeployScheduledTask)

    Name of the Winlogon notification subscriber that took the longest during the
    Logon notification (e.g. "Profiles", "GPClient", or a third-party agent's name).

    A string sensor so Workspace ONE Intelligence can group devices by it: a fleet
    where the slowest subscriber is the same vendor agent everywhere is a vendor
    problem, not a profile problem.

    Returns "" when the collector has not run or the phase was not measurable.
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "SlowestWinlogonSubscriber" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output ""; return }

    $raw = [string]$prop.SlowestWinlogonSubscriber
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output ""; return }
    if ($raw -in @('Unknown', 'N/A', 'LogDisabled', 'Ambiguous')) { Write-Output ""; return }

    Write-Output $raw
    return
}
catch {
    Write-Output ""
    return
}
