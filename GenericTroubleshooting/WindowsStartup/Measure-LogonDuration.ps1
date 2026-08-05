#Requires -Version 5.1
<#
.SYNOPSIS
    Records key logon duration metrics for the currently logged-on interactive user
    to the registry. Designed to run as SYSTEM via a WorkspaceONE logon script trigger.

.DESCRIPTION
    Mines Windows event logs for the most recent interactive logon of the active user
    and captures the following phases:
      - Logon timestamp           (TerminalServices-LocalSessionManager EID 21/25)
      - Shell / Desktop ready     (Microsoft-Windows-Winlogon EID 7001)
      - Total logon duration      (EID 21 -> Winlogon EID 7001)
      - Group Policy total        (GP EID 4001 -> EID 8001, by PrincipalSamName)
      - GP Logon Scripts          (GP EID 4018 -> EID 5018, ScriptType=1)
      - Folder Redirection        (Microsoft-Windows-Folder Redirection EID 501 -> 502)
      - User Profile load         (User Profile Service EID 1 -> 2, by user SID)
      - FSLogix container attach  (FSLogix Operational log, if present)
      - ActiveSetup               (Microsoft-Windows-Shell-Core EID 62170 -> 62171)
      - AppX / UWP packages       (Microsoft-Windows-AppReadiness EID 209)
      - Printer mapping           (PrintService/Operational EID 300 -> 306, if log enabled)
      - Scheduled tasks at logon  (TaskScheduler/Operational EID 100 -> 102, if log enabled)

    All values are written as string registry values under:
      HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration

    Both parameters default to their matching environment variable, so UEM can configure
    the script by setting $env:DeployMode / $env:ConfigureLoggingFirst while a human or
    another script can still pass -DeployMode / -ConfigureLoggingFirst directly. An
    explicitly passed parameter always wins over the environment.

.PARAMETER DeployMode
    Defaults to $env:DeployMode, or RunNow when that is unset.

      RunNow              Measure immediately and write results to the registry.
                          Intended for direct WSO logon script execution.
      DeployScheduledTask Copy this script to C:\ProgramData\AirWatch\Extensions\DEXTools
                          and register a SYSTEM scheduled task that runs at every user
                          logon. Run once from WSO; thereafter the local task handles all
                          subsequent captures without consuming WSO agent time.
      ConfigureLogging    Enable the optional Windows event logs required for full metric
                          coverage (PrintService/Operational, TaskScheduler/Operational).
                          Safe to re-run — skips already-enabled logs.

    An unrecognised $env:DeployMode falls back to RunNow with a warning, so a typo in the
    UEM console degrades to a measurement instead of failing the deployment. An
    unrecognised -DeployMode argument throws, because a caller who typed it should know.

.PARAMETER ConfigureLoggingFirst
    Defaults to $true when $env:ConfigureLoggingFirst is true / 1 / yes / y, otherwise
    $false. Enables the optional event logs before running the requested DeployMode, so
    one deployment configures logging and starts measuring in a single pass. Anything
    unrecognised is false — this shells out to wevtutil, so it fails closed.

    Idempotent: a registry marker records success and later runs skip the work rather
    than calling wevtutil at every logon. DeployMode ConfigureLogging ignores the marker,
    because that is an explicit request rather than a first-run convenience.

.EXAMPLE
    .\Measure-LogonDuration.ps1 -DeployMode DeployScheduledTask -ConfigureLoggingFirst $true

    Enables the optional logs, then installs the per-logon scheduled task.

.EXAMPLE
    $env:DeployMode = 'RunNow'
    .\Measure-LogonDuration.ps1

    How UEM invokes the script: configuration arrives as an environment variable.

