#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : disk_reclaimable_safe_mb
    Data Type    : Integer
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Timeout      : < 5 seconds
    Requires     : Invoke-DiskStateCollection.ps1 scheduled once a day

    MB that Start-DiskCleanupSafe.ps1 would free right now under its own rules (old temp
    files, error reports, update download leftovers, old servicing logs). -1 means
    unknown: the collector has not run on this device.

    This is the playbook's trigger for the safe cleanup: run the script when the value is
    above the threshold the admin chooses. It is not free space, which DEX already
    collects; it is how much of the used space is safely recoverable. The cleanup script
    refreshes the value when it finishes, so the result shows without waiting for the
    next collection.
#>

try {
    $cached = Get-ItemProperty -Path 'HKLM:\Software\AirWatch\Extensions\DiskState' -Name 'ReclaimableSafeMb' -ErrorAction SilentlyContinue
    if ($null -eq $cached -or [string]::IsNullOrEmpty("$($cached.ReclaimableSafeMb)")) {
        Write-Output -1
        return
    }
    Write-Output ([int]$cached.ReclaimableSafeMb)
    return
}
catch {
    Write-Output -1
    return
}
