#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : disk_previous_windows_mb
    Data Type    : Integer
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Timeout      : < 5 seconds
    Requires     : Invoke-DiskStateCollection.ps1 scheduled once a day

    MB held by the previous Windows installation (Windows.old) and upgrade leftovers
    ($Windows.~BT, $Windows.~WS, $GetCurrent). 0 means there are none. -1 means unknown:
    the collector has not run on this device.

    This is the playbook's trigger for Clear-PreviousWindowsInstall.ps1. Windows removes
    these by itself after the roll-back period; a value that stays high for weeks after
    a feature update means that clean-up did not happen. The script leaves anything
    still inside the roll-back period, so a high value straight after an update is
    expected and is not cleared unless the admin sets MinAgeDays to 0.
#>

try {
    $cached = Get-ItemProperty -Path 'HKLM:\Software\AirWatch\Extensions\DiskState' -Name 'PreviousWindowsMb' -ErrorAction SilentlyContinue
    if ($null -eq $cached -or [string]::IsNullOrEmpty("$($cached.PreviousWindowsMb)")) {
        Write-Output -1
        return
    }
    Write-Output ([int]$cached.PreviousWindowsMb)
    return
}
catch {
    Write-Output -1
    return
}
