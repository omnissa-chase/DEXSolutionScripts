#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_winlogon_subscriber_detail
    Data Type    : String
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDurationMultiSession.ps1 2.1+ (DeployMode RunNow or DeployScheduledTask)

    Every Winlogon notification subscriber that ran for the Logon notification, with
    its time in seconds, slowest first:

        Profiles=0.3;TermSrv=0.1;Sens=0.05;GPClient=0.01

    Built-in names: Profiles (user profile load), GPClient (Group Policy hand-off),
    TermSrv, Sens, SessionEnv. Anything else is a third-party product registered under
    HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\Notify or as a Winlogon
    notification package, and is the usual answer to "what is the rest of the logon".

    Returns "" when the collector has not run or the phase was not measurable.
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "WinlogonSubscriberDetail" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output ""; return }

    $raw = [string]$prop.WinlogonSubscriberDetail
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output ""; return }
    if ($raw -in @('Unknown', 'N/A', 'LogDisabled', 'Ambiguous')) { Write-Output ""; return }

    Write-Output $raw
    return
}
catch {
    Write-Output ""
    return
}
