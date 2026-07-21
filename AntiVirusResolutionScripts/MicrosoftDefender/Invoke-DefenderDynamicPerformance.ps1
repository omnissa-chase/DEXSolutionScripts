<#
.SYNOPSIS
    Invoke-DefenderDynamicPerformance -- Tunes Microsoft Defender scan CPU limits based on device hardware.

.DESCRIPTION
    Calculates a hardware performance score from BIOS generation date, logical processor
    count, and system disk type (HDD/SSD/NVMe), then maps the score to one of four
    Defender CPU profiles (VeryLow / Low / Medium / High) and applies the corresponding
    ScanAvgCPULoadFactor and EnableLowCpuPriority settings via Set-MpPreference.
    The score and active profile are persisted under the AirWatch HealthDetection registry
    key so subsequent runs can skip recalculation.

.NOTES
    Script Name  : Invoke-DefenderDynamicPerformance.ps1
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-20

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$healthDetectionPath =  "HKLM:\SOFTWARE\AIRWATCH\Extensions\HealthDetection"
if(-not (Test-Path $healthDetectionPath)){ New-Item -Path $healthDetectionPath -Force | Out-Null }

$PerformanceProfiles=@(
    New-Object -Type PSCustomObject -Property @{'Name'='VeryLow';
      'MaxScore'=0;
      'DisableCpuThrottleOnIdleScans'=$false;
      'EnableLowCpuPriority'=$true;
      'ScanAvgCPULoadFactor'=25};
    New-Object -Type PSCustomObject -Property @{'Name'='Low';
      'MinScore'=0;
      'MaxScore'=2;
      'DisableCpuThrottleOnIdleScans'=$false;
      'EnableLowCpuPriority'=$false;
      'ScanAvgCPULoadFactor'=50};
    New-Object -Type PSCustomObject -Property @{'Name'='Medium';
      'MinScore'=3;
      'MaxScore'=6;
      'DisableCpuThrottleOnIdleScans'=$false;
      'EnableLowCpuPriority'=$false;
      'ScanAvgCPULoadFactor'=60};
    New-Object -Type PSCustomObject -Property @{'Name'='High';
      'MinScore'=7;
      'DisableCpuThrottleOnIdleScans'=$false;
      'EnableLowCpuPriority'=$false;
      'ScanAvgCPULoadFactor'=75};
)

$PerformanceScore = Get-ItemProperty $healthDetectionPath -ErrorAction SilentlyContinue | Select-Object -Property PerformanceProfile -ExpandProperty PerformanceProfile -ErrorAction SilentlyContinue
$CurrentProfile = Get-ItemProperty $healthDetectionPath -ErrorAction SilentlyContinue | Select-Object -Property CurrentProfile -ExpandProperty CurrentProfile -ErrorAction SilentlyContinue

if($PerformanceScore -eq $null){
    $PerformanceScore=0
    
    # +1 FOR EVERY 2 YEARS AFTER 2020
    # -1 FOR EVERY 2 YEARS BEFORE 2020
    $biosQuery = Get-CimInstance Win32_BIOS
    $biosDate = ($biosQuery.ReleaseDate -as [DateTime])
    if($biosDate){
        $cutoff = Get-Date "2020-01-01"
        $GenerationCalc = [Math]::Round((($biosDate.Subtract($cutoff)).TotalDays / 365)/2)
        $PerformanceScore += $GenerationCalc
    }
    
    # Get # of logical processors
    # -1 for every core under 4
    # +1 for every core above 4
    $CPUPerf0=[Environment]::ProcessorCount
    If($CPUPerf0){
        $PerformanceScore += ($CPUPerf0 - 4)
    }

    # Get performance of System drive
    if(-not ([string]::IsNullOrEmpty($env:SystemDrive))){
        $SystemDrive = $env:SystemDrive.Substring(0,1)
        $DiskNumber = (Get-Partition -DriveLetter $SystemDrive).DiskNumber
        $SystemDisk = Get-PhysicalDisk | Where DeviceId -eq $DiskNumber
        $PerfScores=@{"HDD"=-2;"SSD"=2;"NVMe"=2}
        $HDDPerf0=$SystemDisk.MediaType
        $HDDPerf1=$SystemDisk.BusType
        If($PerfScores.ContainsKey($HDDPerf0)){
            $PerformanceScore+=$PerfScores[$HDDPerf0]
        }
        If($PerfScores.ContainsKey($HDDPerf1)){
            $PerformanceScore+=$PerfScores[$HDDPerf1]
        } 
    }
    New-ItemProperty $healthDetectionPath -Name PeformanceScore -Value $PerformanceScore -Force | Out-Null
}

function Get-CurrentDefProfile(){
    $pref=Get-MpPreference
    $CPUThrottle=$pref.DisableCpuThrottleOnIdleScans
    $CPULoad=$pref.ScanAvgCPULoadFactor


}


If($PerformanceScore -ne $CurrentProfile){ 
    #Default configurations
    Set-MpPreference -DisableCpuThrottleOnIdleScans $false
    Set-MpPreference -EnableLowCpuPriority $false
    Set-MpPreference -ScanAvgCPULoadFactor (50 -as [byte])
    If($PerformanceScore -lt 0){
        #Performance score - Very Low
        Set-MpPreference -ScanAvgCPULoadFactor (20 -as [byte])
        Set-MpPreference -EnableLowCpuPriority $true
    }ElseIf($PerformanceScore -le 2){
        #Performance score - Low
        Set-MpPreference -ScanAvgCPULoadFactor (40 -as [byte])
    }ElseIf($PerformanceScore -le 6){
        #Performance score - Mid
        Set-MpPreference -ScanAvgCPULoadFactor (50 -as [byte])
    }ElseIf($PerformanceScore -gt 8){
        #Performance score - High
        Set-MpPreference -ScanAvgCPULoadFactor (75 -as [byte])
    }
}



$PowerProfile=[System.Windows.Forms.SystemInformation]::PowerStatus