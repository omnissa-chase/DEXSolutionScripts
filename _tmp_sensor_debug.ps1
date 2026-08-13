#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_duration_measure
    Data Type    : String
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-12
    Timeout      : One-time / run-once sensor only. Self-enforced budget 25 s, hard
                   ceiling 30 s (UEM max). MUST NOT be scheduled as a recurring sensor.
                   See GENERAL-SCRIPTS-SENSORS_RUNBOOK.md §10, "One-Time / Run-Once
                   Sensors".

    Mines Windows event logs directly for the most recent interactive logon of the
    active user and reports every phase timing as a single compact JSON object --
    no separate collector script, scheduled task, or registry cache required.

    This is the self-contained counterpart to Measure-LogonDuration.ps1 +
    logon_duration_summary.ps1 (which split the same work into a SYSTEM-scheduled
    collector writing a registry cache, plus a lightweight sensor reading it back).
    That split existed because a recurring sensor could never afford the event-log
    mining itself. Now that Workspace ONE Intelligence can trigger a genuine one-time
    sensor run, the mining can happen inside the sensor call itself. Both approaches
    are kept: use this one for a single on-demand pull, use Measure-LogonDuration.ps1
    when you want every logon recorded automatically via its own scheduled task.

    Phases captured (same event sources as Measure-LogonDuration.ps1):
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
    Printer mapping and scheduled-task coverage require those two optional logs to be
    enabled first -- run Enable-LogonAuditLogs.ps1 once per device image.

    SELF-ENFORCED DEADLINE
    Per RUNBOOK §10, a one-time sensor must never rely solely on the UEM ceiling to
    cut work off. A Stopwatch started at first event-log access checks the budget
    before each remaining phase; once exceeded, unattempted phases report -4 (see
    sentinels below) instead of running further queries, and "TimedOut" is set true.

    All *Ms and *Count keys are integers. Timestamps are ISO 8601 local time, or null
    when unavailable. Sentinel values for the *Ms and *Count keys:
      -1  Unknown      -- phase could not be measured
      -2  Not applicable -- feature not present on this device
      -3  Log disabled -- required event log is off; run Enable-LogonAuditLogs.ps1
      -4  Timed out    -- self-enforced deadline reached before this phase ran

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Tunables --
# Leaves a 5 s margin under the 30 s UEM one-time sensor ceiling for JSON serialization
# and process teardown.
$script:TimeoutSeconds = 25

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

function ConvertTo-Ms {
    param($Raw)
    if ($null -eq $Raw)   { return -1 }
    if ($Raw -is [string]) {
        switch ($Raw) {
            'N/A'         { return -2 }
            'LogDisabled' { return -3 }
            'TimedOut'    { return -4 }
            default       { return -1 }
        }
    }
    return [int][math]::Round([double]$Raw * 1000)
}

function ConvertTo-Count {
    param($Raw)
    if ($null -eq $Raw)   { return -1 }
    if ($Raw -is [string]) {
        switch ($Raw) {
            'N/A'         { return -2 }
            'LogDisabled' { return -3 }
            'TimedOut'    { return -4 }
            default {
                $v = 0
                if ([int]::TryParse($Raw, [ref]$v)) { return $v }
                return -1
            }
        }
    }
    return [int]$Raw
}

function ConvertTo-Iso {
    param($Raw)
    if ($Raw -is [datetime]) { return $Raw.ToString('s') }
    return $null
}