.NOTES
    PowerShell 5.1 compatible.

    Numeric and timestamp registry values are written using InvariantCulture. A device in
    a comma-decimal locale would otherwise record "42,5" and a Buddhist-calendar locale
    would record year 2569, either of which silently breaks every sensor that parses them.

    Sentinel strings written to the registry, and their meaning to a consuming sensor:
      Unknown      the phase could not be measured on this logon
      N/A          the feature is not present or did not run on this device
      LogDisabled  the required event log is turned off -- run DeployMode ConfigureLogging

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding()]
param(
    # Defaults are read from the environment because that is how UEM passes configuration.
    # Anything bound explicitly overrides them, since a default only applies when unbound.
    [ValidateSet('RunNow', 'DeployScheduledTask', 'ConfigureLogging')]
    [string]$DeployMode = $(
        if ([string]::IsNullOrWhiteSpace($env:DeployMode)) { 'RunNow' } else { $env:DeployMode.Trim() }
    ),

    [bool]$ConfigureLoggingFirst = $(
        $env:ConfigureLoggingFirst -and $env:ConfigureLoggingFirst.Trim() -in @('true', '1', 'yes', 'y')
    )
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

#region --- Script-level constants ---
$script:ToolsDir   = 'C:\ProgramData\AirWatch\Extensions\DEXTools'
$script:ScriptName = 'Measure-LogonDuration.ps1'
$script:TaskName   = 'DEXTools_MeasureLogonDuration'
$script:RegPath    = 'HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration'
$script:Version    = '1.1.0'
$script:ValidModes = @('RunNow', 'DeployScheduledTask', 'ConfigureLogging')
#endregion

#region --- Configuration normalisation ---
# ValidateSet is not applied to default values, so an unrecognised $env:DeployMode
# arrives here unchecked. Degrade to RunNow rather than failing the whole deployment.
if (-not $PSBoundParameters.ContainsKey('DeployMode')) {
    # -eq on strings is case-insensitive, so this also normalises casing to the canonical value.
    $matched = $script:ValidModes | Where-Object { $_ -eq $DeployMode } | Select-Object -First 1

    if ($matched) {
        $DeployMode = $matched
    }
    else {
        Write-Warning "Unrecognised `$env:DeployMode '$DeployMode'. Using 'RunNow'. Valid values: $($script:ValidModes -join ', ')"
        $DeployMode = 'RunNow'
    }
}
#endregion

#region --- Formatting helpers ---
# Registry values are consumed by sensors that parse them back into numbers and dates.
# Both sides must agree on culture or the round trip silently fails on non-en-US devices.
function Format-Metric {
    param($Value)
    if ($null -eq $Value)     { return 'Unknown' }
    if ($Value -is [string])  { return $Value }
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
}

function Format-Stamp {
    param($Value)
    if ($null -eq $Value) { return 'Unknown' }
    return $Value.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
}
#endregion

#region --- Measurement function ---
function Invoke-LogonDurationCapture {
    $ErrorActionPreference = 'SilentlyContinue'
    $ProgressPreference    = 'SilentlyContinue'

#region --- Identify the currently logged-on interactive user ---
# Win32_ComputerSystem.UserName reliably returns DOMAIN\username from SYSTEM context
$loggedOnUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName

if ([string]::IsNullOrEmpty($loggedOnUser)) {
    Write-Warning 'No interactive user detected. Exiting.'
    exit 1
}

$username = $loggedOnUser.Split('\')[-1]

# Resolve user SID — used for accurate User Profile Service event correlation
$userSID = $null
try {
    $userSID = ([System.Security.Principal.NTAccount]$loggedOnUser).Translate(
        [System.Security.Principal.SecurityIdentifier]
    ).Value
} catch {}
#endregion

#region --- Logon timestamp and Session ID (TerminalServices-LocalSessionManager EID 21) ---
# EID 21  = user logon;  Properties[0] = DOMAIN\user,  Properties[1] = SessionID
# EID 25  = session reconnect — we check both so a reconnect-triggered run still captures data
$tsEvent = Get-WinEvent -FilterHashtable @{
    ProviderName = 'Microsoft-Windows-TerminalServices-LocalSessionManager'
    Id           = @(21, 25)
} -MaxEvents 100 -ErrorAction SilentlyContinue |
    Where-Object { $_.Properties[0].Value -like "*\$username" } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 1

$logonTime = $null
$sessionId = $null
if ($tsEvent) {
    $logonTime = $tsEvent.TimeCreated
    $sessionId = [int]$tsEvent.Properties[1].Value
}
#endregion

#region --- Shell / Desktop Ready + Total Logon Duration ---
# Winlogon EID 7001 fires when the Shell subscriber (Explorer) begins executing
# the logon notification — the closest reliable proxy for "desktop appeared".
# Properties[0] = subscriber name ('Shell'), filtered to avoid other subscribers.
$shellReadyTime     = $null
$totalLogonDurSec   = $null

if ($logonTime) {
    $shellEvent = Get-WinEvent -FilterHashtable @{
        ProviderName = 'Microsoft-Windows-Winlogon'
        Id           = 7001
        StartTime    = $logonTime
        EndTime      = $logonTime.AddMinutes(10)
    } -ErrorAction SilentlyContinue |
        Where-Object { $_.Properties[0].Value -eq 'Shell' } |
        Sort-Object TimeCreated |
        Select-Object -First 1

    if ($shellEvent) {
        $shellReadyTime   = $shellEvent.TimeCreated
        $totalLogonDurSec = [math]::Round(($shellReadyTime - $logonTime).TotalSeconds, 2)
    }
}
#endregion

#region --- Group Policy total duration (EID 4001 start -> EID 8001 finish) ---
# EID 8001 = "Completed user logon policy processing" — the true end of all GP,
# not just individual CSE completions (EID 5016 which we used before).
$gpDurationSec  = $null
$gpStartTime    = $null
$gpStartEvent   = $null

$gpXPath = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$loggedOnUser')]] and *[System[(EventID='4001')]]"
$gpStartEvent = Get-WinEvent -ProviderName 'Microsoft-Windows-GroupPolicy' `
    -FilterXPath $gpXPath -MaxEvents 1 -ErrorAction SilentlyContinue

if ($gpStartEvent) {
    $gpStartTime    = $gpStartEvent.TimeCreated
    $gpEndXPath     = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$loggedOnUser')]] and *[System[(EventID='8001')]]"
    $gpEndCandidates = Get-WinEvent -ProviderName 'Microsoft-Windows-GroupPolicy' `
        -FilterXPath $gpEndXPath -MaxEvents 20 -ErrorAction SilentlyContinue

    # Group Policy stamps one ActivityId per processing cycle. Taking the newest 8001 to
    # pair with the newest 4001 can straddle two different cycles and produce a duration
    # that is wrong, or negative.
    $gpEndEvent = $gpEndCandidates |
        Where-Object { $null -ne $_.ActivityId -and $_.ActivityId -eq $gpStartEvent.ActivityId } |
        Select-Object -First 1

    if (-not $gpEndEvent) {
        $gpEndEvent = $gpEndCandidates |
            Where-Object { $_.TimeCreated -ge $gpStartTime } |
            Sort-Object TimeCreated | Select-Object -First 1
    }

    if ($gpEndEvent) {
        $gpSpan = ($gpEndEvent.TimeCreated - $gpStartEvent.TimeCreated).TotalSeconds
        if ($gpSpan -ge 0) { $gpDurationSec = [math]::Round($gpSpan, 2) }
    }
}
#endregion

#region --- GP Logon Scripts duration (EID 4018 start -> EID 5018 finish, ScriptType=1) ---
# ScriptType=1 = logon scripts; ScriptType=2 = logoff scripts.
$gpScriptsDurSec = $null

if ($gpStartEvent) {
    $gpScriptStartXPath = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$loggedOnUser')] " +
        "and [Data[@Name='ScriptType'] and (Data='1')]] and *[System[(EventID='4018')]]"
    $gpScriptEndXPath   = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$loggedOnUser')] " +
        "and [Data[@Name='ScriptType'] and (Data='1')]] and *[System[(EventID='5018')]]"

    $gpScriptStart = Get-WinEvent -ProviderName 'Microsoft-Windows-GroupPolicy' `
        -FilterXPath $gpScriptStartXPath -MaxEvents 1 -ErrorAction SilentlyContinue
    $gpScriptEndCandidates = Get-WinEvent -ProviderName 'Microsoft-Windows-GroupPolicy' `
        -FilterXPath $gpScriptEndXPath   -MaxEvents 20 -ErrorAction SilentlyContinue

    if ($gpScriptStart) {
        # Same cycle-straddling risk as the 4001/8001 pair above.
        $gpScriptEnd = $gpScriptEndCandidates |
            Where-Object { $null -ne $_.ActivityId -and $_.ActivityId -eq $gpScriptStart.ActivityId } |
            Select-Object -First 1

        if (-not $gpScriptEnd) {
            $gpScriptEnd = $gpScriptEndCandidates |
                Where-Object { $_.TimeCreated -ge $gpScriptStart.TimeCreated } |
                Sort-Object TimeCreated | Select-Object -First 1
        }

        if ($gpScriptEnd) {
            $gpScriptSpan = ($gpScriptEnd.TimeCreated - $gpScriptStart.TimeCreated).TotalSeconds
            if ($gpScriptSpan -ge 0) { $gpScriptsDurSec = [math]::Round($gpScriptSpan, 2) }
        }
    }
}
#endregion

#region --- Folder Redirection duration (EID 501 start -> EID 502 finish) ---
# Spans from first EID 501 to last EID 502 in the Folder Redirection log after logon.
# Multiple 501/502 pairs are expected (one per redirected folder); we measure the total span.
$folderRedirDurSec = $null

if ($logonTime) {
    $frStart = Get-WinEvent -FilterHashtable @{
        ProviderName = 'Microsoft-Windows-Folder Redirection'
        Id           = 501
        StartTime    = $logonTime
        EndTime      = $logonTime.AddMinutes(10)
    } -ErrorAction SilentlyContinue | Sort-Object TimeCreated | Select-Object -First 1

    $frEnd   = Get-WinEvent -FilterHashtable @{
        ProviderName = 'Microsoft-Windows-Folder Redirection'
        Id           = 502
        StartTime    = $logonTime
        EndTime      = $logonTime.AddMinutes(10)
    } -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending | Select-Object -First 1

    if ($frStart -and $frEnd) {
        $folderRedirDurSec = [math]::Round(($frEnd.TimeCreated - $frStart.TimeCreated).TotalSeconds, 2)
    }
}
#endregion

#region --- User Profile load duration (User Profile Service EID 1 start -> EID 2 finish) ---
# Primary: correlate via user SID in the Security element (Security[@UserID='S-1-5-...']).
# Fallback: correlate via Session ID in Properties[0] if SID resolution failed.
$profileDurationSec = $null

if ($logonTime) {
    if ($userSID) {
        $profStartXPath = "*[System[(EventID='1') and Security[@UserID='$userSID'] and " +
            "TimeCreated[@SystemTime>='$($logonTime.ToUniversalTime().ToString('o'))']]]" 
        $profEndXPath   = "*[System[(EventID='2') and Security[@UserID='$userSID'] and " +
            "TimeCreated[@SystemTime>='$($logonTime.ToUniversalTime().ToString('o'))']]]" 

        $profStartEvent = Get-WinEvent -ProviderName 'Microsoft-Windows-User Profile Service' `
            -FilterXPath $profStartXPath -MaxEvents 1 -ErrorAction SilentlyContinue
        $profEndEvent   = Get-WinEvent -ProviderName 'Microsoft-Windows-User Profile Service' `
            -FilterXPath $profEndXPath   -MaxEvents 1 -ErrorAction SilentlyContinue
    }

    # Fallback to Session ID if SID lookup yielded nothing
    if ((-not $profStartEvent -or -not $profEndEvent) -and $null -ne $sessionId) {
        $profStartEvent = Get-WinEvent -FilterHashtable @{
            ProviderName = 'Microsoft-Windows-User Profile Service'
            Id           = 1
            StartTime    = $logonTime
        } -MaxEvents 100 -ErrorAction SilentlyContinue |
            Where-Object { $_.Properties[0].Value -eq $sessionId } |
            Sort-Object TimeCreated | Select-Object -First 1

        $profEndEvent   = Get-WinEvent -FilterHashtable @{
            ProviderName = 'Microsoft-Windows-User Profile Service'
            Id           = 2
            StartTime    = $logonTime
        } -MaxEvents 100 -ErrorAction SilentlyContinue |
            Where-Object { $_.Properties[0].Value -eq $sessionId } |
            Sort-Object TimeCreated | Select-Object -First 1
    }

    if ($profStartEvent -and $profEndEvent) {
        $profileDurationSec = [math]::Round(
            ($profEndEvent.TimeCreated - $profStartEvent.TimeCreated).TotalSeconds, 2
        )
    }
}
#endregion

#region --- FSLogix profile container attach duration ---
# Only attempted if the FSLogix Operational log exists on this machine.
# Measures span from first to last FSLogix event in a 5-minute window after logon.
$fslogixDurationSec = 'N/A'

$fslogixLogExists = Get-WinEvent -ListLog 'Microsoft-FSLogix-Apps/Operational' -ErrorAction SilentlyContinue
if ($fslogixLogExists -and $logonTime) {
    $fsEvents = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-FSLogix-Apps/Operational'
        StartTime = $logonTime.AddSeconds(-30)
        EndTime   = $logonTime.AddMinutes(5)
    } -ErrorAction SilentlyContinue | Sort-Object TimeCreated

    if ($fsEvents -and $fsEvents.Count -ge 2) {
        $fslogixDurationSec = [math]::Round(
            ($fsEvents[-1].TimeCreated - $fsEvents[0].TimeCreated).TotalSeconds, 2
        )
    } elseif ($fsEvents -and $fsEvents.Count -eq 1) {
        $fslogixDurationSec = '0'
    }
}
#endregion

#region --- ActiveSetup duration (Shell-Core EID 62170 start -> EID 62171 finish) ---
# Measures time spent running per-user COM component registrations at logon.
# Filtered to the current user via the Security/UserID attribute (UserId property).
$activeSetupDurSec = 'N/A'

if ($logonTime -and $userSID) {
    $asStart = Get-WinEvent -FilterHashtable @{
        ProviderName = 'Microsoft-Windows-Shell-Core'
        Id           = 62170
        StartTime    = $logonTime
        EndTime      = $logonTime.AddMinutes(10)
    } -ErrorAction SilentlyContinue |
        Where-Object { $null -ne $_.UserId -and $_.UserId.Value -eq $userSID } |
        Sort-Object TimeCreated | Select-Object -First 1

    $asEnd = Get-WinEvent -FilterHashtable @{
        ProviderName = 'Microsoft-Windows-Shell-Core'
        Id           = 62171
        StartTime    = $logonTime
        EndTime      = $logonTime.AddMinutes(10)
    } -ErrorAction SilentlyContinue |
        Where-Object { $null -ne $_.UserId -and $_.UserId.Value -eq $userSID } |
        Sort-Object TimeCreated -Descending | Select-Object -First 1

    if ($asStart -and $asEnd) {
        $activeSetupDurSec = [math]::Round(($asEnd.TimeCreated - $asStart.TimeCreated).TotalSeconds, 2)
    }
}
#endregion

#region --- AppX / UWP package load duration (AppReadiness EID 209) ---
# EID 209 fires twice per logon for UWP state transitions:
#   Start: Properties[1]=2, Properties[2]=0  (From=2 To=0 — packages begin loading)
#   End:   Properties[1]=1, Properties[2]=2  (From=1 To=2 — packages ready)
# Properties[0] = User (SID or username). Returns 'N/A' if AppReadiness is absent.
$appxDurSec = 'N/A'

if ($logonTime -and $userSID) {
    $appxEvents = Get-WinEvent -FilterHashtable @{
        ProviderName = 'Microsoft-Windows-AppReadiness'
        Id           = 209
        StartTime    = $logonTime
        EndTime      = $logonTime.AddMinutes(10)
    } -ErrorAction SilentlyContinue |
        Where-Object { $_.Properties[0].Value -eq $userSID -or $_.Properties[0].Value -eq $username } |
        Sort-Object TimeCreated

    if ($appxEvents) {
        $appxStart = $appxEvents | Where-Object { [int]$_.Properties[1].Value -eq 2 -and [int]$_.Properties[2].Value -eq 0 } | Select-Object -First 1
        $appxEnd   = $appxEvents | Where-Object { [int]$_.Properties[1].Value -eq 1 -and [int]$_.Properties[2].Value -eq 2 } | Select-Object -First 1

        if ($appxStart -and $appxEnd) {
            $appxDurSec = [math]::Round(($appxEnd.TimeCreated - $appxStart.TimeCreated).TotalSeconds, 2)
        } elseif (@($appxEvents).Count -ge 2) {
            # Fallback: span of all user EID 209 events in window
            $appxDurSec = [math]::Round(($appxEvents[-1].TimeCreated - $appxEvents[0].TimeCreated).TotalSeconds, 2)
        }
    }
}
#endregion

#region --- Printer mapping duration (PrintService/Operational EID 300 -> EID 306) ---
# PrintService/Operational is disabled by default — reports 'LogDisabled' if so.
# EID 300 = printer connection started, EID 306 = printer connection completed.
# Records count of connections and total span from first 300 to last 306.
$printerCount  = 'N/A'
$printerDurSec = 'N/A'

$printLogInfo = Get-WinEvent -ListLog 'Microsoft-Windows-PrintService/Operational' -ErrorAction SilentlyContinue
if (-not $printLogInfo -or -not $printLogInfo.IsEnabled) {
    $printerCount  = 'LogDisabled'
    $printerDurSec = 'LogDisabled'
} elseif ($logonTime) {
    $printStart = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-PrintService/Operational'
        Id        = 300
        StartTime = $logonTime
        EndTime   = $logonTime.AddMinutes(10)
    } -ErrorAction SilentlyContinue | Sort-Object TimeCreated

    $printEnd = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-PrintService/Operational'
        Id        = 306
        StartTime = $logonTime
        EndTime   = $logonTime.AddMinutes(10)
    } -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending

    if ($printStart) {
        $printerCount = [string](@($printStart)).Count
        if ($printEnd) {
            $printerDurSec = [math]::Round(
                ((@($printEnd) | Select-Object -First 1).TimeCreated - (@($printStart) | Select-Object -First 1).TimeCreated).TotalSeconds, 2
            )
        }
    } else {
        $printerCount  = '0'
        $printerDurSec = '0'
    }
}
#endregion

