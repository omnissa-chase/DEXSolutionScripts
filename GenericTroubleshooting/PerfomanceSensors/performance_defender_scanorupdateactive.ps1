<#
.NOTES
    Script Name  : performance_defender_scanorupdateactive.ps1
    Data Type    : String 
    Version      : 1.0.1
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-10-29

    Returns Idle, FullScanActive, Updating or FullScanActive;Updating as one line.
    1.0.1: the Get-WinEvent calls are silenced. Under Hub the sensor ran in 1.5 s and
    was rejected as "failed sanity" while an interactive run printed Idle, which
    points at a non-terminating error record reaching the output stream; a sensor
    must emit exactly one line.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

    $status = ''

    $defenderScanning = $false
    $defenderUpdating = $false

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Import-Module -Name ConfigDefender -SkipEditionCheck -ErrorAction Stop
    }

    try {
        $stats = (Get-MpComputerStatus -ErrorAction SilentlyContinue)
        # Attempt to gather the full scan status from the event log
        $startEvt = Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 100 -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -eq 1000 -and $_.Message -match 'Scan Parameters:\s*Full scan' } |
            Select-Object -First 1

        $endEvt = Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 100 -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -eq 1001 -and $_.Message -match 'Scan Parameters:\s*Full scan' } |
            Select-Object -First 1
    
        if(($stats)){
            if(-not ($startEvt)){
                $startEvt = $stats.FullScanStartTime
                $endEvt = $stats.FullScanEndTime
            }
        }
        

        $FullScanHours=0
        if($startEvt){
            if(-not $endEvt -or ($startEvt -ge $endEvt)){
                $status += (If(!([string]::IsNullOrEmpty($status))){";"}Else{""}) + 'FullScanActive'
            }
        }
    }catch {}

    try {
        $updateProcesses = Get-Process -Name 'MpCmdRun','MpSigStub' -ErrorAction SilentlyContinue
        if ($updateProcesses) {
            $status += (If(!([string]::IsNullOrEmpty($status))){";"}Else{""}) + 'Updating'
        }
    }
    catch {}


    if ([string]::IsNullOrEmpty($status) ) {
        $status = 'Idle'
    }

    Write-Output ([string]$status)
