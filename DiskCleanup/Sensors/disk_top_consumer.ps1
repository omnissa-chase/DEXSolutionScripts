#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : disk_top_consumer
    Data Type    : String
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-13
    Timeout      : < 5 seconds
    Requires     : Invoke-DiskStateCollection.ps1 scheduled once a day

    The largest measured item on the system drive that is 1 GB or more, as a fixed key a
    playbook can branch on. Unknown means the collector has not run on this device.

      Cleared by a script     SafeCleanup, CrashDumps, PreviousWindows, RecycleBin,
                              ShadowCopies
      Policy fix, no script   HibernationFile, PageFile, OutlookData, OneDriveLocal,
                              VirtualDisks, Downloads, UserFolders
      None                    nothing measured reaches 1 GB

    This is the sensor that says a cleanup will not help: when a full disk is an Outlook
    data file, OneDrive content kept on the device or the hibernation file, no cleanup
    script frees it, and the playbook should route to the admin instead. The sizes are in
    the one-time disk_space_health sensor.
#>

try {
    $cached = Get-ItemProperty -Path 'HKLM:\Software\AirWatch\Extensions\DiskState' -Name 'TopConsumer' -ErrorAction SilentlyContinue
    if ($null -eq $cached -or [string]::IsNullOrEmpty("$($cached.TopConsumer)")) {
        Write-Output 'Unknown'
        return
    }
    Write-Output ([string]$cached.TopConsumer)
    return
}
catch {
    Write-Output 'Unknown'
    return
}
