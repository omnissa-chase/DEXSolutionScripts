#Requires -Version 5.1
<#
.SYNOPSIS
    Checks the health of the drive behind the system volume and repairs the storage
    settings that can be repaired from the endpoint: an online volume scan, TRIM, and
    the Optimize Drives schedule.

.DESCRIPTION
    Pairs with OneTimeSensor\storage_health.ps1, which grades the same facts on demand.
    A failing or worn drive, bad blocks and I/O errors are a costly cause of a slow or
    unstable device that DEX does not capture on its own. This script reports them and
    caches a 0-100 score and a reason for storage_health_score / storage_health_reason.

      1  Drive Health                 report only (failure prediction, health, wear,
                                      media errors, temperature)
      2  Storage Errors In Event Log  report only (bad blocks, I/O errors, controller
                                      resets, file system errors)
      3  System Volume Health         scan needed: start the Windows online scan;
                                      repair queued: report (it runs at the next restart)
      4  TRIM                         turn TRIM back on
      5  Optimize Drives Schedule     re-enable the ScheduledDefrag task
      6  Optimize Drives Recency      start the task when it has not run in OptimizeStaleDays
      7  Boot Drive Type              report only (spinning disk)

    Steps 1, 2 and 7 print as Warning: a hardware fault needs a backup and a replacement,
    not a script. Step 3 never takes the volume offline (built-in ProactiveScan task).
    Steps 5 and 6 use Windows' own Optimize Drives task (retrim SSD, defragment HDD).

    Steps 4 to 7 are skipped on a virtual machine, where TRIM, defragmentation and the
    drive type belong to the platform (VDI images turn the schedule off on purpose).
    IncludeVirtualMachines=true manages them on persistent VMs.

    Results: HKLM:\Software\AirWatch\Extensions\StorageHealth (score, reason) and
    HKLM:\Software\AirWatch\Extension\DEXRecords\SystemHealth\StorageHealth (per step).

