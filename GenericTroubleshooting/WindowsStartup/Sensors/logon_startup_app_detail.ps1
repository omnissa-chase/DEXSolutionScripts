#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_startup_app_detail
    Data Type    : String
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : < 5 seconds
    Requires     : Measure-LogonDurationMultiSession.ps1 2.1+ (DeployMode RunNow or DeployScheduledTask)

    The five slowest Run / RunOnce commands explorer launched after the desktop
    appeared, with launch time in seconds, slowest first:

        OneDrive.exe=5.13;SecurityHealthSystray.exe=1.43;vmtoolsd.exe=1

    Names are the executable from the Run value; arguments and paths are dropped.
    This is the per-app answer to "what is still loading after I see my desktop".

    Returns "" when the collector has not run or the phase was not measurable.
#>

try {
    $prop = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration" `
                -Name "StartupAppDetail" -ErrorAction SilentlyContinue

    if ($null -eq $prop) { Write-Output ""; return }

    $raw = [string]$prop.StartupAppDetail
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Output ""; return }
    if ($raw -in @('Unknown', 'N/A', 'LogDisabled', 'Ambiguous')) { Write-Output ""; return }

    Write-Output $raw
    return
}
catch {
    Write-Output ""
    return
}
