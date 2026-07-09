#Requires -Version 7.0
<#
.SYNOPSIS
    Records Group Policy Client Side Extension (CSE) load times for the currently
    logged-on user to the registry. Designed to run as SYSTEM via a WorkspaceONE
    logon script trigger.

.DESCRIPTION
    Mines the Microsoft-Windows-GroupPolicy event log for the most recent GP processing
    cycle of the active user (EID 4001 = start, EID 5016 = CSE finish) and captures:
      - Total GP processing duration
      - Top 5 slowest CSEs by duration
      - GPOs associated with the slowest CSE

    All values are written as string registry values under:
      HKLM:\Software\AirWatch\Extensions\DEXRecords\GPLoadTime

    This script leverages PowerShell 7 features:
      - Null-coalescing operator (??)
      - Ternary operator (? :)
      - Null-conditional member access (?.)
      - ForEach-Object -Parallel for concurrent start/finish event retrieval

.NOTES
    PowerShell 7+ required.
    Based on logic from ControlUp's Analyze GPO Extensions Load Time script by @guyrleech.
    Run via WorkspaceONE as a logon-triggered script under SYSTEM context.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE in the repository root for full license terms (MIT).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

#region --- Identify the currently logged-on interactive user ---
$loggedOnUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName

if ([string]::IsNullOrEmpty($loggedOnUser)) {
    Write-Warning 'No interactive user detected. Exiting.'
    exit 1
}
#endregion

#region --- Find the most recent GP processing start event (EID 4001) for this user ---
$gpXPath = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$loggedOnUser')]] and *[System[(EventID='4001')]]"
$gpStartEvent = Get-WinEvent -ProviderName 'Microsoft-Windows-GroupPolicy' `
    -FilterXPath $gpXPath -MaxEvents 1 -ErrorAction SilentlyContinue

if (-not $gpStartEvent) {
    Write-Warning "No GP processing start event (EID 4001) found for '$loggedOnUser'. Exiting."
    exit 1
}

$gpStartTime  = $gpStartEvent.TimeCreated
$activityGuid = '{' + $gpStartEvent.ActivityId.Guid + '}'
#endregion

#region --- Retrieve CSE start (EID 4016) and finish (EID 5016/6016/7016) events in parallel ---
$eventResults = @('Start', 'Finish') | ForEach-Object -Parallel {
    $type         = $_
    $startTime    = $using:gpStartTime
    $guid         = $using:activityGuid
    $ErrorActionPreference = 'SilentlyContinue'

    $timeFilter = "TimeCreated[@SystemTime>='$($startTime.ToUniversalTime().ToString('s'))." +
                  "$($startTime.ToUniversalTime().ToString('fff'))Z']"
    $corrFilter = "Correlation[@ActivityID='$guid']"

    $eidFilter = $type -eq 'Start' ? "EventID='4016'" : "EventID='5016' or EventID='6016' or EventID='7016'"
    $xPath     = "*[System[($eidFilter) and $timeFilter and $corrFilter]]"

    $events = Get-WinEvent -ProviderName 'Microsoft-Windows-GroupPolicy' `
        -FilterXPath $xPath -ErrorAction SilentlyContinue

    [PSCustomObject]@{ Type = $type; Events = $events }
} -ThrottleLimit 2

$cseStartEvents  = ($eventResults | Where-Object Type -eq 'Start').Events
$cseFinishEvents = ($eventResults | Where-Object Type -eq 'Finish').Events
#endregion

if (-not $cseFinishEvents -or $cseFinishEvents.Count -eq 0) {
    Write-Warning 'No CSE finish events found for this GP processing cycle. Exiting.'
    exit 1
}

#region --- Build CSE-to-GPO map from EID 4016 start events ---
# Properties[0] = CSE GUID, Properties[5] = GPO list (newline-separated)
$cse2Gpo = @{}
$cseStartEvents | ForEach-Object {
    $cse2Gpo[$_.Properties[0].Value] ??= $_.Properties[5].Value
}
#endregion

#region --- Calculate per-CSE durations from EID 5016/6016/7016 finish events ---
$lastFinishTime = $null
$cseTimings = $cseFinishEvents | ForEach-Object {
    $durationSec = [math]::Round($_.Properties[0].Value / 1000, 2)

    if (-not $lastFinishTime -or $_.TimeCreated -gt $lastFinishTime) {
        $lastFinishTime = $_.TimeCreated
    }

    $cseGuid = $_.Properties[3].Value
    $gpos    = ($cse2Gpo[$cseGuid] -split "`n" | Where-Object { $_.Trim() }) -join '; '

    [PSCustomObject]@{
        CSE         = [string]$_.Properties[2].Value
        DurationSec = $durationSec
        GPOs        = $gpos.Trim('[; ]')
    }
}

$gpTotalSec = $lastFinishTime ?
    [math]::Round(($lastFinishTime - $gpStartTime).TotalSeconds, 2) :
    $null

$topCSEs = $cseTimings | Sort-Object DurationSec -Descending | Select-Object -First 5
#endregion

#region --- Write results to registry ---
$regPath = 'HKLM:\Software\AirWatch\Extensions\DEXRecords\GPLoadTime'
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

$regValues = [ordered]@{
    Username           = $loggedOnUser
    GPStartTime        = $gpStartTime.ToString('yyyy-MM-dd HH:mm:ss')
    GPTotalDurationSec = $null -ne $gpTotalSec ? [string]$gpTotalSec : 'Unknown'
    CSETotalCount      = [string]$cseTimings.Count
    DataCollectedAt    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
}

for ($i = 0; $i -lt $topCSEs.Count; $i++) {
    $rank = $i + 1
    $regValues["TopCSE_${rank}_Name"]        = [string]$topCSEs[$i].CSE
    $regValues["TopCSE_${rank}_DurationSec"] = [string]$topCSEs[$i].DurationSec
    $regValues["TopCSE_${rank}_GPOs"]        = [string]$topCSEs[$i].GPOs
}

foreach ($key in $regValues.Keys) {
    Set-ItemProperty -Path $regPath -Name $key -Value $regValues[$key] -Type String -Force
}
#endregion

Write-Output "GP load time metrics recorded for '$loggedOnUser' at '$regPath' (Total: ${gpTotalSec}s, $($cseTimings.Count) CSEs)"