.NOTES
    Script Name  : Invoke-AutoRemediateStorageHealth.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-16 (1.0.0)
    Timeout      : 30 seconds (typically 5 to 12; the scan and the optimisation it starts
                   run in Windows' own tasks after the script has exited)

    Environment variables (each is also a parameter; a parameter wins): WhatIf=true (dry
    run, the intended first run), EventLookbackDays (System log days for step 2, default
    7), OptimizeStaleDays (step 6, default 45), IncludeVirtualMachines (default false).

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# == Shared block: identical in Invoke-AutoRemediateStorageHealth.ps1 and OneTimeSensor\storage_health.ps1
# == (Test-StorageHealthScore.ps1 fails when the copies differ). Edit both together.
function Get-StorageFacts {
    param([int]$EventDays = 7, [bool]$IncludeVirtual = $false)
    $ns = 'root/Microsoft/Windows/Storage'
    $f = [ordered]@{
        Virtual = $false; ConfigChecks = $true; SysDisk = -1; Model = ''; Media = 'Unknown'; Bus = 'Unknown'; SizeGB = -1
        Health = -1; PredictFail = $false; Wear = -1; TempC = -1; MediaErrors = -1; PowerOnHours = -1
        OtherDisks = 0; OtherBad = 0; VolHealth = -1
        EventDays = $EventDays; BadBlocks = 0; IoErrors = 0; FsErrors = 0
        TrimDisabled = $false; OptimizeTask = 'Unknown'; DaysSinceOptimize = -1
    }
    $letter = "$env:SystemDrive".Substring(0, 1)
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $f.Virtual = [bool]("$($cs.Manufacturer) $($cs.Model)" -match 'VMware|Virtual|Hyper-V|QEMU|KVM|Xen|Nutanix|Parallels')
    } catch { }
    # On a VM, TRIM, the optimize schedule and the drive type belong to the platform.
    $f.ConfigChecks = (-not $f.Virtual) -or $IncludeVirtual

    # -- Drives: the one behind the system volume, and a count of other internal drives --
    try {
        $part = Get-CimInstance -Namespace $ns -ClassName MSFT_Partition -Filter "DriveLetter='$letter'" -ErrorAction Stop | Select-Object -First 1
        if ($part) { $f.SysDisk = [int]$part.DiskNumber }
    } catch { }
    $mediaNames = @{ 3 = 'HDD'; 4 = 'SSD'; 5 = 'SCM' }
    $busNames = @{ 7 = 'USB'; 8 = 'RAID'; 10 = 'SAS'; 11 = 'SATA'; 12 = 'SD'; 13 = 'MMC'; 14 = 'Virtual'; 15 = 'VHD'; 16 = 'Spaces'; 17 = 'NVMe'; 19 = 'UFS' }
    try {
        foreach ($d in @(Get-CimInstance -Namespace $ns -ClassName MSFT_PhysicalDisk -ErrorAction Stop)) {
            $bus = [int]$d.BusType
            if ("$($d.DeviceId)" -ne "$($f.SysDisk)") {
                # USB, SD and mounted virtual disks come and go; they are not this device's storage.
                if ($bus -notin 7, 12, 14, 15) { $f.OtherDisks++; if ([int]$d.HealthStatus -in 1, 2) { $f.OtherBad++ } }
                continue
            }
            $f.Model = "$($d.FriendlyName)".Trim()
            if ($d.Size -gt 0) { $f.SizeGB = [int][math]::Round($d.Size / 1GB) }
            $mt = [int]$d.MediaType
            if ($mediaNames.ContainsKey($mt)) { $f.Media = $mediaNames[$mt] }
            elseif ($d.SpindleSpeed -gt 0 -and $d.SpindleSpeed -lt 4294967295) { $f.Media = 'HDD' }
            if ($busNames.ContainsKey($bus)) { $f.Bus = $busNames[$bus] } else { $f.Bus = "Bus$bus" }
            if ([int]$d.HealthStatus -in 0, 1, 2) { $f.Health = [int]$d.HealthStatus }
            try {
                # Needs administrator rights (SYSTEM has them); empty on most virtual disks.
                $r = Get-CimAssociatedInstance -InputObject $d -ResultClassName MSFT_StorageReliabilityCounter -ErrorAction Stop | Select-Object -First 1
                if ($r) {
                    if ($null -ne $r.Wear) { $f.Wear = [int]$r.Wear }
                    # Virtual disks report placeholders (254 on a VMware NVMe disk); only a plausible reading counts.
                    if ($r.Temperature -gt 0 -and $r.Temperature -le 110) { $f.TempC = [int]$r.Temperature }
                    if ($null -ne $r.ReadErrorsUncorrected -or $null -ne $r.WriteErrorsUncorrected) {
                        $f.MediaErrors = [int][math]::Min(999999, [double]$r.ReadErrorsUncorrected + [double]$r.WriteErrorsUncorrected)
                    }
                    if ($null -ne $r.PowerOnHours -and $r.PowerOnHours -lt 2000000) { $f.PowerOnHours = [int]$r.PowerOnHours }
                }
            } catch { }
        }
    } catch { }
    try {
        # SMART failure prediction as the storage driver reports it. Not supported on VMs.
        foreach ($p in @(Get-CimInstance -Namespace 'root/wmi' -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)) {
            if ($p.PredictFailure -and "$($p.InstanceName)" -notmatch '^USBSTOR') { $f.PredictFail = $true }
        }
    } catch { }

    # -- System volume health: 0 healthy, 1 scan needed, 2 spot fix needed, 3 full repair needed --
    try {
        $v = Get-CimInstance -Namespace $ns -ClassName MSFT_Volume -Filter "DriveLetter='$letter'" -ErrorAction Stop | Select-Object -First 1
        if ($v) {
            $ops = @($v.OperationalStatus | ForEach-Object { [int]$_ })
            if ($ops -contains 53263) { $f.VolHealth = 3 }
            elseif ($ops -contains 53262) { $f.VolHealth = 2 }
            elseif ($ops -contains 53261) { $f.VolHealth = 1 }
            elseif ([int]$v.HealthStatus -eq 2) { $f.VolHealth = 3 }
            elseif ([int]$v.HealthStatus -eq 1) { $f.VolHealth = 1 }
            else { $f.VolHealth = 0 }
        }
    } catch { }

    # -- System log: bad blocks, I/O errors and controller resets, file system errors --
    $reader = $null
    try {
        $ms = [int64]$EventDays * 86400000
        $xp = "*[System[(EventID=7 or EventID=11 or EventID=51 or EventID=55 or EventID=129 or EventID=137 or EventID=140 or EventID=153) and (Level=1 or Level=2 or Level=3) and TimeCreated[timediff(@SystemTime) <= $ms]]]"
        $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('System', [System.Diagnostics.Eventing.Reader.PathType]::LogName, $xp)
        $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
        $n = 0
        while ($n -lt 5000 -and $null -ne ($e = $reader.ReadEvent())) {
            $n++
            $prov = "$($e.ProviderName)"; $id = [int]$e.Id
            $isDisk = ($prov -eq 'disk'); $isNtfs = ($prov -match '^(Microsoft-Windows-)?Ntfs$')
            $isPort = ($id -in 11, 129 -and $prov -match '^(stor|iastor|nvme|secnvme|vmd)')
            if ($isDisk -or $isNtfs -or $isPort) {
                $text = ''
                try { $text = (@($e.Properties | ForEach-Object { "$($_.Value)" }) -join ' ') } catch { }
                if ($isDisk) {
                    # disk events name \Device\Harddisk<n>; one for another drive (USB stick, dock) is not counted.
                    if ($text -match 'Harddisk(\d+)' -and [int]$Matches[1] -ne $f.SysDisk) { }
                    elseif ($id -eq 7) { $f.BadBlocks++ }
                    elseif ($id -in 11, 51, 153) { $f.IoErrors++ }
                }
                elseif ($isNtfs) { if ($id -in 55, 137, 140 -and $text -match "(?<![A-Za-z])${letter}:") { $f.FsErrors++ } }
                else { $f.IoErrors++ }
            }
            $e.Dispose()
        }
    } catch { } finally { if ($reader) { $reader.Dispose() } }

    # -- TRIM and the Optimize Drives schedule --
    try { $f.TrimDisabled = ([int](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'DisableDeleteNotification' -ErrorAction Stop).DisableDeleteNotification -eq 1) } catch { }
    try {
        $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop
        if ("$($t.State)" -eq 'Disabled' -or -not $t.Settings.Enabled) { $f.OptimizeTask = 'Disabled' } else { $f.OptimizeTask = 'Enabled' }
        $since = $null
        try { $last = ($t | Get-ScheduledTaskInfo -ErrorAction Stop).LastRunTime; if ($last -and $last.Year -gt 2000) { $since = $last } } catch { }
        # Never run: count from the OS install date, so a new device is not called stale.
        if (-not $since) { try { $since = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).InstallDate } catch { } }
        if ($since) { $f.DaysSinceOptimize = [int][math]::Max(0, [math]::Floor(((Get-Date) - $since).TotalDays)) }
    } catch { if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { $f.OptimizeTask = 'Missing' } }
    return $f
}