try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    function Test-BudgetExceeded { $sw.Elapsed.TotalSeconds -ge $script:TimeoutSeconds }
    $timedOut = $false

    # Win32_ComputerSystem.UserName reliably returns DOMAIN\username from SYSTEM context.
    $loggedOnUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
    if ([string]::IsNullOrEmpty($loggedOnUser)) {
        throw 'No interactive user detected.'
    }
    $username = $loggedOnUser.Split('\')[-1]

    $userSID = $null
    try {
        $userSID = ([System.Security.Principal.NTAccount]$loggedOnUser).Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
    } catch {}

    # EID 21 = user logon; EID 25 = session reconnect. Properties[0]=DOMAIN\user, [1]=SessionID.
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

    # Winlogon EID 7001 (Shell subscriber) is the closest reliable proxy for "desktop appeared".
    $shellReadyTime   = $null
    $totalLogonDurSec = $null
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

    # -- Group Policy total (EID 4001 -> EID 8001, the true end of all GP processing) --
    $gpDurationSec = $null
    $gpStartTime   = $null
    $gpStartEvent  = $null
    if (Test-BudgetExceeded) {
        $timedOut = $true; $gpDurationSec = 'TimedOut'
    } else {
        $gpXPath = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$loggedOnUser')]] and *[System[(EventID='4001')]]"
        $gpStartEvent = Get-WinEvent -ProviderName 'Microsoft-Windows-GroupPolicy' `
            -FilterXPath $gpXPath -MaxEvents 1 -ErrorAction SilentlyContinue

        if ($gpStartEvent) {
            $gpStartTime = $gpStartEvent.TimeCreated
            $gpEndXPath  = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$loggedOnUser')]] and *[System[(EventID='8001')]]"
            $gpEndCandidates = Get-WinEvent -ProviderName 'Microsoft-Windows-GroupPolicy' `
                -FilterXPath $gpEndXPath -MaxEvents 20 -ErrorAction SilentlyContinue

            # Group Policy stamps one ActivityId per processing cycle; pairing the newest
            # 8001 with the newest 4001 can straddle two cycles and go negative.
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
    }

    # -- GP Logon Scripts (EID 4018 -> EID 5018, ScriptType=1) --
    $gpScriptsDurSec = $null
    if (Test-BudgetExceeded) {
        $timedOut = $true; $gpScriptsDurSec = 'TimedOut'
    } elseif ($gpStartEvent) {
        $gpScriptStartXPath = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$loggedOnUser')] " +
            "and [Data[@Name='ScriptType'] and (Data='1')]] and *[System[(EventID='4018')]]"
        $gpScriptEndXPath   = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$loggedOnUser')] " +
            "and [Data[@Name='ScriptType'] and (Data='1')]] and *[System[(EventID='5018')]]"

        $gpScriptStart = Get-WinEvent -ProviderName 'Microsoft-Windows-GroupPolicy' `
            -FilterXPath $gpScriptStartXPath -MaxEvents 1 -ErrorAction SilentlyContinue
        $gpScriptEndCandidates = Get-WinEvent -ProviderName 'Microsoft-Windows-GroupPolicy' `
            -FilterXPath $gpScriptEndXPath -MaxEvents 20 -ErrorAction SilentlyContinue

        if ($gpScriptStart) {
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

    # -- Folder Redirection (first EID 501 -> last EID 502) --
    $folderRedirDurSec = $null
    if (Test-BudgetExceeded) {
        $timedOut = $true; $folderRedirDurSec = 'TimedOut'
    } elseif ($logonTime) {
        $frStart = Get-WinEvent -FilterHashtable @{
            ProviderName = 'Microsoft-Windows-Folder Redirection'; Id = 501
            StartTime = $logonTime; EndTime = $logonTime.AddMinutes(10)
        } -ErrorAction SilentlyContinue | Sort-Object TimeCreated | Select-Object -First 1

        $frEnd = Get-WinEvent -FilterHashtable @{
            ProviderName = 'Microsoft-Windows-Folder Redirection'; Id = 502
            StartTime = $logonTime; EndTime = $logonTime.AddMinutes(10)
        } -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending | Select-Object -First 1

        if ($frStart -and $frEnd) {
            $folderRedirDurSec = [math]::Round(($frEnd.TimeCreated - $frStart.TimeCreated).TotalSeconds, 2)
        }
    }

    # -- User Profile load (EID 1 -> EID 2), correlated by user SID with a session-id fallback --
    $profileDurationSec = $null
    if (Test-BudgetExceeded) {
        $timedOut = $true; $profileDurationSec = 'TimedOut'
    } elseif ($logonTime) {
        $profStartEvent = $null
        $profEndEvent   = $null
        if ($userSID) {
            $profStartXPath = "*[System[(EventID='1') and Security[@UserID='$userSID'] and " +
                "TimeCreated[@SystemTime>='$($logonTime.ToUniversalTime().ToString('o'))']]]"
            $profEndXPath   = "*[System[(EventID='2') and Security[@UserID='$userSID'] and " +
                "TimeCreated[@SystemTime>='$($logonTime.ToUniversalTime().ToString('o'))']]]"

            $profStartEvent = Get-WinEvent -ProviderName 'Microsoft-Windows-User Profile Service' `
                -FilterXPath $profStartXPath -MaxEvents 1 -ErrorAction SilentlyContinue
            $profEndEvent   = Get-WinEvent -ProviderName 'Microsoft-Windows-User Profile Service' `
                -FilterXPath $profEndXPath -MaxEvents 1 -ErrorAction SilentlyContinue
        }

        if ((-not $profStartEvent -or -not $profEndEvent) -and $null -ne $sessionId) {
            $profStartEvent = Get-WinEvent -FilterHashtable @{
                ProviderName = 'Microsoft-Windows-User Profile Service'; Id = 1; StartTime = $logonTime
            } -MaxEvents 100 -ErrorAction SilentlyContinue |
                Where-Object { $_.Properties[0].Value -eq $sessionId } |
                Sort-Object TimeCreated | Select-Object -First 1

            $profEndEvent = Get-WinEvent -FilterHashtable @{
                ProviderName = 'Microsoft-Windows-User Profile Service'; Id = 2; StartTime = $logonTime
            } -MaxEvents 100 -ErrorAction SilentlyContinue |
                Where-Object { $_.Properties[0].Value -eq $sessionId } |
                Sort-Object TimeCreated | Select-Object -First 1
        }

        if ($profStartEvent -and $profEndEvent) {
            $profileDurationSec = [math]::Round(($profEndEvent.TimeCreated - $profStartEvent.TimeCreated).TotalSeconds, 2)
        }
    }

    # -- FSLogix container attach (only if the Operational log exists) --
    $fslogixDurationSec = 'N/A'
    if (Test-BudgetExceeded) {
        $timedOut = $true; $fslogixDurationSec = 'TimedOut'
    } elseif ($logonTime -and (Get-WinEvent -ListLog 'Microsoft-FSLogix-Apps/Operational' -ErrorAction SilentlyContinue)) {
        $fsEvents = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-FSLogix-Apps/Operational'
            StartTime = $logonTime.AddSeconds(-30); EndTime = $logonTime.AddMinutes(5)
        } -ErrorAction SilentlyContinue | Sort-Object TimeCreated

        if ($fsEvents -and @($fsEvents).Count -ge 2) {
            $fsEvents = @($fsEvents)
            $fslogixDurationSec = [math]::Round(($fsEvents[-1].TimeCreated - $fsEvents[0].TimeCreated).TotalSeconds, 2)
        } elseif ($fsEvents -and @($fsEvents).Count -eq 1) {
            $fslogixDurationSec = 0
        }
    }

    # -- ActiveSetup (Shell-Core EID 62170 -> 62171), filtered to this user's SID --
    $activeSetupDurSec = 'N/A'
    if (Test-BudgetExceeded) {
        $timedOut = $true; $activeSetupDurSec = 'TimedOut'
    } elseif ($logonTime -and $userSID) {
        $asStart = Get-WinEvent -FilterHashtable @{
            ProviderName = 'Microsoft-Windows-Shell-Core'; Id = 62170
            StartTime = $logonTime; EndTime = $logonTime.AddMinutes(10)
        } -ErrorAction SilentlyContinue |
            Where-Object { $null -ne $_.UserId -and $_.UserId.Value -eq $userSID } |
            Sort-Object TimeCreated | Select-Object -First 1

        $asEnd = Get-WinEvent -FilterHashtable @{
            ProviderName = 'Microsoft-Windows-Shell-Core'; Id = 62171
            StartTime = $logonTime; EndTime = $logonTime.AddMinutes(10)
        } -ErrorAction SilentlyContinue |
            Where-Object { $null -ne $_.UserId -and $_.UserId.Value -eq $userSID } |
            Sort-Object TimeCreated -Descending | Select-Object -First 1

        if ($asStart -and $asEnd) {
            $activeSetupDurSec = [math]::Round(($asEnd.TimeCreated - $asStart.TimeCreated).TotalSeconds, 2)
        }
    }

    # -- AppX / UWP load (AppReadiness EID 209: From=2/To=0 start, From=1/To=2 end) --
    $appxDurSec = 'N/A'
    if (Test-BudgetExceeded) {
        $timedOut = $true; $appxDurSec = 'TimedOut'
    } elseif ($logonTime -and $userSID) {
        $appxEvents = Get-WinEvent -FilterHashtable @{
            ProviderName = 'Microsoft-Windows-AppReadiness'; Id = 209
            StartTime = $logonTime; EndTime = $logonTime.AddMinutes(10)
        } -ErrorAction SilentlyContinue |
            Where-Object { $_.Properties[0].Value -eq $userSID -or $_.Properties[0].Value -eq $username } |
            Sort-Object TimeCreated

        if ($appxEvents) {
            $appxEvents = @($appxEvents)
            $appxStart = $appxEvents | Where-Object { [int]$_.Properties[1].Value -eq 2 -and [int]$_.Properties[2].Value -eq 0 } | Select-Object -First 1
            $appxEnd   = $appxEvents | Where-Object { [int]$_.Properties[1].Value -eq 1 -and [int]$_.Properties[2].Value -eq 2 } | Select-Object -First 1

            if ($appxStart -and $appxEnd) {
                $appxDurSec = [math]::Round(($appxEnd.TimeCreated - $appxStart.TimeCreated).TotalSeconds, 2)
            } elseif ($appxEvents.Count -ge 2) {
                $appxDurSec = [math]::Round(($appxEvents[-1].TimeCreated - $appxEvents[0].TimeCreated).TotalSeconds, 2)
            }
        }
    }

    # -- Printer mapping (PrintService/Operational EID 300 -> 306; disabled by default) --
    $printerCount  = 'N/A'
    $printerDurSec = 'N/A'
    if (Test-BudgetExceeded) {
        $timedOut = $true; $printerCount = 'TimedOut'; $printerDurSec = 'TimedOut'
    } else {
        $printLogInfo = Get-WinEvent -ListLog 'Microsoft-Windows-PrintService/Operational' -ErrorAction SilentlyContinue
        if (-not $printLogInfo -or -not $printLogInfo.IsEnabled) {
            $printerCount = 'LogDisabled'; $printerDurSec = 'LogDisabled'
        } elseif ($logonTime) {
            $printStart = Get-WinEvent -FilterHashtable @{
                LogName = 'Microsoft-Windows-PrintService/Operational'; Id = 300
                StartTime = $logonTime; EndTime = $logonTime.AddMinutes(10)
            } -ErrorAction SilentlyContinue | Sort-Object TimeCreated

            $printEnd = Get-WinEvent -FilterHashtable @{
                LogName = 'Microsoft-Windows-PrintService/Operational'; Id = 306
                StartTime = $logonTime; EndTime = $logonTime.AddMinutes(10)
            } -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending

            if ($printStart) {
                $printStart = @($printStart)
                $printerCount = $printStart.Count
                if ($printEnd) {
                    $printEnd = @($printEnd)
                    $printerDurSec = [math]::Round(($printEnd[0].TimeCreated - $printStart[-1].TimeCreated).TotalSeconds, 2)
                }
            } else {
                $printerCount = 0; $printerDurSec = 0
            }
        }
    }

    # -- Scheduled tasks at logon (TaskScheduler/Operational EID 100 -> 102) --
    $logonTaskCount    = 'N/A'
    $logonTaskTotalSec = 'N/A'
    if (Test-BudgetExceeded) {
        $timedOut = $true; $logonTaskCount = 'TimedOut'; $logonTaskTotalSec = 'TimedOut'
    } else {
        $taskLogInfo = Get-WinEvent -ListLog 'Microsoft-Windows-TaskScheduler/Operational' -ErrorAction SilentlyContinue
        if (-not $taskLogInfo -or -not $taskLogInfo.IsEnabled) {
            $logonTaskCount = 'LogDisabled'; $logonTaskTotalSec = 'LogDisabled'
        } elseif ($logonTime) {
            $taskStartEvents = Get-WinEvent -FilterHashtable @{
                LogName = 'Microsoft-Windows-TaskScheduler/Operational'; Id = 100
                StartTime = $logonTime; EndTime = $logonTime.AddMinutes(5)
            } -ErrorAction SilentlyContinue

            $taskEndEvents = Get-WinEvent -FilterHashtable @{
                LogName = 'Microsoft-Windows-TaskScheduler/Operational'; Id = 102
                StartTime = $logonTime; EndTime = $logonTime.AddMinutes(5)
            } -ErrorAction SilentlyContinue

            if ($taskStartEvents) {
                $taskStartEvents = @($taskStartEvents)
                $logonTaskCount = $taskStartEvents.Count
                if ($taskEndEvents) {
                    $firstStart = $taskStartEvents | Sort-Object TimeCreated | Select-Object -First 1
                    $lastEnd    = @($taskEndEvents) | Sort-Object TimeCreated -Descending | Select-Object -First 1
                    $logonTaskTotalSec = [math]::Round(($lastEnd.TimeCreated - $firstStart.TimeCreated).TotalSeconds, 2)
                }
            } else {
                $logonTaskCount = 0; $logonTaskTotalSec = 0
            }
        }
    }

    $payload = [ordered]@{
        Status              = 'OK'
        TimedOut            = $timedOut
        Username            = $loggedOnUser
        LogonTime           = ConvertTo-Iso $logonTime
        ShellReadyTime      = ConvertTo-Iso $shellReadyTime
        DataCollectedAt     = ConvertTo-Iso (Get-Date)
        TotalMs             = ConvertTo-Ms $totalLogonDurSec
        GpStartTime         = ConvertTo-Iso $gpStartTime
        GpMs                = ConvertTo-Ms $gpDurationSec
        GpScriptsMs         = ConvertTo-Ms $gpScriptsDurSec
        FolderRedirectMs    = ConvertTo-Ms $folderRedirDurSec
        ProfileLoadMs       = ConvertTo-Ms $profileDurationSec
        FslogixAttachMs     = ConvertTo-Ms $fslogixDurationSec
        ActiveSetupMs       = ConvertTo-Ms $activeSetupDurSec
        AppxLoadMs          = ConvertTo-Ms $appxDurSec
        PrintersMappedCount = ConvertTo-Count $printerCount
        PrinterMappingMs    = ConvertTo-Ms $printerDurSec
        LogonTaskCount      = ConvertTo-Count $logonTaskCount
        LogonTaskTotalMs    = ConvertTo-Ms $logonTaskTotalSec
    }

    Write-Output (ConvertTo-Json -InputObject $payload -Compress)
    return
}
catch {
    Write-Output ('EXC: ' + $_.Exception.Message)
    Write-Output ('AT: ' + $_.InvocationInfo.PositionMessage)
    return
}