#region --- Scheduled tasks at logon (TaskScheduler/Operational EID 100 -> EID 102) ---
# Counts tasks that launched in the first 5 minutes after logon and records the span
# from the first task start (EID 100) to the last task completion (EID 102).
# TaskScheduler/Operational is usually enabled; reports 'LogDisabled' if not.
$logonTaskCount    = 'N/A'
$logonTaskTotalSec = 'N/A'

$taskLogInfo = Get-WinEvent -ListLog 'Microsoft-Windows-TaskScheduler/Operational' -ErrorAction SilentlyContinue
if (-not $taskLogInfo -or -not $taskLogInfo.IsEnabled) {
    $logonTaskCount    = 'LogDisabled'
    $logonTaskTotalSec = 'LogDisabled'
} elseif ($logonTime) {
    $taskStartEvents = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-TaskScheduler/Operational'
        Id        = 100
        StartTime = $logonTime
        EndTime   = $logonTime.AddMinutes(5)
    } -ErrorAction SilentlyContinue

    $taskEndEvents = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-TaskScheduler/Operational'
        Id        = 102
        StartTime = $logonTime
        EndTime   = $logonTime.AddMinutes(5)
    } -ErrorAction SilentlyContinue

    if ($taskStartEvents) {
        $logonTaskCount = [string](@($taskStartEvents)).Count
        if ($taskEndEvents) {
            $firstStart        = @($taskStartEvents) | Sort-Object TimeCreated | Select-Object -First 1
            $lastEnd           = @($taskEndEvents)   | Sort-Object TimeCreated -Descending | Select-Object -First 1
            $logonTaskTotalSec = [string][math]::Round(($lastEnd.TimeCreated - $firstStart.TimeCreated).TotalSeconds, 2)
        }
    } else {
        $logonTaskCount    = '0'
        $logonTaskTotalSec = '0'
    }
}
#endregion