function Get-StorageScore {
    param($Facts, [int]$StaleDays = 45)
    $f = $Facts; $d = [ordered]@{}
    # Hardware findings first: nothing here can be repaired from the endpoint.
    if ($f.PredictFail -or $f.Health -eq 2) { $d.DriveFailing = 60 } elseif ($f.Health -eq 1) { $d.DriveWarning = 30 }
    if ($f.BadBlocks -gt 0) { $d.BadBlocks = 25 }
    if ($f.Wear -ge 90) { $d.WearHigh = 25 }
    if ($f.MediaErrors -gt 0) { $d.MediaErrors = 20 }
    if ($f.FsErrors -gt 0) { $d.FileSystemErrors = 20 }
    if ($f.IoErrors -ge 5) { $d.IoErrors = 15 } elseif ($f.IoErrors -gt 0) { $d.IoErrors = 5 }
    if ($f.OtherBad -gt 0) { $d.SecondaryDriveUnhealthy = 15 }
    if ($f.TempC -ge 70) { $d.DriveHot = 10 }
    if ($f.ConfigChecks -and $f.Media -eq 'HDD') { $d.SpinningBootDrive = 15 }
    $hardware = $d.Count
    # Then what the script, or a restart, can put right.
    if ($f.VolHealth -ge 2) { $d.VolumeRepairAtRestart = 20 } elseif ($f.VolHealth -eq 1) { $d.VolumeScanNeeded = 15 }
    if ($f.ConfigChecks) {
        if ($f.TrimDisabled -and $f.Media -ne 'HDD') { $d.TrimDisabled = 10 }
        if ($f.OptimizeTask -eq 'Disabled') { $d.OptimizeDisabled = 10 }
        elseif ($f.OptimizeTask -eq 'Enabled' -and $f.DaysSinceOptimize -gt $StaleDays) { $d.OptimizeStale = 5 }
    }
    $sum = 0; $reason = 'Healthy'; $top = 0; $hwReason = ''; $hwTop = 0; $i = 0
    foreach ($k in @($d.Keys)) {
        $sum += $d[$k]
        if ($d[$k] -gt $top) { $top = $d[$k]; $reason = $k }
        if ($i -lt $hardware -and $d[$k] -gt $hwTop) { $hwTop = $d[$k]; $hwReason = $k }
        $i++
    }
    $adminDetail = @{
        DriveFailing = 'Drive reports failure: back up now and replace it'
        DriveWarning = 'Drive reports a warning: back up and plan a replacement'
        BadBlocks = 'Bad blocks logged: back up and replace the drive'
        WearHigh = 'SSD near the end of its rated life: plan a replacement'
        MediaErrors = 'Uncorrected media errors: back up and plan a replacement'
        FileSystemErrors = 'File system errors logged: check the drive, then chkdsk'
        IoErrors = 'I/O errors or controller resets: check firmware, driver, cabling'
        SecondaryDriveUnhealthy = 'A second internal drive is unhealthy'
        DriveHot = 'Drive is running hot: check airflow and fans'
        SpinningBootDrive = 'Boot drive is a spinning disk: an SSD is the fix'
    }
    $next = 'NONE'; $detail = ''
    if ($hwReason) { $next = 'ADMIN'; $detail = $adminDetail[$hwReason] }
    elseif ($d.Contains('VolumeRepairAtRestart')) { $next = 'USER'; $detail = 'Restart the device: Windows repairs the system volume at startup' }
    elseif ($d.Count -gt 0) { $next = 'AUTO'; $detail = 'Invoke-AutoRemediateStorageHealth.ps1' }
    return @{ Score = [int][math]::Max(0, 100 - $sum); Reason = $reason; NextStep = $next; Detail = $detail; Deductions = $d }
}
# == End of shared block ==

