<#
.SYNOPSIS
    Invoke-DefenderDynamicPerformance -- Tunes Microsoft Defender scan CPU limits based on device hardware.

.DESCRIPTION
    Calculates a hardware performance score from BIOS generation date, logical processor
    count, and system disk type (HDD/SSD/NVMe), then maps the score to one of four
    Defender CPU profiles (VeryLow / Low / Mid / High) and applies the corresponding
    ScanAvgCPULoadFactor and EnableLowCpuPriority settings via Set-MpPreference.
    The score and active profile are persisted under the AirWatch HealthDetection registry
    key (PerformanceScore, CurrentProfile) so subsequent runs can skip recalculation and
    only re-apply settings when the profile changes.

    Profiles:
        VeryLow  score <  0   ScanAvgCPULoadFactor 20, EnableLowCpuPriority on
        Low      score <= 2   ScanAvgCPULoadFactor 40
        Mid      score <= 6   ScanAvgCPULoadFactor 50
        High     score >  6   ScanAvgCPULoadFactor 75

.NOTES
    Script Name  : Invoke-DefenderDynamicPerformance.ps1
    Version      : 1.2.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05

    1.2.0: drift is repaired, not just a profile change: the live Defender preferences are
    compared with the target profile's values every run and re-applied when they differ even
    though CurrentProfile already matches. CurrentProfile is written only after every
    Set-MpPreference succeeded (-ErrorAction Stop; a failure exits 1 and leaves the marker
    alone so the next run tries again). The cached score carries a HardwareFingerprint
    (BIOS date, logical processors, system disk media and bus) and is recomputed when the
    hardware changes. Score, profile, settings and the last run time are mirrored under
    HKLM:\SOFTWARE\AirWatch\Extension\DEXRecords\Defender\DynamicPerformance; the
    HealthDetection cache stays where it was for compatibility.

    1.1.0: the cached score was written as 'PeformanceScore' but read as 'PerformanceProfile',
    so it was recomputed every run and CurrentProfile was never written, so settings were
    re-applied every run. Scores 7 and 8 fell through to no profile. The trailing
    System.Windows.Forms reference threw under a strict host. ConfigDefender is now imported
    on PowerShell 7 like the other Defender scripts. Output lines and exit codes added so the
    caller can tell what happened (0 applied or already current, 1 Defender unavailable).

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$SCRIPT_VERSION = "1.2.0"
$RunEventId = ([Random]::new()).Next(1000,9999)
Write-Output "[$RunEventId] Executing script, $SCRIPT_VERSION.  Started @ '$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))'"
$HEAD="[$RunEventId]"

# DEXRecords mirror (the HealthDetection cache below is the script's working state).
$dexRecordsPath = 'HKLM:\SOFTWARE\AirWatch\Extension\DEXRecords\Defender\DynamicPerformance'
function Write-DexRecord([hashtable]$Values) {
    try {
        if (-not (Test-Path $dexRecordsPath)) { New-Item -Path $dexRecordsPath -Force | Out-Null }
        foreach ($k in $Values.Keys) { New-ItemProperty -Path $dexRecordsPath -Name $k -Value ([string]$Values[$k]) -PropertyType String -Force | Out-Null }
    } catch { }
}

if ($PSVersionTable.PSVersion.Major -ge 7) {
    Import-Module -Name ConfigDefender -SkipEditionCheck -ErrorAction SilentlyContinue
}
if (-not (Get-Command Set-MpPreference -ErrorAction SilentlyContinue)) {
    Write-Output "$HEAD Microsoft Defender cmdlets are not available on this device. Nothing to do."
    Exit 1
}

$healthDetectionPath = "HKLM:\SOFTWARE\AIRWATCH\Extensions\HealthDetection"
if(-not (Test-Path $healthDetectionPath)){ New-Item -Path $healthDetectionPath -Force | Out-Null }

$cached = Get-ItemProperty -Path $healthDetectionPath -ErrorAction SilentlyContinue
$PerformanceScore = $null
if ($cached -and $null -ne $cached.PerformanceScore) {
    $parsed = 0
    if ([int]::TryParse([string]$cached.PerformanceScore, [ref]$parsed)) { $PerformanceScore = $parsed }
}
$CurrentProfile = if ($cached) { [string]$cached.CurrentProfile } else { '' }
$cachedFingerprint = if ($cached) { [string]$cached.HardwareFingerprint } else { '' }

# The inputs to the score, read every run so a hardware change (more cores, a new system
# disk, a firmware update) invalidates the cached score instead of living on forever.
$biosDate = (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).ReleaseDate -as [DateTime]
$CPUPerf0 = [Environment]::ProcessorCount
$HDDPerf0 = ''; $HDDPerf1 = ''; $diskError = $null
if(-not ([string]::IsNullOrEmpty($env:SystemDrive))){
    try {
        $SystemDrive = $env:SystemDrive.Substring(0,1)
        $DiskNumber = (Get-Partition -DriveLetter $SystemDrive -ErrorAction Stop).DiskNumber
        $SystemDisk = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$DiskNumber }
        $HDDPerf0=[string]$SystemDisk.MediaType
        $HDDPerf1=[string]$SystemDisk.BusType
    } catch { $diskError = $_.Exception.Message }
}
$fingerprint = "bios=$(if ($biosDate) { $biosDate.ToString('yyyy-MM-dd') })|cpu=$CPUPerf0|disk=$HDDPerf0/$HDDPerf1"

