#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : disk_crashdump_mb
    Data Type    : Integer
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Timeout      : < 5 seconds
    Requires     : Invoke-DiskStateCollection.ps1 scheduled once a day

    MB held by crash dumps: the full memory dump, minidumps, live kernel reports and
    application dumps. -1 means unknown: the collector has not run on this device.

    This is the playbook's trigger for Clear-CrashDumps.ps1: dumps are worth keeping
    until they are large, so run the script when the value is above the threshold the
    admin chooses (a full memory dump is as large as the device's RAM). The script
    refreshes the value when it finishes; what remains is the few newest minidumps it
    keeps on purpose.
#>

try {
    $cached = Get-ItemProperty -Path 'HKLM:\Software\AirWatch\Extensions\DiskState' -Name 'CrashDumpMb' -ErrorAction SilentlyContinue
    if ($null -eq $cached -or [string]::IsNullOrEmpty("$($cached.CrashDumpMb)")) {
        Write-Output -1
        return
    }
    Write-Output ([int]$cached.CrashDumpMb)
    return
}
catch {
    Write-Output -1
    return
}