function Invoke-AutoRemediateStorageHealth {
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateRange(1, 30)]
    [int]$EventLookbackDays = $(
        $v = 0
        if ([int]::TryParse("$env:EventLookbackDays".Trim(), [ref]$v) -and $v -ge 1 -and $v -le 30) { $v } else { 7 }
    ),
    [ValidateRange(1, 365)]
    [int]$OptimizeStaleDays = $(
        $v = 0
        if ([int]::TryParse("$env:OptimizeStaleDays".Trim(), [ref]$v) -and $v -ge 1 -and $v -le 365) { $v } else { 45 }
    ),
    [bool]$IncludeVirtualMachines = $(
        $env:IncludeVirtualMachines -and $env:IncludeVirtualMachines.Trim() -in @('true', '1', 'yes', 'y')
    )
)

$SCRIPT_VERSION = "1.0.0"
$RegPath        = "HKLM:\Software\AirWatch\Extensions\StorageHealth"
$DexRecordsPath = "HKLM:\Software\AirWatch\Extension\DEXRecords\SystemHealth\StorageHealth"
$LogPath        = "$env:SystemRoot\Temp\UEM_AutoRemediateStorageHealth.log"
$FsKey          = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
$DefragPath     = '\Microsoft\Windows\Defrag\'
$DefragTask     = 'ScheduledDefrag'
$ChkdskPath     = '\Microsoft\Windows\Chkdsk\'

# -- WhatIf bridge -------------------------------------------------------------
# UEM cannot set $WhatIfPreference directly. Bridge it from an environment
# variable. Absent, empty, or unparseable => $false (live run).
$DryRun = $false
if ($env:WhatIf) {
    try   { $DryRun = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $DryRun = $false }
}

# -- Run header ----------------------------------------------------------------
$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Output "[$RunEventId] Executing Invoke-AutoRemediateStorageHealth, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$DryRun"
$HEAD = "`r`n[$RunEventId]"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    # -WhatIf:$false so a dry run is still recorded; the log is evidence, not state.
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}
function Res { param([string]$Status, [string]$Message) @{ Status = $Status; Message = $Message } }

Write-Log "Settings: EventLookbackDays=$EventLookbackDays OptimizeStaleDays=$OptimizeStaleDays IncludeVirtualMachines=$IncludeVirtualMachines"

