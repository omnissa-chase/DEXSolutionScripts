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
    Version      : 1.1.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-10-28

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

$SCRIPT_VERSION = "1.1.0"
$RunEventId = ([Random]::new()).Next(1000,9999)
Write-Output "[$RunEventId] Executing script, $SCRIPT_VERSION.  Started @ '$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))'"
$HEAD="`r`n[$RunEventId]"

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

if($null -eq $PerformanceScore){
    $PerformanceScore=0

    # +1 for every 2 years after 2020, -1 for every 2 years before 2020
    $biosDate = (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).ReleaseDate -as [DateTime]
    if($biosDate){
        $cutoff = Get-Date "2020-01-01"
        $PerformanceScore += [int][Math]::Round((($biosDate.Subtract($cutoff)).TotalDays / 365)/2)
    }

    # -1 for every logical processor under 4, +1 for every one above 4
    $CPUPerf0=[Environment]::ProcessorCount
    If($CPUPerf0){
        $PerformanceScore += ($CPUPerf0 - 4)
    }

    # System drive media and bus type
    if(-not ([string]::IsNullOrEmpty($env:SystemDrive))){
        try {
            $SystemDrive = $env:SystemDrive.Substring(0,1)
            $DiskNumber = (Get-Partition -DriveLetter $SystemDrive -ErrorAction Stop).DiskNumber
            $SystemDisk = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$DiskNumber }
            $PerfScores=@{"HDD"=-2;"SSD"=2;"NVMe"=2}
            $HDDPerf0=[string]$SystemDisk.MediaType
            $HDDPerf1=[string]$SystemDisk.BusType
            If($PerfScores.ContainsKey($HDDPerf0)){ $PerformanceScore+=$PerfScores[$HDDPerf0] }
            If($PerfScores.ContainsKey($HDDPerf1)){ $PerformanceScore+=$PerfScores[$HDDPerf1] }
        } catch {
            Write-Output "$HEAD Could not determine system disk type: $($_.Exception.Message). Disk contributes 0."
        }
    }
    New-ItemProperty -Path $healthDetectionPath -Name PerformanceScore -Value $PerformanceScore -PropertyType String -Force | Out-Null
    Write-Output "$HEAD Computed performance score $PerformanceScore (BIOS, CPU count, disk type) and cached it."
} else {
    Write-Output "$HEAD Using cached performance score $PerformanceScore."
}

# Map the score to a profile. Every score lands in exactly one bucket.
if     ($PerformanceScore -lt 0) { $TargetProfile = 'VeryLow' }
elseif ($PerformanceScore -le 2) { $TargetProfile = 'Low' }
elseif ($PerformanceScore -le 6) { $TargetProfile = 'Mid' }
else                             { $TargetProfile = 'High' }

If($TargetProfile -ne $CurrentProfile){
    Write-Output "$HEAD Applying Defender CPU profile '$TargetProfile' (was '$CurrentProfile')."
    # Defaults, then the per-profile overrides.
    Set-MpPreference -DisableCpuThrottleOnIdleScans $false
    Set-MpPreference -EnableLowCpuPriority $false
    Set-MpPreference -ScanAvgCPULoadFactor (50 -as [byte])
    switch ($TargetProfile) {
        'VeryLow' {
            Set-MpPreference -ScanAvgCPULoadFactor (20 -as [byte])
            Set-MpPreference -EnableLowCpuPriority $true
        }
        'Low'  { Set-MpPreference -ScanAvgCPULoadFactor (40 -as [byte]) }
        'Mid'  { Set-MpPreference -ScanAvgCPULoadFactor (50 -as [byte]) }
        'High' { Set-MpPreference -ScanAvgCPULoadFactor (75 -as [byte]) }
    }
    New-ItemProperty -Path $healthDetectionPath -Name CurrentProfile -Value $TargetProfile -PropertyType String -Force | Out-Null
} else {
    Write-Output "$HEAD Defender CPU profile '$TargetProfile' is already applied. No changes made."
}

$pref = Get-MpPreference
Write-Output "$HEAD ScanAvgCPULoadFactor=$($pref.ScanAvgCPULoadFactor) EnableLowCpuPriority=$($pref.EnableLowCpuPriority) DisableCpuThrottleOnIdleScans=$($pref.DisableCpuThrottleOnIdleScans)"
Exit 0