#region --- Write results to registry ---
$regPath = $script:RegPath
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

$regValues = [ordered]@{
    Username                  = $loggedOnUser
    LogonTime                 = Format-Stamp  $logonTime
    ShellReadyTime            = Format-Stamp  $shellReadyTime
    TotalLogonDurationSec     = Format-Metric $totalLogonDurSec
    GPStartTime               = Format-Stamp  $gpStartTime
    GPDurationSec             = Format-Metric $gpDurationSec
    GPScriptsDurationSec      = if ($null -ne $gpScriptsDurSec)   { Format-Metric $gpScriptsDurSec }   else { 'N/A' }
    FolderRedirDurationSec    = if ($null -ne $folderRedirDurSec) { Format-Metric $folderRedirDurSec } else { 'N/A' }
    ProfileLoadDurationSec    = Format-Metric $profileDurationSec
    FSLogixAttachDurationSec  = Format-Metric $fslogixDurationSec
    ActiveSetupDurationSec    = Format-Metric $activeSetupDurSec
    AppXLoadDurationSec       = Format-Metric $appxDurSec
    PrintersMappedCount       = Format-Metric $printerCount
    PrinterMappingDurationSec = Format-Metric $printerDurSec
    LogonTaskCount            = Format-Metric $logonTaskCount
    LogonTaskTotalDurationSec = Format-Metric $logonTaskTotalSec
    DataCollectedAt           = Format-Stamp  (Get-Date)
    CollectorVersion          = $script:Version
}