# -- Facts (gathered once; detection only reads them, so detection never mutates) --
# Read before $WhatIfPreference is set: a module that auto-loads under WhatIf prints a
# "What if: Set Alias" line for each of its aliases (Windows PowerShell 5.1).
$Facts = Get-StorageFacts -EventDays $EventLookbackDays -IncludeVirtual $IncludeVirtualMachines
$WhatIfPreference = $DryRun
$Drive = if ($Facts.Model) { "$($Facts.Model) ($($Facts.Media), $($Facts.Bus), $($Facts.SizeGB) GB)" } else { 'System drive' }
$Vol   = $env:SystemDrive
$NotVm = 'Not checked: virtual machine, left to the platform (IncludeVirtualMachines=true to manage it).'
Write-Log "Facts: $((@($Facts.Keys | ForEach-Object { "$_=$($Facts[$_])" })) -join ' ')"

# -- Steps ---------------------------------------------------------------------
# Each detection returns @{ Status = Passed | Warning | Failed; Message = ... } (through Res).
$Steps = @(
@{
    Name = 'Drive Health'; Order = 1; Enabled = $true; ResolveOnWarning = $false; ResolutionScript = $null
    DetectionScript = {
        if ($Facts.SysDisk -lt 0 -or -not $Facts.Model) { return (Res 'Warning' 'Could not identify the drive behind the system volume (Storage Spaces, RAID, or a driver that hides it).') }
        $issues = @()
        if ($Facts.PredictFail) { $issues += 'SMART predicts failure' }
        if ($Facts.Health -eq 2) { $issues += 'drive reports Unhealthy' } elseif ($Facts.Health -eq 1) { $issues += 'drive reports Warning' }
        if ($Facts.Wear -ge 90) { $issues += "$($Facts.Wear)% of rated SSD life used" }
        if ($Facts.MediaErrors -gt 0) { $issues += "$($Facts.MediaErrors) uncorrected media error(s)" }
        if ($Facts.TempC -ge 70) { $issues += "temperature $($Facts.TempC) C" }
        if ($Facts.OtherBad -gt 0) { $issues += "$($Facts.OtherBad) other internal drive(s) unhealthy" }
        if ($issues.Count -gt 0) { return (Res 'Warning' "${Drive}: $($issues -join '; '). Back up the device and plan a drive replacement; no script can repair this.") }
        $extra = ''
        if ($Facts.Wear -ge 0) { $extra += ", wear $($Facts.Wear)%" }
        if ($Facts.TempC -ge 0) { $extra += ", $($Facts.TempC) C" }
        if ($Facts.Health -lt 0) { return (Res 'Passed' "${Drive}: the drive does not report a health status$extra.") }
        Res 'Passed' "${Drive}: healthy$extra."
    }
},
@{
    Name = 'Storage Errors In Event Log'; Order = 2; Enabled = $true; ResolveOnWarning = $false; ResolutionScript = $null
    DetectionScript = {
        $issues = @()
        if ($Facts.BadBlocks -gt 0) { $issues += "$($Facts.BadBlocks) bad-block event(s)" }
        if ($Facts.IoErrors -gt 0) { $issues += "$($Facts.IoErrors) I/O error or controller reset event(s)" }
        if ($Facts.FsErrors -gt 0) { $issues += "$($Facts.FsErrors) file system error event(s)" }
        if ($issues.Count -gt 0) { return (Res 'Warning' "$($issues -join '; ') on the system drive in the last $EventLookbackDays day(s). Check the drive, its firmware and the storage driver.") }
        Res 'Passed' "No storage errors for the system drive in the last $EventLookbackDays day(s)."
    }
},
@{
    Name = 'System Volume Health'; Order = 3; Enabled = $true; ResolveOnWarning = $false
    DetectionScript = {
        switch ($Facts.VolHealth) {
            0 { return (Res 'Passed' "$Vol reports healthy.") }
            1 { return (Res 'Failed' "$Vol is flagged 'scan needed': NTFS saw a possible fault and wants an online scan.") }
            2 { return (Res 'Warning' "$Vol is flagged 'spot fix needed': Windows repairs it at the next restart. Restart the device.") }
            3 { return (Res 'Warning' "$Vol is flagged 'full repair needed': Windows runs chkdsk at the next restart. Back up first, then restart.") }
        }
        Res 'Warning' "Could not read the health of $Vol."
    }
    ResolutionScript = {
        $t = Get-ScheduledTask -TaskPath $ChkdskPath -TaskName 'ProactiveScan' -ErrorAction Stop
        if ("$($t.State)" -eq 'Disabled') { Enable-ScheduledTask -TaskPath $ChkdskPath -TaskName 'ProactiveScan' -ErrorAction Stop | Out-Null }
        if ("$($t.State)" -ne 'Running') { Start-ScheduledTask -TaskPath $ChkdskPath -TaskName 'ProactiveScan' -ErrorAction Stop | Out-Null }
        Res 'Pending' "Windows online volume scan started (ProactiveScan task); the volume stays in use. Re-run to confirm $Vol reports healthy."
    }
},
@{
    Name = 'TRIM'; Order = 4; Enabled = $true; ResolveOnWarning = $false
    DetectionScript = {
        if (-not $Facts.ConfigChecks) { return (Res 'Passed' $NotVm) }
        if ($Facts.Media -eq 'HDD') { return (Res 'Passed' 'Not applicable: the boot drive is a spinning disk.') }
        if ($Facts.TrimDisabled) { return (Res 'Failed' 'TRIM is turned off (DisableDeleteNotify = 1): deleted space is never handed back to the SSD, which slows writes as the drive fills.') }
        Res 'Passed' 'TRIM is on.'
    }
    ResolutionScript = {
        $null = & fsutil.exe behavior set DisableDeleteNotify NTFS 0 2>&1
        if ($LASTEXITCODE -ne 0) { $null = & fsutil.exe behavior set DisableDeleteNotify 0 2>&1 }
        $rc  = $LASTEXITCODE
        $now = (Get-ItemProperty -Path $FsKey -Name 'DisableDeleteNotification' -ErrorAction SilentlyContinue).DisableDeleteNotification
        if ([int]$now -ne 0) { throw "fsutil did not turn TRIM on (exit $rc, DisableDeleteNotification=$now)" }
    }
},
@{
    Name = 'Optimize Drives Schedule'; Order = 5; Enabled = $true; ResolveOnWarning = $false
    DetectionScript = {
        if (-not $Facts.ConfigChecks) { return (Res 'Passed' $NotVm) }
        switch ($Facts.OptimizeTask) {
            'Enabled'  { return (Res 'Passed' 'The Optimize Drives task (ScheduledDefrag) is enabled.') }
            'Disabled' { return (Res 'Failed' 'The Optimize Drives task (ScheduledDefrag) is disabled: the SSD is never retrimmed and a spinning disk is never defragmented.') }
            'Missing'  { return (Res 'Warning' 'The Optimize Drives task (ScheduledDefrag) does not exist on this device.') }
        }
        Res 'Warning' 'Could not read the Optimize Drives task.'
    }
    ResolutionScript = {
        Enable-ScheduledTask -TaskPath $DefragPath -TaskName $DefragTask -ErrorAction Stop | Out-Null
        $t = Get-ScheduledTask -TaskPath $DefragPath -TaskName $DefragTask -ErrorAction Stop
        if ("$($t.State)" -eq 'Disabled') { throw 'the task is still disabled after Enable-ScheduledTask' }
    }
},
@{
    Name = 'Optimize Drives Recency'; Order = 6; Enabled = $true; ResolveOnWarning = $false
    DetectionScript = {
        if (-not $Facts.ConfigChecks) { return (Res 'Passed' $NotVm) }
        if ($Facts.OptimizeTask -notin 'Enabled', 'Disabled') { return (Res 'Passed' 'Not checked: no readable Optimize Drives task (step 5).') }
        if ($Facts.DaysSinceOptimize -lt 0) { return (Res 'Warning' 'Could not read when Optimize Drives last ran.') }
        if ($Facts.DaysSinceOptimize -gt $OptimizeStaleDays) { return (Res 'Failed' "Optimize Drives has not run for $($Facts.DaysSinceOptimize) day(s) (limit $OptimizeStaleDays). On its own it only runs when the device is idle on AC power.") }
        Res 'Passed' "Optimize Drives last ran $($Facts.DaysSinceOptimize) day(s) ago."
    }
    ResolutionScript = {
        $t = Get-ScheduledTask -TaskPath $DefragPath -TaskName $DefragTask -ErrorAction Stop
        if ("$($t.State)" -eq 'Disabled') { throw 'the Optimize Drives task is disabled (step 5 did not enable it)' }
        if ("$($t.State)" -ne 'Running') { Start-ScheduledTask -TaskPath $DefragPath -TaskName $DefragTask -ErrorAction Stop | Out-Null }
        Res 'Pending' 'Optimize Drives started in the background (retrim on SSD, defragment on HDD, low priority); it finishes on its own.'
    }
},
@{
    Name = 'Boot Drive Type'; Order = 7; Enabled = $true; ResolveOnWarning = $false; ResolutionScript = $null
    DetectionScript = {
        if (-not $Facts.ConfigChecks) { return (Res 'Passed' $NotVm) }
        if ($Facts.Media -eq 'HDD') { return (Res 'Warning' 'Windows boots from a spinning disk. Boot, logon and app launch are several times slower than on an SSD; replacing the drive is the fix.') }
        if ($Facts.Media -eq 'Unknown') { return (Res 'Passed' 'The drive does not report its type.') }
        Res 'Passed' "Windows boots from solid-state storage ($($Facts.Media), $($Facts.Bus))."
    }
}
)

