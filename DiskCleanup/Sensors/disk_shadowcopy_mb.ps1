#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : disk_shadowcopy_mb
    Data Type    : Integer
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Timeout      : < 5 seconds
    Requires     : Invoke-DiskStateCollection.ps1 scheduled once a day

    MB used by shadow copies: System Restore points and Previous Versions. 0 means
    there are none (System Restore is off on many managed devices). -1 means unknown:
    the collector has not run on this device.

    This is the playbook's trigger for Clear-ShadowCopies.ps1, which deletes all but
    the newest restore point and can cap the storage limit. The script refreshes the
    value when it finishes.
#>

try {
    $cached = Get-ItemProperty -Path 'HKLM:\Software\AirWatch\Extensions\DiskState' -Name 'ShadowCopyMb' -ErrorAction SilentlyContinue
    if ($null -eq $cached -or [string]::IsNullOrEmpty("$($cached.ShadowCopyMb)")) {
        Write-Output -1
        return
    }
    Write-Output ([int]$cached.ShadowCopyMb)
    return
}
catch {
    Write-Output -1
    return
}
