<#
.NOTES
    Script Name  : performance_defender_scanorupdateactive.ps1
    Data Type    : String 
    Version      : 1.0.2
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05

    Returns Idle, FullScanActive, Updating or FullScanActive;Updating as one line.
    1.0.1: the Get-WinEvent calls are silenced. Under Hub the sensor ran in 1.5 s and
    was rejected as "failed sanity" while an interactive run printed Idle, which
    points at a non-terminating error record reaching the output stream; a sensor
    must emit exactly one line.
    1.0.2: full-scan start/finish events read through the .NET EventLogReader; Get-WinEvent fails in every form under Hub's ARM64 PowerShell 7.2 engine.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

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

    $status = ''

    $defenderScanning = $false
    $defenderUpdating = $false

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Import-Module -Name ConfigDefender -SkipEditionCheck -ErrorAction Stop
    }

    try {
        $stats = (Get-MpComputerStatus -ErrorAction SilentlyContinue)
        # Attempt to gather the full scan status from the event log
        $startEvt = Get-DexEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -Id 1000 -MaxEvents 100 |
            Where-Object { $_.Id -eq 1000 -and $_.Message -match 'Scan Parameters:\s*Full scan' } |
            Select-Object -First 1

        $endEvt = Get-DexEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -Id 1001 -MaxEvents 100 |
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