# -- Engine --------------------------------------------------------------------
Write-Output "$HEAD === Storage Health Checks ==="
$results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

foreach ($step in ($Steps | Where-Object { $_.Enabled } | Sort-Object { [int]$_.Order })) {
    $status = 'Failed'; $message = ''; $remediated = $false; $remError = $null; $detectionThrew = $false
    try {
        $result  = & $step.DetectionScript
        $status  = $result.Status
        $message = $result.Message
    } catch {
        # A detection that threw is a step failure, and never a reason to change the device.
        $detectionThrew = $true
        $status  = 'Failed'
        $message = "Detection exception: $($_.Exception.Message)"
    }

    $shouldRemediate = (-not $detectionThrew) -and (($status -eq 'Failed') -or ($status -eq 'Warning' -and $step.ResolveOnWarning))
    if ($shouldRemediate -and $step.ResolutionScript) {
        if ($PSCmdlet.ShouldProcess($step.Name, 'Repair storage configuration')) {
            try {
                $r = & $step.ResolutionScript
                $remediated = $true
                if ($r -is [hashtable] -and $r.Status -eq 'Pending') { $status = 'Pending'; $message = $r.Message }
            } catch { $remError = $_.Exception.Message }
        }
    }

    $remNote = if ($remediated -and $status -ne 'Pending') { '  -> Remediated' } elseif ($remError) { "  -> Remediation ERROR: $remError" } else { '' }
    Write-Output "`r`n  [$($status.PadRight(7))] $($step.Name): $message$remNote"
    Write-Log "$($step.Name): $status - $message$remNote"
    $results.Add([PSCustomObject]@{ Order = $step.Order; Name = $step.Name; Status = $status; Message = $message; Remediated = $remediated; RemError = $remError })
}

