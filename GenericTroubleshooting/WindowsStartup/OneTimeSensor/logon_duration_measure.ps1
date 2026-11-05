#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : logon_duration_measure
    Data Type    : String
    Architecture : Any (x86/x64/ARM64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05 (1.1.1: ShellReadyTime from the session's explorer.exe
                   creation time, Winlogon 7001 only as a fallback, and the Group Policy
                   4001 bounded to the logon window instead of the user's newest cycle;
                   1.1.0: every event query goes through the .NET
                   EventLogReader with an explicit log name instead of Get-WinEvent,
                   which throws "Cannot marshal 'parameter #8'" under the PowerShell
                   7.2 engine Hub embeds on ARM64 and enumerates provider metadata on
                   every engine when given -ProviderName without a log; see
                   TEST-VALIDATION.md 13.2.v and 13.2.z)
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

    Phases captured (same event sources as Measure-LogonDuration.ps1), with the log
    each one is read from:
      - Logon timestamp           (TerminalServices-LocalSessionManager/Operational EID 21/25)
      - Shell / Desktop ready     (session explorer.exe creation time; Winlogon EID 7001 fallback)
      - Total logon duration      (EID 21 -> shell ready)
      - Group Policy total        (GroupPolicy/Operational EID 4001 -> 8001, by PrincipalSamName)
      - GP Logon Scripts          (GroupPolicy/Operational EID 4018 -> 5018, ScriptType=1)
      - Folder Redirection        (Folder Redirection/Operational EID 501 -> 502)
      - User Profile load         (User Profile Service/Operational EID 1 -> 2, by user SID;
                                   provider is "User Profiles Service", the log is
                                   "User Profile Service/Operational" -- fixed 2026-11-03)
      - FSLogix container attach  (FSLogix Operational log, if present)
      - ActiveSetup               (Shell-Core/Operational EID 62170 -> 62171)
      - AppX / UWP packages       (AppReadiness/Admin EID 209)
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

#region --- Event log access (.NET EventLogReader; no Get-WinEvent) ---
# Returns event records newest first, like Get-WinEvent, from one named log through an
# XPath filter. The records carry the members this file uses (TimeCreated, Id,
# ProviderName, Properties, UserId, ActivityId). Errors (missing channel, access denied)
# yield no output rather than throwing, matching -ErrorAction SilentlyContinue.
function Get-DexEvent {
    param(
        [Parameter(Mandatory = $true)][string]$LogName,
        [int[]]$Id,
        [string]$ProviderName,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [string]$UserSid,
        [string]$XPath,
        [int]$MaxEvents = 0,
        [switch]$Oldest
    )
    $sys = New-Object System.Collections.Generic.List[string]
    if ($Id)           { $sys.Add('(' + (@($Id | ForEach-Object { "EventID=$_" }) -join ' or ') + ')') }
    if ($ProviderName) { $sys.Add("Provider[@Name='$ProviderName']") }
    if ($UserSid)      { $sys.Add("Security[@UserID='$UserSid']") }
    # Whole-second bounds, as Get-WinEvent's StartTime/EndTime are: the profile and
    # Winlogon events of a logon land a few hundred ms before the session manager's
    # EID 21 that anchors the window, and an exact bound would drop them.
    $when = New-Object System.Collections.Generic.List[string]
    if ($PSBoundParameters.ContainsKey('StartTime')) {
        $t = $StartTime.ToUniversalTime(); $t = $t.AddTicks(-($t.Ticks % [TimeSpan]::TicksPerSecond))
        $when.Add("@SystemTime>='" + $t.ToString('o') + "'")
    }
    if ($PSBoundParameters.ContainsKey('EndTime')) {
        $t = $EndTime.ToUniversalTime(); if ($t.Ticks % [TimeSpan]::TicksPerSecond) { $t = $t.AddTicks([TimeSpan]::TicksPerSecond - ($t.Ticks % [TimeSpan]::TicksPerSecond)) }
        $when.Add("@SystemTime<='" + $t.ToString('o') + "'")
    }
    if ($when.Count -gt 0) { $sys.Add('TimeCreated[' + ($when -join ' and ') + ']') }
    $query = if ($XPath) { $XPath } elseif ($sys.Count -gt 0) { '*[System[' + ($sys -join ' and ') + ']]' } else { '*' }

    $out    = New-Object System.Collections.Generic.List[object]
    $reader = $null
    try {
        $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery($LogName, [System.Diagnostics.Eventing.Reader.PathType]::LogName, $query)
        $q.ReverseDirection = -not $Oldest
        $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($q)
        while (($MaxEvents -le 0 -or $out.Count -lt $MaxEvents) -and ($null -ne ($record = $reader.ReadEvent()))) { $out.Add($record) }
    } catch { }
    finally { if ($reader) { $reader.Dispose() } }
    return $out.ToArray()
}

# Log configuration (IsEnabled and friends) without Get-WinEvent -ListLog; $null when
# the channel does not exist on this device.
function Get-DexEventLog {
    param([Parameter(Mandatory = $true)][string]$LogName)
    try { return New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration($LogName) } catch { return $null }
}
#endregion

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
    $tsEvent = Get-DexEvent -LogName 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational' `
        -Id 21, 25 -MaxEvents 100 |
        Where-Object { $_.Properties[0].Value -like "*\$username" } |
        Sort-Object TimeCreated -Descending |
        Select-Object -First 1

    $logonTime = $null
    $sessionId = $null
    if ($tsEvent) {
        $logonTime = $tsEvent.TimeCreated
        $sessionId = [int]$tsEvent.Properties[1].Value
    }

    # Shell-ready is the creation time of the session's explorer.exe (the earliest one; a shell
    # restart spawns another). Winlogon 7001 is only a fallback: on Windows 11 it carries
    # [1, <SID>], fires before TS-LSM 21 and never names the 'Shell' subscriber.
    $shellReadyTime   = $null
    $totalLogonDurSec = $null
    if ($logonTime) {
        try {
            $explorerStart = $null
            if ($null -ne $sessionId) {
                foreach ($proc in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)) {
                    if ($null -eq $proc.CreationDate -or [int]$proc.SessionId -ne $sessionId) { continue }
                    if ($null -eq $explorerStart -or $proc.CreationDate -lt $explorerStart) { $explorerStart = $proc.CreationDate }
                }
            }
            if ($explorerStart -and $explorerStart -ge $logonTime) {
                $shellReadyTime = $explorerStart
            }
            else {
                $shellEvent = Get-DexEvent -LogName 'System' -ProviderName 'Microsoft-Windows-Winlogon' -Id 7001 `
                    -StartTime $logonTime -EndTime $logonTime.AddMinutes(10) |
                    Where-Object { $_.Properties[0].Value -eq 'Shell' } |
                    Sort-Object TimeCreated |
                    Select-Object -First 1
                if ($shellEvent) { $shellReadyTime = $shellEvent.TimeCreated }
            }
            if ($shellReadyTime) {
                $totalLogonDurSec = [math]::Round(($shellReadyTime - $logonTime).TotalSeconds, 2)
            }
        } catch {}
    }

    # -- Group Policy total (EID 4001 -> EID 8001, the true end of all GP processing) --
    $gpLog         = 'Microsoft-Windows-GroupPolicy/Operational'
    $gpDurationSec = $null
    $gpStartTime   = $null
    $gpStartEvent  = $null
    if (Test-BudgetExceeded) {
        $timedOut = $true; $gpDurationSec = 'TimedOut'
    } else {
        try {
            # Bounded to the logon window: the user's newest 4001 can be a background refresh cycle (both
            # lab VMs reported one exactly ten minutes after logon, TEST-VALIDATION.md 8.3), so only a
            # cycle that started within a minute before the logon and ten minutes after it counts, oldest
            # first because the logon's own processing is the first cycle in that window. The 8001 that
            # closes it is looked for in the thirty minutes after the 4001, ActivityId match first.            $gpWindow = ''
            if ($logonTime) {
                $gpWindow = " and TimeCreated[@SystemTime>='" + $logonTime.AddMinutes(-1).ToUniversalTime().ToString('o') + "' and @SystemTime<='" + $logonTime.AddMinutes(10).ToUniversalTime().ToString('o') + "']"
            }
            $gpXPath = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$loggedOnUser')]] and *[System[(EventID='4001')$gpWindow]]"
            $gpStartEvent = Get-DexEvent -LogName $gpLog -XPath $gpXPath -MaxEvents 1 -Oldest:([bool]$logonTime) | Select-Object -First 1

            if ($gpStartEvent) {
                $gpStartTime = $gpStartEvent.TimeCreated
                $gpEndXPath  = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$loggedOnUser')]] and *[System[(EventID='8001') and TimeCreated[@SystemTime>='" + $gpStartTime.ToUniversalTime().ToString('o') + "' and @SystemTime<='" + $gpStartTime.AddMinutes(30).ToUniversalTime().ToString('o') + "']]]"
                $gpEndCandidates = @(Get-DexEvent -LogName $gpLog -XPath $gpEndXPath -MaxEvents 20 -Oldest)

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
            elseif ($logonTime) {
                # No user cycle inside the logon window: on a workgroup device that is N/A
                # (no domain policy at logon; the lab VMs log 4001/8001 only as later refreshes).
                if (-not [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain) { $gpDurationSec = 'N/A' }
            }
        } catch {}
    }

    # -- GP Logon Scripts (EID 4018 -> EID 5018, ScriptType=1) --
    $gpScriptsDurSec = $null
    if (Test-BudgetExceeded) {
        $timedOut = $true; $gpScriptsDurSec = 'TimedOut'
    } elseif ($gpStartEvent) {
        try {
            $gpScriptStartXPath = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$loggedOnUser')] " +
                "and [Data[@Name='ScriptType'] and (Data='1')]] and *[System[(EventID='4018')]]"
            $gpScriptEndXPath   = "*[EventData[Data[@Name='PrincipalSamName'] and (Data='$loggedOnUser')] " +
                "and [Data[@Name='ScriptType'] and (Data='1')]] and *[System[(EventID='5018')]]"

            $gpScriptStart         = Get-DexEvent -LogName $gpLog -XPath $gpScriptStartXPath -MaxEvents 1 | Select-Object -First 1
            $gpScriptEndCandidates = @(Get-DexEvent -LogName $gpLog -XPath $gpScriptEndXPath -MaxEvents 20)

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
        } catch {}
    }

    # -- Folder Redirection (first EID 501 -> last EID 502) --
    $frLog             = 'Microsoft-Windows-Folder Redirection/Operational'
    $folderRedirDurSec = $null
    if (Test-BudgetExceeded) {
        $timedOut = $true; $folderRedirDurSec = 'TimedOut'
    } elseif ($logonTime) {
        try {
            $frStart = Get-DexEvent -LogName $frLog -Id 501 -StartTime $logonTime -EndTime $logonTime.AddMinutes(10) |
                Sort-Object TimeCreated | Select-Object -First 1
            $frEnd   = Get-DexEvent -LogName $frLog -Id 502 -StartTime $logonTime -EndTime $logonTime.AddMinutes(10) |
                Sort-Object TimeCreated -Descending | Select-Object -First 1

            if ($frStart -and $frEnd) {
                $folderRedirDurSec = [math]::Round(($frEnd.TimeCreated - $frStart.TimeCreated).TotalSeconds, 2)
            }
        } catch {}
    }

    # -- User Profile load (EID 1 -> EID 2), correlated by user SID with a session-id fallback --
    $profLog            = 'Microsoft-Windows-User Profile Service/Operational'
    $profileDurationSec = $null
    if (Test-BudgetExceeded) {
        $timedOut = $true; $profileDurationSec = 'TimedOut'
    } elseif ($logonTime) {
        try {
            $profStartEvent = $null
            $profEndEvent   = $null
            if ($userSID) {
                $profStartEvent = Get-DexEvent -LogName $profLog -Id 1 -UserSid $userSID -StartTime $logonTime -MaxEvents 1 | Select-Object -First 1
                $profEndEvent   = Get-DexEvent -LogName $profLog -Id 2 -UserSid $userSID -StartTime $logonTime -MaxEvents 1 | Select-Object -First 1
            }

            if ((-not $profStartEvent -or -not $profEndEvent) -and $null -ne $sessionId) {
                $profStartEvent = Get-DexEvent -LogName $profLog -Id 1 -StartTime $logonTime -MaxEvents 100 |
                    Where-Object { $_.Properties[0].Value -eq $sessionId } |
                    Sort-Object TimeCreated | Select-Object -First 1

                $profEndEvent = Get-DexEvent -LogName $profLog -Id 2 -StartTime $logonTime -MaxEvents 100 |
                    Where-Object { $_.Properties[0].Value -eq $sessionId } |
                    Sort-Object TimeCreated | Select-Object -First 1
            }

            if ($profStartEvent -and $profEndEvent) {
                $profileDurationSec = [math]::Round(($profEndEvent.TimeCreated - $profStartEvent.TimeCreated).TotalSeconds, 2)
            }
        } catch {}
    }

    # -- FSLogix container attach (only if the Operational log exists) --
    $fsLog              = 'Microsoft-FSLogix-Apps/Operational'
    $fslogixDurationSec = 'N/A'
    if (Test-BudgetExceeded) {
        $timedOut = $true; $fslogixDurationSec = 'TimedOut'
    } elseif ($logonTime -and (Get-DexEventLog -LogName $fsLog)) {
        try {
            $fsEvents = @(Get-DexEvent -LogName $fsLog -StartTime $logonTime.AddSeconds(-30) -EndTime $logonTime.AddMinutes(5) |
                Sort-Object TimeCreated)

            if ($fsEvents.Count -ge 2) {
                $fslogixDurationSec = [math]::Round(($fsEvents[-1].TimeCreated - $fsEvents[0].TimeCreated).TotalSeconds, 2)
            } elseif ($fsEvents.Count -eq 1) {
                $fslogixDurationSec = 0
            }
        } catch {}
    }

    # -- ActiveSetup (Shell-Core EID 62170 -> 62171), filtered to this user's SID --
    $shellLog          = 'Microsoft-Windows-Shell-Core/Operational'
    $activeSetupDurSec = 'N/A'
    if (Test-BudgetExceeded) {
        $timedOut = $true; $activeSetupDurSec = 'TimedOut'
    } elseif ($logonTime -and $userSID) {
        try {
            $asStart = Get-DexEvent -LogName $shellLog -Id 62170 -UserSid $userSID -StartTime $logonTime -EndTime $logonTime.AddMinutes(10) |
                Sort-Object TimeCreated | Select-Object -First 1
            $asEnd   = Get-DexEvent -LogName $shellLog -Id 62171 -UserSid $userSID -StartTime $logonTime -EndTime $logonTime.AddMinutes(10) |
                Sort-Object TimeCreated -Descending | Select-Object -First 1

            if ($asStart -and $asEnd) {
                $activeSetupDurSec = [math]::Round(($asEnd.TimeCreated - $asStart.TimeCreated).TotalSeconds, 2)
            }
        } catch {}
    }

    # -- AppX / UWP load (AppReadiness/Admin EID 209: From=2/To=0 start, From=1/To=2 end) --
    $appxLog    = 'Microsoft-Windows-AppReadiness/Admin'
    $appxDurSec = 'N/A'
    if (Test-BudgetExceeded) {
        $timedOut = $true; $appxDurSec = 'TimedOut'
    } elseif ($logonTime -and $userSID) {
        try {
            $appxEvents = @(Get-DexEvent -LogName $appxLog -Id 209 -StartTime $logonTime -EndTime $logonTime.AddMinutes(10) |
                Where-Object { $_.Properties[0].Value -eq $userSID -or $_.Properties[0].Value -eq $username } |
                Sort-Object TimeCreated)

            if ($appxEvents.Count -gt 0) {
                $appxStart = $appxEvents | Where-Object { [int]$_.Properties[1].Value -eq 2 -and [int]$_.Properties[2].Value -eq 0 } | Select-Object -First 1
                $appxEnd   = $appxEvents | Where-Object { [int]$_.Properties[1].Value -eq 1 -and [int]$_.Properties[2].Value -eq 2 } | Select-Object -First 1

                if ($appxStart -and $appxEnd) {
                    $appxDurSec = [math]::Round(($appxEnd.TimeCreated - $appxStart.TimeCreated).TotalSeconds, 2)
                } elseif ($appxEvents.Count -ge 2) {
                    $appxDurSec = [math]::Round(($appxEvents[-1].TimeCreated - $appxEvents[0].TimeCreated).TotalSeconds, 2)
                }
            }
        } catch {}
    }

    # -- Printer mapping (PrintService/Operational EID 300 -> 306; disabled by default) --
    $printLog      = 'Microsoft-Windows-PrintService/Operational'
    $printerCount  = 'N/A'
    $printerDurSec = 'N/A'
    if (Test-BudgetExceeded) {
        $timedOut = $true; $printerCount = 'TimedOut'; $printerDurSec = 'TimedOut'
    } else {
        $printLogInfo = Get-DexEventLog -LogName $printLog
        if (-not $printLogInfo -or -not $printLogInfo.IsEnabled) {
            $printerCount = 'LogDisabled'; $printerDurSec = 'LogDisabled'
        } elseif ($logonTime) {
            try {
                $printStart = @(Get-DexEvent -LogName $printLog -Id 300 -StartTime $logonTime -EndTime $logonTime.AddMinutes(10) |
                    Sort-Object TimeCreated)
                $printEnd   = @(Get-DexEvent -LogName $printLog -Id 306 -StartTime $logonTime -EndTime $logonTime.AddMinutes(10) |
                    Sort-Object TimeCreated -Descending)

                if ($printStart.Count -gt 0) {
                    $printerCount = $printStart.Count
                    if ($printEnd.Count -gt 0) {
                        $printerDurSec = [math]::Round(($printEnd[0].TimeCreated - $printStart[-1].TimeCreated).TotalSeconds, 2)
                    }
                } else {
                    $printerCount = 0; $printerDurSec = 0
                }
            } catch {}
        }
    }

    # -- Scheduled tasks at logon (TaskScheduler/Operational EID 100 -> 102) --
    $taskLog           = 'Microsoft-Windows-TaskScheduler/Operational'
    $logonTaskCount    = 'N/A'
    $logonTaskTotalSec = 'N/A'
    if (Test-BudgetExceeded) {
        $timedOut = $true; $logonTaskCount = 'TimedOut'; $logonTaskTotalSec = 'TimedOut'
    } else {
        $taskLogInfo = Get-DexEventLog -LogName $taskLog
        if (-not $taskLogInfo -or -not $taskLogInfo.IsEnabled) {
            $logonTaskCount = 'LogDisabled'; $logonTaskTotalSec = 'LogDisabled'
        } elseif ($logonTime) {
            try {
                $taskStartEvents = @(Get-DexEvent -LogName $taskLog -Id 100 -StartTime $logonTime -EndTime $logonTime.AddMinutes(5))
                $taskEndEvents   = @(Get-DexEvent -LogName $taskLog -Id 102 -StartTime $logonTime -EndTime $logonTime.AddMinutes(5))

                if ($taskStartEvents.Count -gt 0) {
                    $logonTaskCount = $taskStartEvents.Count
                    if ($taskEndEvents.Count -gt 0) {
                        $firstStart = $taskStartEvents | Sort-Object TimeCreated | Select-Object -First 1
                        $lastEnd    = $taskEndEvents   | Sort-Object TimeCreated -Descending | Select-Object -First 1
                        $logonTaskTotalSec = [math]::Round(($lastEnd.TimeCreated - $firstStart.TimeCreated).TotalSeconds, 2)
                    }
                } else {
                    $logonTaskCount = 0; $logonTaskTotalSec = 0
                }
            } catch {}
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
    $safeMessage = $_.Exception.Message -replace '"', "'"
    Write-Output ('{{"Status":"Failed","Error":"{0}"}}' -f $safeMessage)
    return
}
