#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : storage_health_reason
    Data Type    : String
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-16 (1.0.0)
    Timeout      : < 5 seconds (one registry read)
    Requires     : Invoke-AutoRemediateStorageHealth.ps1 run on a schedule (daily is enough)

    The single largest deduction from storage_health_score. One of:
    Healthy, DriveFailing, DriveWarning, BadBlocks, WearHigh, MediaErrors,
    FileSystemErrors, IoErrors, SecondaryDriveUnhealthy, DriveHot, SpinningBootDrive,
    VolumeRepairAtRestart, VolumeScanNeeded, TrimDisabled, OptimizeDisabled, OptimizeStale.
    Empty means the script has not run on this device yet.
#>
try {
    $cached = Get-ItemProperty -Path 'HKLM:\Software\AirWatch\Extensions\StorageHealth' -Name 'HealthReason' -ErrorAction SilentlyContinue
    if ($null -eq $cached -or [string]::IsNullOrEmpty($cached.HealthReason)) {
        Write-Output ""
        return
    }
    Write-Output ([string]$cached.HealthReason)
    return
}
catch {
    Write-Output ""
    return
}