# -- Summary -------------------------------------------------------------------
$passed   = @($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
$pending  = @($results | Where-Object { $_.Status -eq 'Pending' }).Count
# A Failed step whose remediation ran is not a failure; a remediation that threw is.
$failed   = @($results | Where-Object { ($_.Status -eq 'Failed' -and -not $_.Remediated) -or $_.RemError }).Count
$remCount = @($results | Where-Object { $_.Remediated }).Count
$remErrs  = @($results | Where-Object { $_.RemError }).Count

# Grade again after a repair so the cached score describes the device as the script left it.
$After = $Facts
if ($remCount -gt 0) { $After = Get-StorageFacts -EventDays $EventLookbackDays -IncludeVirtual $IncludeVirtualMachines }
$Final = Get-StorageScore -Facts $After -StaleDays $OptimizeStaleDays
$dedText = (@($Final.Deductions.Keys | ForEach-Object { "${_}:$($Final.Deductions[$_])" })) -join ';'

Write-Output "`r`n--------------------------------------------------------------------"
Write-Output "  Passed: $passed  |  Warnings: $warnings  |  Pending: $pending  |  Failed: $failed  |  Remediations run: $remCount"
Write-Output "  Storage health: score=$($Final.Score)  reason=$($Final.Reason)  next step=$($Final.NextStep)$(if ($Final.Detail) { "  ($($Final.Detail))" })"
Write-Output "--------------------------------------------------------------------`r`n"
Write-Log "Summary: Passed=$passed Warnings=$warnings Pending=$pending Failed=$failed RemediationsRun=$remCount RemediationErrors=$remErrs Score=$($Final.Score) Reason=$($Final.Reason) Deductions='$dedText'"

# -- Registry reporting --------------------------------------------------------
# Skipped entirely on a WhatIf run -- a dry run must not claim a state that was never applied.
if (-not $DryRun) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try {
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null }
        $healthNames = @{ 0 = 'Healthy'; 1 = 'Warning'; 2 = 'Unhealthy' }
        $volNames    = @{ 0 = 'Healthy'; 1 = 'ScanNeeded'; 2 = 'SpotFixNeeded'; 3 = 'FullRepairNeeded' }
        $strings = [ordered]@{
            LastRun = $stamp; ScriptVersion = $SCRIPT_VERSION; HealthReason = $Final.Reason; NextStep = $Final.NextStep; Detail = $Final.Detail; Deductions = $dedText
            Status = $(if ($failed -gt 0) { 'Failed' } elseif ($pending -gt 0) { 'Pending' } else { 'Completed' })
            DriveHealth  = $(if ($healthNames.ContainsKey($After.Health)) { $healthNames[$After.Health] } else { 'Unknown' })
            VolumeHealth = $(if ($volNames.ContainsKey($After.VolHealth)) { $volNames[$After.VolHealth] } else { 'Unknown' })
        }
        foreach ($k in $strings.Keys) { Set-ItemProperty -Path $RegPath -Name $k -Value "$($strings[$k])" -Type String }
        $numbers = [ordered]@{
            HealthScore = $Final.Score
            Passed = $passed; Warnings = $warnings; Pending = $pending; Failed = $failed; RemediationsRun = $remCount; RemediationErrors = $remErrs
        }
        foreach ($k in $numbers.Keys) { Set-ItemProperty -Path $RegPath -Name $k -Value ([int]$numbers[$k]) -Type DWord }
        Write-Log "Results cached to $RegPath"
    } catch { Write-Log "Registry cache write failed: $($_.Exception.Message)" 'WARN' }

    # Per-step DEXRecords values (family convention). Fully wrapped: a registry failure
    # here must never change the exit code.
    try {
        if (-not (Test-Path $DexRecordsPath)) { New-Item -Path $DexRecordsPath -Force -ErrorAction Stop | Out-Null }
        $existing = Get-Item -Path $DexRecordsPath -ErrorAction SilentlyContinue
        if ($existing) { $existing.GetValueNames() | ForEach-Object { Remove-ItemProperty -Path $DexRecordsPath -Name $_ -ErrorAction SilentlyContinue } }
        Set-ItemProperty -Path $DexRecordsPath -Name 'LastScanTime'  -Value $stamp -Type String
        Set-ItemProperty -Path $DexRecordsPath -Name 'ScriptVersion' -Value $SCRIPT_VERSION -Type String
        $counts = [ordered]@{ TotalSteps = $results.Count; PassedCount = $passed; WarningCount = $warnings; PendingCount = $pending; FailedCount = $failed; RemediatedCount = $remCount }
        foreach ($k in $counts.Keys) { Set-ItemProperty -Path $DexRecordsPath -Name $k -Value ([int]$counts[$k]) -Type DWord }
        foreach ($r in $results) {
            $valueName = 'Step{0:D2}_{1}' -f $r.Order, ($r.Name -replace '[^A-Za-z0-9]', '')
            $tag  = if ($r.Remediated -and $r.Status -ne 'Pending') { '[Remediated]' } else { "[$($r.Status)]" }
            $text = "$tag $($r.Name): $($r.Message)"
            if ($r.RemError) { $text += "  -> Remediation ERROR: $($r.RemError)" }
            if ($text.Length -gt 500) { $text = $text.Substring(0, 497) + '...' }
            Set-ItemProperty -Path $DexRecordsPath -Name $valueName -Value $text -Type String
        }
        Write-Log "Per-step results written to $DexRecordsPath"
    } catch { Write-Log "DEXRecords write failed: $($_.Exception.Message)" 'WARN' }
} else {
    Write-Log 'WhatIf run -- registry cache left untouched.'
}

exit $(if ($failed -gt 0) { 1 } else { 0 })
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function deliberately: the Workspace ONE script
# engine does not recognise one at script scope, and $PSCmdlet is $null there.

Invoke-AutoRemediateStorageHealth
Exit 0