# Registry writes are the one place a silenced error would be invisible and fatal to
# every downstream sensor, so surface a failure here rather than reporting success.
$writeFailures = 0
foreach ($key in $regValues.Keys) {
    Set-ItemProperty -Path $regPath -Name $key -Value $regValues[$key] -Type String -Force -ErrorAction SilentlyContinue -ErrorVariable writeErr
    if ($writeErr) { $writeFailures++ }
}

if ($writeFailures -gt 0) {
    Write-Warning "$writeFailures of $($regValues.Count) registry values could not be written to '$regPath'."
}
#endregion

# Reporting success after a failed write would leave an operator believing sensors
# have fresh data when the key is empty or stale. Say what actually happened.
if ($writeFailures -eq 0) {
    Write-Output "Logon duration metrics recorded for '$loggedOnUser' at '$regPath'"
}
elseif ($writeFailures -lt $regValues.Count) {
    Write-Output "Logon duration metrics PARTIALLY recorded for '$loggedOnUser' at '$regPath' ($($regValues.Count - $writeFailures) of $($regValues.Count) values)."
}
else {
    Write-Output "Logon duration metrics NOT recorded for '$loggedOnUser'. No values could be written to '$regPath' (elevation required?)."
}
} # end Invoke-LogonDurationCapture
#endregion