if($null -eq $PerformanceScore -or $cachedFingerprint -ne $fingerprint){
    $reason = if ($null -eq $PerformanceScore) { 'no cached score' } else { "hardware changed ('$cachedFingerprint' -> '$fingerprint')" }
    $PerformanceScore=0

    # +1 for every 2 years after 2020, -1 for every 2 years before 2020
    if($biosDate){
        $cutoff = Get-Date "2020-01-01"
        $PerformanceScore += [int][Math]::Round((($biosDate.Subtract($cutoff)).TotalDays / 365)/2)
    }

    # -1 for every logical processor under 4, +1 for every one above 4
    If($CPUPerf0){
        $PerformanceScore += ($CPUPerf0 - 4)
    }

    # System drive media and bus type
    if ($diskError) {
        Write-Output "$HEAD Could not determine system disk type: $diskError. Disk contributes 0."
    } else {
        $PerfScores=@{"HDD"=-2;"SSD"=2;"NVMe"=2}
        If($PerfScores.ContainsKey($HDDPerf0)){ $PerformanceScore+=$PerfScores[$HDDPerf0] }
        If($PerfScores.ContainsKey($HDDPerf1)){ $PerformanceScore+=$PerfScores[$HDDPerf1] }
    }
    try {
        New-ItemProperty -Path $healthDetectionPath -Name PerformanceScore -Value $PerformanceScore -PropertyType String -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $healthDetectionPath -Name HardwareFingerprint -Value $fingerprint -PropertyType String -Force -ErrorAction Stop | Out-Null
        Write-Output "$HEAD Computed performance score $PerformanceScore (BIOS, CPU count, disk type; $reason) and cached it."
    } catch {
        Write-Output "$HEAD Computed performance score $PerformanceScore (BIOS, CPU count, disk type; $reason); the cache could not be written ($($_.Exception.Message)), so it will be recomputed next run."
    }
} else {
    Write-Output "$HEAD Using cached performance score $PerformanceScore (hardware unchanged)."
}

# Map the score to a profile. Every score lands in exactly one bucket.
if     ($PerformanceScore -lt 0) { $TargetProfile = 'VeryLow' }
elseif ($PerformanceScore -le 2) { $TargetProfile = 'Low' }
elseif ($PerformanceScore -le 6) { $TargetProfile = 'Mid' }
else                             { $TargetProfile = 'High' }

# What the target profile means in Defender terms.
$TargetLoad   = switch ($TargetProfile) { 'VeryLow' { 20 } 'Low' { 40 } 'Mid' { 50 } 'High' { 75 } }
$TargetLowPri = ($TargetProfile -eq 'VeryLow')

# Drift: compare the live preferences with the target, not just the marker. A profile that
# "matches" while someone has changed the load factor by hand is a fault this script owns.
$pref  = Get-MpPreference -ErrorAction SilentlyContinue
$drift = @()
if ($pref) {
    if ([int]$pref.ScanAvgCPULoadFactor -ne $TargetLoad)        { $drift += "ScanAvgCPULoadFactor $($pref.ScanAvgCPULoadFactor) (want $TargetLoad)" }
    if ([bool]$pref.EnableLowCpuPriority -ne $TargetLowPri)     { $drift += "EnableLowCpuPriority $($pref.EnableLowCpuPriority) (want $TargetLowPri)" }
    if ([bool]$pref.DisableCpuThrottleOnIdleScans)              { $drift += 'DisableCpuThrottleOnIdleScans True (want False)' }
}

$applied = $false
If($TargetProfile -ne $CurrentProfile -or $drift.Count -gt 0){
    $why = if ($TargetProfile -ne $CurrentProfile) { "was '$CurrentProfile'" } else { "drift: $($drift -join '; ')" }
    Write-Output "$HEAD Applying Defender CPU profile '$TargetProfile' ($why)."
    try {
        Set-MpPreference -DisableCpuThrottleOnIdleScans $false -ErrorAction Stop
        Set-MpPreference -EnableLowCpuPriority $TargetLowPri -ErrorAction Stop
        Set-MpPreference -ScanAvgCPULoadFactor ($TargetLoad -as [byte]) -ErrorAction Stop
        # The marker is written only once every setting took, so a failed apply is retried next run.
        New-ItemProperty -Path $healthDetectionPath -Name CurrentProfile -Value $TargetProfile -PropertyType String -Force | Out-Null
        $applied = $true
    } catch {
        Write-Output "$HEAD Error: Set-MpPreference failed, profile marker left unchanged so the next run retries: $($_.Exception.Message)"
        Write-DexRecord @{ LastRun = (Get-Date).ToString('s'); ScriptVersion = $SCRIPT_VERSION; PerformanceScore = $PerformanceScore; TargetProfile = $TargetProfile; Result = 'ApplyFailed'; Error = $_.Exception.Message }
        Exit 1
    }
} else {
    Write-Output "$HEAD Defender CPU profile '$TargetProfile' is already applied and the live settings match. No changes made."
}

$pref = Get-MpPreference -ErrorAction SilentlyContinue
Write-Output "$HEAD ScanAvgCPULoadFactor=$($pref.ScanAvgCPULoadFactor) EnableLowCpuPriority=$($pref.EnableLowCpuPriority) DisableCpuThrottleOnIdleScans=$($pref.DisableCpuThrottleOnIdleScans)"
Write-DexRecord @{
    LastRun = (Get-Date).ToString('s'); ScriptVersion = $SCRIPT_VERSION
    PerformanceScore = $PerformanceScore; HardwareFingerprint = $fingerprint; CurrentProfile = $TargetProfile
    Result = $(if ($applied) { 'Applied' } else { 'AlreadyCurrent' })
    ScanAvgCPULoadFactor = $pref.ScanAvgCPULoadFactor; EnableLowCpuPriority = $pref.EnableLowCpuPriority
}
Exit 0
