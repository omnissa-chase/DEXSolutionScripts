#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : storage_health_score
    Data Type    : Integer
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-16 (1.0.0)
    Timeout      : < 5 seconds (one registry read)
    Requires     : Invoke-AutoRemediateStorageHealth.ps1 run on a schedule (daily is enough)

    Storage health of the drive behind the system volume, 0-100. Higher is healthier.
    100 minus a deduction for each finding (failing or worn drive, bad blocks, I/O errors,
    file system errors, a volume waiting for repair, TRIM off, Optimize Drives disabled or
    stale, a spinning boot disk). The table is in the script and in storage_health.ps1.
    -1 means the script has not run on this device yet.
#>
try {
    $cached = Get-ItemProperty -Path 'HKLM:\Software\AirWatch\Extensions\StorageHealth' -Name 'HealthScore' -ErrorAction SilentlyContinue
    if ($null -eq $cached -or $null -eq $cached.HealthScore) {
        Write-Output -1
        return
    }
    Write-Output ([int]$cached.HealthScore)
    return
}
catch {
    Write-Output -1
    return
}
