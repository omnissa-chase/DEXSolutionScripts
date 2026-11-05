# ScriptName: Defender_FullScan_1.0.3.3
# Context: System
#
# 1.0.3.2 (2026-10-28): $healthDetectionPath was only assigned in the "no monitoring task"
# branch, so the task-present branch read a $null path and FullScanInProgress=1 never
# suppressed a scan. The Get-MpComputerStatus fallback stored DateTime values but compared
# .TimeCreated on them, which is $null, so a finished scan was reported as running.
# Start-MpScan now uses -ErrorAction Stop so the catch block is reachable. 24-hour timestamp.
# 1.0.3.3 (2026-11-05): full-scan start/finish events read through the .NET EventLogReader; Get-WinEvent fails in every form under Hub's ARM64 PowerShell 7.2 engine.
#region --- Event log reader --------------------------------------------------------------------
# Get-WinEvent fails in every form under Hub's ARM64 PowerShell 7.2 engine ("Cannot marshal
# 'parameter #8'"), so events are read through System.Diagnostics.Eventing.Reader, which behaves
# the same on Windows PowerShell 5.1 and PowerShell 7. Get-WinEvent semantics are kept: newest
# first unless -Oldest, StartTime/EndTime are whole-second bounds, a failed read yields an empty
# result unless -ErrorStop. Each record carries a Message property (FormatDescription(), falling
# back to the raw property values when the provider ships no message metadata).
function Get-DexEvent {
    param(
        [Parameter(Mandatory = $true)][string]$LogName,
        [int[]]$Id,
        [string[]]$ProviderName,
        [int[]]$Level,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string]$XPath,
        [int]$MaxEvents = 0,
        [switch]$Oldest,
        [switch]$ErrorStop
    )
    $sys = New-Object System.Collections.Generic.List[string]
    if ($Id)           { $sys.Add('(' + (@($Id | ForEach-Object { "EventID=$_" }) -join ' or ') + ')') }
    if ($ProviderName) { $sys.Add('(' + (@($ProviderName | ForEach-Object { "Provider[@Name='$_']" }) -join ' or ') + ')') }
    if ($Level)        { $sys.Add('(' + (@($Level | ForEach-Object { "Level=$_" }) -join ' or ') + ')') }
    $when = New-Object System.Collections.Generic.List[string]
    if ($PSBoundParameters.ContainsKey('StartTime')) {
        $t = $StartTime.ToUniversalTime(); $t = $t.AddTicks(-($t.Ticks % [TimeSpan]::TicksPerSecond))
        $when.Add("@SystemTime>='" + $t.ToString('o') + "'")
    }
    if ($PSBoundParameters.ContainsKey('EndTime')) {
        $t = $EndTime.ToUniversalTime()
        if ($t.Ticks % [TimeSpan]::TicksPerSecond) { $t = $t.AddTicks([TimeSpan]::TicksPerSecond - ($t.Ticks % [TimeSpan]::TicksPerSecond)) }
        $when.Add("@SystemTime<='" + $t.ToString('o') + "'")
    }
    if ($when.Count -gt 0) { $sys.Add('TimeCreated[' + ($when -join ' and ') + ']') }
    $query = if ($XPath) { $XPath } elseif ($sys.Count -gt 0) { '*[System[' + ($sys -join ' and ') + ']]' } else { '*' }
    $getMessage = {
        $m = $null
        try { $m = $this.FormatDescription() } catch { }
        if (-not $m) { $m = (@($this.Properties | ForEach-Object { "$($_.Value)" }) -join "`n") }
        $m
    }
    $out = New-Object System.Collections.Generic.List[object]
    $reader = $null
    try {
        $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery($LogName, [System.Diagnostics.Eventing.Reader.PathType]::LogName, $query)
        $q.ReverseDirection = -not $Oldest
        $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
        while (($MaxEvents -le 0 -or $out.Count -lt $MaxEvents) -and ($null -ne ($record = $reader.ReadEvent()))) {
            $po = [System.Management.Automation.PSObject]::AsPSObject($record)
            $po.PSObject.Properties.Add((New-Object System.Management.Automation.PSScriptProperty('Message', $getMessage)))
            $out.Add($po)
        }
    } catch {
        if ($ErrorStop) { throw }
    } finally {
        if ($reader) { $reader.Dispose() }
    }
    return $out.ToArray()
}
function Get-DexEventLog {
    param([Parameter(Mandatory = $true)][string]$LogName)
    try { return New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration($LogName) } catch { return $null }
}
#endregion