#region --- Scheduled Task deployment function ---
function Install-LogonDurationTask {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        Write-Warning 'Cannot determine script path ($PSCommandPath is empty). Run from a saved .ps1 file.'
        return
    }

    # Ensure tools directory exists
    if (-not (Test-Path $script:ToolsDir)) {
        New-Item -Path $script:ToolsDir -ItemType Directory -Force | Out-Null
    }

    # Copy this script to the permanent tools location
    $destScript = Join-Path $script:ToolsDir $script:ScriptName
    Copy-Item -Path $PSCommandPath -Destination $destScript -Force

    # Passed explicitly so the task can never inherit a machine-level environment variable
    # and re-deploy or re-configure at every logon. Logging setup is a deployment-time
    # concern, not a per-logon one. -Command rather than -File because -File would pass
    # $false as the literal string '$false', which a [bool] parameter reads as true.
    $taskCommand = "& '$destScript' -DeployMode RunNow -ConfigureLoggingFirst `$false"
    $action    = New-ScheduledTaskAction `
        -Execute  'powershell.exe' `
        -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$taskCommand`""

    # AtLogon trigger for any user; 30-second delay ensures event log entries are flushed
    $trigger         = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Delay   = 'PT30S'

    $principal = New-ScheduledTaskPrincipal `
        -UserId    'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel  Highest

    $settings  = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -MultipleInstances  IgnoreNew `
        -Hidden

    # Remove existing task of the same name before re-registering
    $existing = Get-ScheduledTask -TaskName $script:TaskName -TaskPath '\DEXTools\' -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $script:TaskName -TaskPath '\DEXTools\' -Confirm:$false
    }

    Register-ScheduledTask `
        -TaskName    $script:TaskName `
        -TaskPath    '\DEXTools\' `
        -Action      $action `
        -Trigger     $trigger `
        -Principal   $principal `
        -Settings    $settings `
        -Description 'Captures logon duration metrics to HKLM registry at each user logon. Deployed by WorkspaceONE.' | Out-Null

    Write-Output "Scheduled task '\DEXTools\$($script:TaskName)' registered."
    Write-Output "Worker script saved to: $destScript"
}
#endregion

