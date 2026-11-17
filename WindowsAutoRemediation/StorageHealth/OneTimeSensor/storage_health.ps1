#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : storage_health
    Data Type    : String (one compressed JSON object, under Hub's 1 KB sensor value cap)
    Version      : 1.0.0
    Architecture : Any (x86/x64/ARM64)
    Context      : System (drive wear, temperature and failure prediction need administrator rights)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-16 (1.0.0)
    Timeout      : One-time / run-once sensor only. Typically 3 to 8 s. MUST NOT be scheduled
                   as a recurring sensor (it reads a week of the System event log).

    The on-demand companion of Invoke-AutoRemediateStorageHealth.ps1: the same facts and
    the same deduction table (the shared block below is identical in both files), as a JSON
    summary and without changing anything. It answers "is this device slow or unstable
    because of its drive", which DEX does not capture on its own.

    Keys: Schema, Collected, ElapsedMs, Virtual (VM: TRIM, optimize schedule and drive type
    are not graded unless IncludeVirtualMachines=true), Model, Media (SSD, HDD, SCM,
    Unknown), Bus (NVMe, SATA, ...), SizeGB, Health (drive: Healthy, Warning, Unhealthy,
    Unknown), PredictFail (SMART failure predicted), Wear (percent of rated SSD life used),
    TempC, MediaErrors (uncorrected read plus write errors), PowerOnHours, OtherDisks and
    OtherBad (other internal drives, and how many are unhealthy), Volume (system volume:
    Healthy, ScanNeeded, SpotFixNeeded, FullRepairNeeded, Unknown), EventDays, BadBlocks
    (disk event 7), IoErrors (disk 11/51/153 on the system drive, storage port 11/129),
    FsErrors (Ntfs 55/137/140 on the system volume), Trim (On, Off), OptimizeTask (Enabled,
    Disabled, Missing, Unknown), DaysSinceOptimize, Score, Reason, NextStep, Detail, Ded.

    Score: 100 minus DriveFailing 60, DriveWarning 30, BadBlocks 25, WearHigh 25 (90 percent
    or more), MediaErrors 20, FileSystemErrors 20, IoErrors 15 (5 or more events; 5 points
    for 1 to 4), SecondaryDriveUnhealthy 15, DriveHot 10 (70 C or more), SpinningBootDrive
    15, VolumeRepairAtRestart 20, VolumeScanNeeded 15, TrimDisabled 10, OptimizeDisabled 10,
    OptimizeStale 5 (not run in OptimizeStaleDays); floor 0. Reason is the largest deduction.
    NextStep: ADMIN (a hardware finding: Detail says what to do), USER (restart so Windows
    repairs the volume), AUTO (run the script), NONE. Ded lists every deduction as
    "Name:points" and is trimmed from the end until the JSON fits in 1,000 bytes.
    Sentinels: -1 unknown or not reported by the drive.

    Optional script variables: EventLookbackDays (default 7), OptimizeStaleDays (default 45),
    IncludeVirtualMachines (default false).

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$ErrorActionPreference = 'SilentlyContinue'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$EventDays = 7
$StaleDays = 45
if ("$env:EventLookbackDays" -match '^\d{1,2}$' -and [int]$env:EventLookbackDays -ge 1 -and [int]$env:EventLookbackDays -le 30) { $EventDays = [int]$env:EventLookbackDays }
if ("$env:OptimizeStaleDays" -match '^\d{1,3}$' -and [int]$env:OptimizeStaleDays -ge 1 -and [int]$env:OptimizeStaleDays -le 365) { $StaleDays = [int]$env:OptimizeStaleDays }
$IncludeVirtual = ("$env:IncludeVirtualMachines".Trim() -in @('true', '1', 'yes', 'y'))

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

try {
    $f = Get-StorageFacts -EventDays $EventDays -IncludeVirtual $IncludeVirtual
    $s = Get-StorageScore -Facts $f -StaleDays $StaleDays
    $healthNames = @{ 0 = 'Healthy'; 1 = 'Warning'; 2 = 'Unhealthy' }
    $volNames = @{ 0 = 'Healthy'; 1 = 'ScanNeeded'; 2 = 'SpotFixNeeded'; 3 = 'FullRepairNeeded' }
    $model = "$($f.Model)"; if ($model.Length -gt 28) { $model = $model.Substring(0, 28) }
    $payload = [ordered]@{
        Schema = 1; Collected = (Get-Date -Format 's'); ElapsedMs = 0; Virtual = [bool]$f.Virtual
        Model = $model; Media = $f.Media; Bus = $f.Bus; SizeGB = $f.SizeGB
        Health = $(if ($healthNames.ContainsKey($f.Health)) { $healthNames[$f.Health] } else { 'Unknown' })
        PredictFail = [bool]$f.PredictFail; Wear = $f.Wear; TempC = $f.TempC; MediaErrors = $f.MediaErrors; PowerOnHours = $f.PowerOnHours
        OtherDisks = $f.OtherDisks; OtherBad = $f.OtherBad
        Volume = $(if ($volNames.ContainsKey($f.VolHealth)) { $volNames[$f.VolHealth] } else { 'Unknown' })
        EventDays = $f.EventDays; BadBlocks = $f.BadBlocks; IoErrors = $f.IoErrors; FsErrors = $f.FsErrors
        Trim = $(if ($f.TrimDisabled) { 'Off' } else { 'On' }); OptimizeTask = $f.OptimizeTask; DaysSinceOptimize = $f.DaysSinceOptimize
        Score = $s.Score; Reason = $s.Reason; NextStep = $s.NextStep; Detail = $s.Detail
        Ded = @()
    }
    $rows = @($s.Deductions.Keys | ForEach-Object { "${_}:$($s.Deductions[$_])" })
    do {
        $payload.Ded = @($rows)
        $payload.ElapsedMs = [int]$sw.ElapsedMilliseconds
        $json = ConvertTo-Json -InputObject $payload -Compress -Depth 3
        if ($json.Length -le 1000 -or $rows.Count -eq 0) { break }
        $rows = @($rows | Select-Object -First ($rows.Count - 1))
    } while ($true)
    Write-Output $json
    return
}
catch {
    Write-Output ('{{"Schema":1,"Score":-1,"Reason":"Error","NextStep":"NONE","Error":"{0}"}}' -f ($_.Exception.Message -replace '["\\]', "'"))
    return
}