$SCRIPT_VERSION = "1.0.3.3"
# Enable WhatIfPreference to $true if you want to test this sample
$WhatIfPreference=$false

$RunEventId = ([Random]::new()).Next(1000,9999)
Write-Output "[$RunEventId] Executing script, $SCRIPT_VERSION.  Started @ '$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))'"
$HEAD="`r`n[$RunEventId]"

if ($PSVersionTable.PSVersion.Major -ge 7) {
    Import-Module -Name ConfigDefender -SkipEditionCheck -ErrorAction Stop
}

$healthDetectionPath="HKLM:\SOFTWARE\AIRWATCH\Extensions\HealthDetection"
If(-not (Test-Path $healthDetectionPath)) { New-Item -Path $healthDetectionPath -Force | Out-Null }

$defendermonitor = Get-ScheduledTask -TaskPath "\WorkspaceOneEx\Defender\" -TaskName FullScanDetection -ErrorAction SilentlyContinue
if(@($defendermonitor).Count -eq 0){
    Write-Output "$HEAD Defender monitoring task not detected.  Manually detecting for existing scan..."

    $fullScanRunning=$false

    # Newest full-scan start (1000) and finish (1001) events. Normalise both to [DateTime]
    # so the comparison below works whether the value came from an event or from
    # Get-MpComputerStatus.
    $startEvt = Get-DexEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -Id 1000 -MaxEvents 100 |
        Where-Object { $_.Id -eq 1000 -and $_.Message -match 'Scan Parameters:\s*Full scan' } |
        Select-Object -First 1

    $endEvt = Get-DexEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -Id 1001 -MaxEvents 100 |
        Where-Object { $_.Id -eq 1001 -and $_.Message -match 'Scan Parameters:\s*Full scan' } |
        Select-Object -First 1

    $startTime = $null
    $endTime   = $null
    if($startEvt){
        $startTime = $startEvt.TimeCreated
        if($endEvt){ $endTime = $endEvt.TimeCreated }
    } else {
        $stats = (Get-MpComputerStatus)
        $startTime = $stats.FullScanStartTime
        $endTime   = $stats.FullScanEndTime
    }

    if($startTime){
        if(-not $endTime){
            $fullScanRunning = $true
        }elseif($startTime -ge $endTime){
            $fullScanRunning = $true
        }
    }

}Else{
    Write-Output "$HEAD Defender monitoring task detected.  Checking registry entry..."
    $currentDetectedStatus=Get-ItemProperty -Path $healthDetectionPath -ErrorAction SilentlyContinue | Select-Object -Property FullScanInProgress -ExpandProperty FullScanInProgress -ErrorAction SilentlyContinue
    $fullScanRunning = ($currentDetectedStatus -eq 1)
}

If($fullScanRunning){
    Write-Output "$HEAD Full scan is already running. Exiting..."
    Exit 0
}


# Start Full Defender scan
$Scan=$null
Try{
    Write-Output "$HEAD Starting Defender scan (Full Scan)."
    If(-not $WhatIfPreference){
        $Scan=Start-MpScan -ScanType FullScan -AsJob -ErrorAction Stop
    } Else { 
        Write-Output "`r`nWhat if: Performing the operation 'Start-MpScan' on target 'HOST' with option 'ScanType=FullScan', as new job" 
    }
}Catch{
    Write-Output "$HEAD An error has occured running Full Scan: $($_.Exception.Message)"
    Exit 1
}
Exit 0