#region --- Logging configuration function ---
function Enable-DEXAuditLogs {
    <#
    .SYNOPSIS
        Enables the optional Windows event logs used by Measure-LogonDuration.
        Safe to run multiple times — already-enabled logs are reported and skipped.
    .PARAMETER Force
        Runs even when the completion marker is already set. Used by DeployMode
        ConfigureLogging, where the admin has explicitly asked for the work.
    #>
    [CmdletBinding()]
    param([switch]$Force)

    if (-not $Force) {
        $marker = (Get-ItemProperty -Path $script:RegPath -Name 'AuditLogsConfiguredAt' -ErrorAction SilentlyContinue).AuditLogsConfiguredAt
        if (-not [string]::IsNullOrWhiteSpace($marker)) {
            Write-Output "Audit logs already configured at $marker. Skipping."
            return
        }
    }

    # Logs that are disabled by default but required for full metric coverage
    $targets = @(
        [PSCustomObject]@{
            LogName     = 'Microsoft-Windows-PrintService/Operational'
            Description = 'Printer mapping duration (EID 300 start, EID 306 finish)'
        }
        [PSCustomObject]@{
            LogName     = 'Microsoft-Windows-TaskScheduler/Operational'
            Description = 'Logon scheduled task duration (EID 100 start, EID 102 finish)'
        }
    )

    Write-Output ''
    Write-Output '=== DEX Audit Log Configuration ==='

    foreach ($target in $targets) {
        $log = Get-WinEvent -ListLog $target.LogName -ErrorAction SilentlyContinue

        if (-not $log) {
            Write-Output "  [NOT FOUND] $($target.LogName)"
            Write-Output "              This log does not exist on this system. Skipping."
            continue
        }

        if ($log.IsEnabled) {
            Write-Output "  [OK]        $($target.LogName)"
            Write-Output "              Already enabled $($target.Description)"
        } else {
            try {
                wevtutil.exe sl $target.LogName /e:true 2>&1 | Out-Null
                # Re-query to confirm
                $verify = Get-WinEvent -ListLog $target.LogName -ErrorAction SilentlyContinue
                if ($verify.IsEnabled) {
                    Write-Output "  [ENABLED]   $($target.LogName)"
                    Write-Output "              Now enabled $($target.Description)"
                } else {
                    Write-Output "  [FAILED]    $($target.LogName)"
                    Write-Output "              wevtutil returned success but log still reports disabled."
                }
            } catch {
                Write-Output "  [ERROR]     $($target.LogName)"
                Write-Output "              $_"
            }
        }
        Write-Output ''
    }

    # Marker makes ConfigureLoggingFirst a one-time cost rather than a wevtutil call
    # on every single logon.
    if (-not (Test-Path $script:RegPath)) {
        New-Item -Path $script:RegPath -Force | Out-Null
    }
    Set-ItemProperty -Path $script:RegPath -Name 'AuditLogsConfiguredAt' `
        -Value (Format-Stamp (Get-Date)) -Type String -Force -ErrorAction SilentlyContinue

    Write-Output '=== Configuration complete ==='
    Write-Output 'Re-run with -DeployMode RunNow or DeployScheduledTask (or the matching $env:DeployMode) when ready.'
}
#endregion

#region --- Entry point ---
switch ($DeployMode) {
    'RunNow' {
        if ($ConfigureLoggingFirst) { Enable-DEXAuditLogs }
        Invoke-LogonDurationCapture
    }
    'DeployScheduledTask' {
        if ($ConfigureLoggingFirst) { Enable-DEXAuditLogs }
        Install-LogonDurationTask
    }
    'ConfigureLogging' {
        # Explicit request, so the marker does not suppress it.
        Enable-DEXAuditLogs -Force
    }
}

exit 0
#endregion