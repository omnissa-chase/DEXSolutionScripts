#Requires -Version 5.1
<#
.SYNOPSIS
    Records per-session logon duration metrics for every interactive session on a
    device, including multi-session hosts (RDSH / AVD / Horizon), and publishes a
    device-level aggregate. Designed to run as SYSTEM from a scheduled task.

.DESCRIPTION
    The single-session collector (Measure-LogonDuration.ps1) answers "how long did the
    console user's last logon take". That question has no single answer on a session
    host, so this script answers a different one: it measures every logon it can
    attribute, stores one record per user, and reduces them to a distribution.

    Three structural differences from the single-session collector:

      1. Session inventory replaces Win32_ComputerSystem.UserName. That CIM property
         returns only the console user -- empty on a session host with no one at the
         console, and wrong for every remote user when someone is. Sessions are built
         from TerminalServices-LocalSessionManager events instead, which carry user,
         session ID and source address, and work whether or not anyone is logged on
         right now. This is also what makes "last logged-on user" answerable.

      2. Queries are provider-major, not user-major. Each event source is queried once
         across the whole window and correlated in memory. The single-session collector
         issues roughly twenty queries per user; repeating that per session would be
         about a thousand queries on a fifty-session host. Here it stays at roughly a
         dozen regardless of session count.

      3. Every phase declares how it correlates to a session. A phase that cannot be
         attributed reports the Ambiguous sentinel rather than a plausible-looking
         wrong number. Folder Redirection and FSLogix carry no user or session
         discriminator in their events, so they are measured only when the host had
         exactly one logon inside the phase window; otherwise they report Ambiguous.
         Attributing one user's folder redirection to another is worse than declining
         to answer.

    Registry layout:

      HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration
          The most recent logon on the device, in exactly the value shape the existing
          single-session sensors already read. Unchanged on a single-session device.

      HKLM:\...\LogonDuration\Sessions\<SID>
          The same values, per user, for that user's most recent measured logon.

      HKLM:\...\LogonDuration\Aggregate
          Device-level distribution across AggregateWindowHours: session count,
          P50/P95/max/mean total logon duration, and the slowest user. A Workspace ONE
          sensor returns one scalar per device, so a session host has to be reduced to
          a distribution somewhere; it is done here, at write time.

    Event sources are resolved at runtime rather than hard-coded, because the correct
    identity varies by OS build and domain state. AppReadiness event 209 is in the
    /Admin channel on Windows 11, not /Operational. The GroupPolicy provider is
    registered on a workgroup machine while its Operational channel is not, so its
    events land in System. Each phase declares both a log name and a provider name;
    whichever returns events wins, and the choice is recorded.

.PARAMETER DeployMode
    Defaults to $env:DeployMode, or RunNow when unset.

      RunNow              Measure now and write results.
      DeployScheduledTask Copy this script to C:\ProgramData\AirWatch\Extensions\DEXTools
                          and register a SYSTEM task that sweeps at logon and every
                          RepeatMinutes thereafter. On a session host the repeating
                          trigger carries the real load, not the logon trigger.
      ConfigureLogging    Enable the optional event logs (PrintService/Operational,
                          TaskScheduler/Operational). Safe to re-run.

    An unrecognised $env:DeployMode degrades to RunNow with a warning so a console typo
    does not fail the deployment. An unrecognised -DeployMode argument throws.

.PARAMETER SessionScope
    Which logons to measure. Defaults to $env:SessionScope, or LastLogon when unset.

      LastLogon  The newest logon on the device only. Matches the single-session
                 collector's behaviour and is the cheapest option.
      AllActive  Every session that currently has processes running.
      AllSince   Every logon inside LookbackHours that has not already been measured,
                 plus any earlier record still marked provisional. This is the right
                 choice for a session host and the default the scheduled task deploys
                 with.

.PARAMETER LookbackHours
    How far back to read logon events. Defaults to $env:LookbackHours, then 24.

.PARAMETER MaxSessions
    Upper bound on sessions measured in one run, newest first. Defaults to
    $env:MaxSessions, then 50. A guard against an unbounded sweep on a large host.

.PARAMETER TargetUser
    Measure only this user -- DOMAIN\user, bare username, or SID. Defaults to
    $env:TargetUser. Use it to audit one person's logon from SYSTEM context without
    touching the records of anyone else.

.PARAMETER ExcludeUserPattern
    Wildcard pattern of accounts to skip, matched against DOMAIN\user. Defaults to
    $env:ExcludeUserPattern. Intended for break-glass, monitoring and service accounts
    whose logons would otherwise skew the device aggregate.

.PARAMETER AggregateWindowHours
    Window the aggregate is computed over. Defaults to $env:AggregateWindowHours,
    then 24.

.PARAMETER TimeBudgetSeconds
    Soft ceiling on the measurement loop. When exceeded the sweep stops cleanly and
    leaves the unmeasured logons for the next run rather than being killed mid-write by
    the task's execution time limit. Defaults to $env:TimeBudgetSeconds, then 240.

.PARAMETER RepeatMinutes
    Repeating interval for the task registered by DeployScheduledTask. Defaults to
    $env:RepeatMinutes, then 15.

.PARAMETER ConfigureLoggingFirst
    Enable the optional event logs before running the requested DeployMode. True when
    $env:ConfigureLoggingFirst is true / 1 / yes / y. Anything unrecognised is false --
    this shells out to wevtutil, so it fails closed. Idempotent via a registry marker;
    DeployMode ConfigureLogging ignores the marker because that is an explicit request.

.EXAMPLE
    .\Measure-LogonDurationMultiSession.ps1 -DeployMode DeployScheduledTask -SessionScope AllSince -ConfigureLoggingFirst $true

    The intended session-host deployment: enable the optional logs, then install a
    sweeping task.

.EXAMPLE
    .\Measure-LogonDurationMultiSession.ps1 -SessionScope AllActive

    Measure every live session now and print a per-session table. Useful on a host
    users are complaining about.

.EXAMPLE
    .\Measure-LogonDurationMultiSession.ps1 -TargetUser 'CORP\jsmith' -LookbackHours 72

    Audit one user's most recent logon from SYSTEM context.

.NOTES
    Script Name  : Measure-LogonDurationMultiSession.ps1
    Version      : 2.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-10-02
    Timeout      : 300 seconds

    PowerShell 5.1 compatible.

    Every run ends by printing the contents of all three registry keys, re-read from
    the registry rather than echoed from memory, so an admin testing a deployment sees
    what a sensor will actually find. A write that failed shows as a stale or absent
    value instead of being masked by the in-memory copy.

    Numeric and timestamp registry values use InvariantCulture. A comma-decimal locale
    would otherwise record "42,5" and a Buddhist-calendar locale would record year 2569,
    either of which silently breaks every sensor that parses them.

    Sentinel strings, and their meaning to a consuming sensor:
      Unknown      the phase could not be measured on this logon
      N/A          the feature is not present or did not run on this device
      LogDisabled  the required event log is off -- run DeployMode ConfigureLogging
      Ambiguous    the phase was measurable but could not be attributed to this
                   session, because concurrent logons overlapped its window and the
                   event source carries no user or session discriminator

    Ambiguous is new in this collector. Sensors reading these values should map it to
    -4, alongside the established -1 Unknown / -2 N/A / -3 LogDisabled.

    Shell-ready is taken from the session's explorer.exe creation time rather than a
    Winlogon event. Winlogon 7001 is a Customer Experience Improvement Program logon
    notification whose EventData is TSId and UserSid; it fires in the same second as
    the logon itself, so it cannot measure time-to-desktop. explorer.exe creation is
    exact and per-session, but only readable while the session is live -- an ended
    session reports Unknown with a ShellReadySource of SessionEnded.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Measure-LogonDurationMultiSession {
[CmdletBinding()]
param(
    # Defaults are read from the environment because that is how UEM passes
    # configuration. Anything bound explicitly overrides them.
    [ValidateSet('RunNow', 'DeployScheduledTask', 'ConfigureLogging')]
    [string]$DeployMode = $(
        if ([string]::IsNullOrWhiteSpace($env:DeployMode)) { 'RunNow' } else { $env:DeployMode.Trim() }
    ),

    [ValidateSet('LastLogon', 'AllActive', 'AllSince')]
    [string]$SessionScope = $(
        if ([string]::IsNullOrWhiteSpace($env:SessionScope)) { 'LastLogon' } else { $env:SessionScope.Trim() }
    ),

    # ValidateRange applies to explicit arguments only, so a bad environment variable
    # degrades to the default instead of failing the run.
    [ValidateRange(1, 168)]
    [int]$LookbackHours = $(
        $v = 0
        if ([int]::TryParse("$env:LookbackHours".Trim(), [ref]$v) -and $v -ge 1 -and $v -le 168) { $v } else { 24 }
    ),

    [ValidateRange(1, 500)]
    [int]$MaxSessions = $(
        $v = 0
        if ([int]::TryParse("$env:MaxSessions".Trim(), [ref]$v) -and $v -ge 1 -and $v -le 500) { $v } else { 50 }
    ),

    [string]$TargetUser = $(
        if ([string]::IsNullOrWhiteSpace($env:TargetUser)) { '' } else { $env:TargetUser.Trim() }
    ),

    [string]$ExcludeUserPattern = $(
        if ([string]::IsNullOrWhiteSpace($env:ExcludeUserPattern)) { '' } else { $env:ExcludeUserPattern.Trim() }
    ),

    [ValidateRange(1, 168)]
    [int]$AggregateWindowHours = $(
        $v = 0
        if ([int]::TryParse("$env:AggregateWindowHours".Trim(), [ref]$v) -and $v -ge 1 -and $v -le 168) { $v } else { 24 }
    ),

    [ValidateRange(10, 3600)]
    [int]$TimeBudgetSeconds = $(
        $v = 0
        if ([int]::TryParse("$env:TimeBudgetSeconds".Trim(), [ref]$v) -and $v -ge 10 -and $v -le 3600) { $v } else { 240 }
    ),

    [ValidateRange(5, 1440)]
    [int]$RepeatMinutes = $(
        $v = 0
        if ([int]::TryParse("$env:RepeatMinutes".Trim(), [ref]$v) -and $v -ge 5 -and $v -le 1440) { $v } else { 15 }
    ),

    [bool]$ConfigureLoggingFirst = $(
        $env:ConfigureLoggingFirst -and $env:ConfigureLoggingFirst.Trim() -in @('true', '1', 'yes', 'y')
    )
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

#region --- Script-level constants ---
$script:ToolsDir     = 'C:\ProgramData\AirWatch\Extensions\DEXTools'
$script:ScriptName   = 'Measure-LogonDurationMultiSession.ps1'
$script:TaskName     = 'DEXTools_MeasureLogonDurationMultiSession'
$script:RegRoot      = 'HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration'
$script:SessionsRoot = 'HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration\Sessions'
$script:AggRoot      = 'HKLM:\Software\AirWatch\Extensions\DEXRecords\LogonDuration\Aggregate'
$script:Version      = '2.0.0'
$script:ValidModes   = @('RunNow', 'DeployScheduledTask', 'ConfigureLogging')
$script:ValidScopes  = @('LastLogon', 'AllActive', 'AllSince')

# How long after a logon a phase's events may still appear. Phase windows are clamped
# to this, which also bounds how much of the event log is read per run.
$script:PhaseWindowMinutes = 10

# A provisional record is one measured before all its events had flushed. It is
# re-measured on later sweeps until it is complete or has been attempted this often.
$script:MaxMeasureAttempts = 3

# Accounts that produce TerminalServices logon events but are not people.
$script:SystemAccountPattern = '^(NT AUTHORITY|NT SERVICE|Window Manager|Font Driver Host)\\'
#endregion

#region --- Configuration normalisation ---
# ValidateSet is not applied to default values, so unrecognised environment variables
# arrive here unchecked. Degrade rather than failing the whole deployment.
if (-not $PSBoundParameters.ContainsKey('DeployMode')) {
    # -eq on strings is case-insensitive, so this also normalises casing.
    $matchedMode = $script:ValidModes | Where-Object { $_ -eq $DeployMode } | Select-Object -First 1
    if ($matchedMode) {
        $DeployMode = $matchedMode
    }
    else {
        Write-Warning "Unrecognised `$env:DeployMode '$DeployMode'. Using 'RunNow'. Valid values: $($script:ValidModes -join ', ')"
        $DeployMode = 'RunNow'
    }
}

if (-not $PSBoundParameters.ContainsKey('SessionScope')) {
    $matchedScope = $script:ValidScopes | Where-Object { $_ -eq $SessionScope } | Select-Object -First 1
    if ($matchedScope) {
        $SessionScope = $matchedScope
    }
    else {
        Write-Warning "Unrecognised `$env:SessionScope '$SessionScope'. Using 'LastLogon'. Valid values: $($script:ValidScopes -join ', ')"
        $SessionScope = 'LastLogon'
    }
}
#endregion

#region --- Formatting helpers ---
# Registry values are consumed by sensors that parse them back into numbers and dates.
# Both sides must agree on culture or the round trip silently fails on non-en-US devices.
function Format-Metric {
    param($Value)
    if ($null -eq $Value)    { return 'Unknown' }
    if ($Value -is [string]) { return $Value }
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
}

function Format-Stamp {
    param($Value)
    if ($null -eq $Value)    { return 'Unknown' }
    if ($Value -is [string]) { return $Value }
    return $Value.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
}

# Round-trip-safe form for the high-water mark, where a second's precision is not
# enough to tell two near-simultaneous logons apart.
function Format-StampUtc {
    param([datetime]$Value)
    return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-StampUtc {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParse(
        $Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )
    if ($ok) { return $parsed.ToLocalTime() }
    return $null
}

# Only a value that is actually a measurement is usable in the aggregate. Every
# sentinel, and any string a non-invariant collector may have left behind, is excluded.
function ConvertTo-Measurement {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw))                       { return $null }
    if ($Raw -in @('Unknown', 'N/A', 'LogDisabled', 'Ambiguous')) { return $null }
    $value = 0.0
    $ok = [double]::TryParse(
        ($Raw -replace ',', '.'),
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$value
    )
    if ($ok) { return $value }
    return $null
}

# A unit belongs on a measurement, not on a sentinel: "P95 Unknowns" reads as a plural
# rather than as the absence of data.
function Format-WithUnit {
    param($Value, [string]$Unit = 's')
    $text = [string]$Value
    if ($null -eq (ConvertTo-Measurement $text)) { return $text }
    return "$text$Unit"
}

function Get-Percentile {
    param([double[]]$Values, [int]$Percentile)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    # Nearest-rank. Exact enough for a fleet metric and has no interpolation surprises
    # at small sample sizes, which is the common case on a lightly used host.
    $rank = [int][math]::Ceiling(($Percentile / 100.0) * $sorted.Count)
    if ($rank -lt 1)             { $rank = 1 }
    if ($rank -gt $sorted.Count) { $rank = $sorted.Count }
    return [math]::Round($sorted[$rank - 1], 2)
}
#endregion

#region --- Event source resolution ---
# Each phase declares both a log name and a provider name. Which one is correct varies
# by OS build and domain state -- AppReadiness 209 is in /Admin on Windows 11, not
# /Operational, and the GroupPolicy provider is registered on a workgroup machine while
# its Operational channel is not. Rather than guess, try the declared identities and
# keep whichever the event service accepts.
#
# Optional: the phase reports N/A when the source is absent, instead of Unknown. A
# device without FSLogix has not failed to measure a container attach; it has no
# container to attach.
#
# Correlation: how an event is tied back to a session.
#   Sid        Security/@UserID or an EventData SID field
#   SessionId  an EventData TSId / SessionId field
#   SamName    an EventData PrincipalSamName field
#   TimeOnly   no discriminator exists; measurable only when the host had exactly one
#              logon inside the phase window, otherwise Ambiguous
$script:SourceTable = [ordered]@{
    Logon = @{
        LogName     = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
        ProviderName= 'Microsoft-Windows-TerminalServices-LocalSessionManager'
        Ids         = @(21, 25)
        Correlation = 'SessionId'
        Optional    = $false
        NeedsData   = $false
    }
    GroupPolicy = @{
        LogName     = 'Microsoft-Windows-GroupPolicy/Operational'
        ProviderName= 'Microsoft-Windows-GroupPolicy'
        Ids         = @(4001, 8001, 4018, 5018)
        Correlation = 'SamName'
        Optional    = $true
        NeedsData   = $true
    }
    Profile = @{
        LogName     = 'Microsoft-Windows-User Profile Service/Operational'
        ProviderName= 'Microsoft-Windows-User Profiles Service'
        Ids         = @(1, 2)
        Correlation = 'Sid'
        Optional    = $false
        NeedsData   = $false
    }
    FolderRedirection = @{
        LogName     = 'Microsoft-Windows-Folder Redirection/Operational'
        ProviderName= 'Microsoft-Windows-Folder Redirection'
        Ids         = @(501, 502)
        Correlation = 'TimeOnly'
        Optional    = $true
        NeedsData   = $false
    }
    FSLogix = @{
        LogName     = 'Microsoft-FSLogix-Apps/Operational'
        ProviderName= 'Microsoft-FSLogix-Apps'
        Ids         = @()
        Correlation = 'TimeOnly'
        Optional    = $true
        NeedsData   = $false
    }
    ActiveSetup = @{
        LogName     = 'Microsoft-Windows-Shell-Core/Operational'
        ProviderName= 'Microsoft-Windows-Shell-Core'
        Ids         = @(62170, 62171)
        Correlation = 'Sid'
        Optional    = $true
        NeedsData   = $false
    }
    AppX = @{
        LogName     = 'Microsoft-Windows-AppReadiness/Admin'
        ProviderName= 'Microsoft-Windows-AppReadiness'
        Ids         = @(209)
        Correlation = 'Sid'
        Optional    = $true
        NeedsData   = $false
    }
    PrintService = @{
        LogName     = 'Microsoft-Windows-PrintService/Operational'
        ProviderName= 'Microsoft-Windows-PrintService'
        Ids         = @(300, 306)
        Correlation = 'Sid'
        Optional    = $true
        NeedsData   = $false
    }
    TaskScheduler = @{
        LogName     = 'Microsoft-Windows-TaskScheduler/Operational'
        ProviderName= 'Microsoft-Windows-TaskScheduler'
        Ids         = @(100, 102)
        Correlation = 'SamName'
        Optional    = $true
        NeedsData   = $true
    }
}

# Resolution outcome per phase, filled in by Resolve-EventSources and consulted when a
# phase has no events, so "Unknown" can be told apart from "this log is switched off".
$script:SourceState = @{}

function Resolve-EventSources {
    foreach ($key in $script:SourceTable.Keys) {
        $spec   = $script:SourceTable[$key]
        $state  = @{ Identity = $null; Status = 'ProviderMissing'; Resolved = 'None' }

        $log = Get-WinEvent -ListLog $spec.LogName -ErrorAction SilentlyContinue
        if ($log) {
            if ($log.IsEnabled) {
                $state.Identity = @{ LogName = $spec.LogName }
                $state.Status   = 'OK'
                $state.Resolved = 'Log'
            }
            else {
                # The log exists but is switched off. Distinct from absent: an operator
                # can fix this, and DeployMode ConfigureLogging is how.
                $state.Status   = 'LogDisabled'
                $state.Resolved = 'None'
            }
        }

        # Fall back to the provider when the channel is absent or disabled. On a
        # workgroup machine the GroupPolicy channel does not exist but the provider
        # does, writing to System instead.
        if ($state.Status -ne 'OK') {
            $provider = Get-WinEvent -ListProvider $spec.ProviderName -ErrorAction SilentlyContinue
            if ($provider) {
                $state.Identity = @{ ProviderName = $spec.ProviderName }
                # A disabled dedicated channel still means the data is not being
                # written, even though the provider is registered. Keep LogDisabled.
                if ($state.Status -ne 'LogDisabled') {
                    $state.Status   = 'OK'
                    $state.Resolved = 'Provider'
                }
            }
        }

        $script:SourceState[$key] = $state
    }
}

# The sentinel a phase should report when it produced no events, which depends on why.
function Get-SourceSentinel {
    param([string]$SourceKey)
    $state = $script:SourceState[$SourceKey]
    if ($null -eq $state)                { return 'Unknown' }
    if ($state.Status -eq 'LogDisabled') { return 'LogDisabled' }
    if ($state.Status -ne 'OK') {
        if ($script:SourceTable[$SourceKey].Optional) { return 'N/A' }
        return 'Unknown'
    }
    return 'Unknown'
}

# EventData as a name-keyed hashtable. ToXml is not cheap, so it is only attached to
# the phases whose correlation actually needs a named field (GroupPolicy, TaskScheduler).
function Get-EventDataMap {
    param($Event)
    $map = @{}
    try {
        $xml = [xml]$Event.ToXml()
        foreach ($node in $xml.Event.EventData.Data) {
            if ($node.Name) { $map[$node.Name] = [string]$node.'#text' }
        }
    }
    catch {}
    return $map
}

# One query per source for the whole window. This is the change that makes a
# fifty-session sweep affordable: correlation happens in memory afterwards.
function Get-EventSet {
    param(
        [string]$SourceKey,
        [datetime]$StartTime,
        [datetime]$EndTime
    )

    $state = $script:SourceState[$SourceKey]
    if ($null -eq $state -or $state.Status -ne 'OK' -or $null -eq $state.Identity) {
        return @()
    }

    $spec   = $script:SourceTable[$SourceKey]
    $filter = @{}
    foreach ($k in $state.Identity.Keys) { $filter[$k] = $state.Identity[$k] }
    if ($spec.Ids.Count -gt 0) { $filter['Id'] = $spec.Ids }
    $filter['StartTime'] = $StartTime
    $filter['EndTime']   = $EndTime

    $events = @(Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue |
                    Sort-Object TimeCreated)

    if ($spec.NeedsData) {
        foreach ($event in $events) {
            Add-Member -InputObject $event -NotePropertyName 'DataMap' `
                -NotePropertyValue (Get-EventDataMap -Event $event) -Force
        }
    }

    return $events
}
#endregion

#region --- Session inventory ---
# Which session IDs currently have processes. Any process in a session means the
# session is live, which is both cheaper and more robust than parsing the fixed-width
# output of "query session".
function Get-LiveSessionIds {
    $ids = @{}
    foreach ($process in (Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)) {
        if ($null -ne $process.SessionId) { $ids[[int]$process.SessionId] = $true }
    }
    return $ids
}

# explorer.exe creation time per session -- the shell-ready source. Exact and
# per-session, but only readable while the session is live.
function Get-ShellStartBySession {
    $map = @{}
    $processes = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue
    foreach ($process in $processes) {
        if ($null -eq $process.SessionId -or $null -eq $process.CreationDate) { continue }
        $sid = [int]$process.SessionId
        # A session can have more than one explorer.exe over its life (a shell restart).
        # The earliest is the one that released the desktop.
        if (-not $map.ContainsKey($sid) -or $process.CreationDate -lt $map[$sid]) {
            $map[$sid] = $process.CreationDate
        }
    }
    return $map
}

function Resolve-UserSid {
    param([string]$Account)
    try {
        return ([System.Security.Principal.NTAccount]$Account).Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
    }
    catch {
        return $null
    }
}

# Sessions come from TerminalServices-LocalSessionManager 21 (logon) and 25
# (reconnect). Properties are [DOMAIN\user, SessionId, SourceNetworkAddress], so a
# single query yields the user, the session and whether it arrived locally or over the
# network -- and it works with nobody logged on, which Win32_ComputerSystem.UserName
# does not.
function Get-SessionInventory {
    param([datetime]$Since)

    $events = Get-EventSet -SourceKey 'Logon' -StartTime $Since -EndTime (Get-Date).AddMinutes(1)
    if ($events.Count -eq 0) { return @() }

    $live     = Get-LiveSessionIds
    $sessions = @()

    foreach ($event in $events) {
        if ($event.Properties.Count -lt 2) { continue }

        $account = [string]$event.Properties[0].Value
        if ([string]::IsNullOrWhiteSpace($account)) { continue }
        if ($account -match $script:SystemAccountPattern) { continue }

        $sessionId = 0
        if (-not [int]::TryParse([string]$event.Properties[1].Value, [ref]$sessionId)) { continue }

        $source = 'LOCAL'
        if ($event.Properties.Count -ge 3 -and -not [string]::IsNullOrWhiteSpace([string]$event.Properties[2].Value)) {
            $source = [string]$event.Properties[2].Value
        }

        $sessions += [PSCustomObject]@{
            Account     = $account
            Username    = $account.Split('\')[-1]
            Sid         = Resolve-UserSid -Account $account
            SessionId   = $sessionId
            LogonTime   = $event.TimeCreated
            IsReconnect = ($event.Id -eq 25)
            Source      = $source
            SessionType = if ($source -eq 'LOCAL') { 'Console' } else { 'Remote' }
            IsLive      = $live.ContainsKey($sessionId)
        }
    }

    # One record per user per session: the newest event wins, so a reconnect does not
    # create a second session for someone who is already counted. Reconnects still
    # matter as an anchor, because phases re-run on reconnect.
    $deduped = @()
    foreach ($group in ($sessions | Group-Object { "$($_.Account)|$($_.SessionId)" })) {
        $deduped += ($group.Group | Sort-Object LogonTime -Descending | Select-Object -First 1)
    }

    return @($deduped | Sort-Object LogonTime -Descending)
}

# Scope, target and exclusion filtering, plus the high-water mark that keeps AllSince
# from re-measuring work already done.
function Select-SessionsInScope {
    param(
        [object[]]$Sessions,
        [string]$Scope,
        [string]$Target,
        [string]$Exclude,
        [int]$Limit
    )

    $candidates = @($Sessions)

    if (-not [string]::IsNullOrWhiteSpace($Target)) {
        $candidates = @($candidates | Where-Object {
            $_.Account -eq $Target -or $_.Username -eq $Target -or $_.Sid -eq $Target
        })
    }

    if (-not [string]::IsNullOrWhiteSpace($Exclude)) {
        $candidates = @($candidates | Where-Object { $_.Account -notlike $Exclude })
    }

    switch ($Scope) {
        'LastLogon' {
            $candidates = @($candidates | Select-Object -First 1)
        }
        'AllActive' {
            $candidates = @($candidates | Where-Object { $_.IsLive })
        }
        'AllSince' {
            $mark = ConvertFrom-StampUtc (Get-ItemProperty -Path $script:RegRoot `
                        -Name 'LastProcessedLogon' -ErrorAction SilentlyContinue).LastProcessedLogon

            if ($mark) {
                # Newer than the mark, or an older record still provisional because its
                # events had not flushed when it was first measured.
                $candidates = @($candidates | Where-Object {
                    $_.LogonTime -gt $mark -or (Test-SessionNeedsRemeasure -Session $_)
                })
            }
        }
    }

    return @($candidates | Select-Object -First $Limit)
}

# A stored record is retried only while it is still incomplete and has not been
# attempted too many times, so a genuinely unmeasurable phase does not cause the
# sweep to re-measure the same logon forever.
function Test-SessionNeedsRemeasure {
    param($Session)

    if ([string]::IsNullOrWhiteSpace($Session.Sid)) { return $false }

    $key    = "$($script:SessionsRoot)\$($Session.Sid)"
    $record = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if ($null -eq $record) { return $true }

    $storedLogon = ConvertFrom-StampUtc ([string]$record.LogonTimeUtc)
    if ($null -eq $storedLogon) { return $true }

    # A different logon than the one on record: measure it.
    if ([math]::Abs(($storedLogon - $Session.LogonTime).TotalSeconds) -gt 2) { return $true }

    if ([string]$record.Provisional -ne 'True') { return $false }

    $attempts = 0
    [void][int]::TryParse([string]$record.MeasureAttempts, [ref]$attempts)
    return ($attempts -lt $script:MaxMeasureAttempts)
}
#endregion

#region --- Correlation helpers ---
# Events belonging to this session. Sid and SessionId correlation are exact; SamName
# matches the account string Group Policy and Task Scheduler record.
function Select-SessionEvents {
    param(
        [object[]]$Events,
        [int]$Id,
        $Session,
        [string]$Correlation,
        [string]$DataField
    )

    $matched = @($Events | Where-Object { $_.Id -eq $Id })
    if ($matched.Count -eq 0) { return @() }

    switch ($Correlation) {
        'Sid' {
            if ([string]::IsNullOrWhiteSpace($Session.Sid)) { return @() }
            return @($matched | Where-Object {
                ($null -ne $_.UserId -and $_.UserId.Value -eq $Session.Sid) -or
                ($_.Properties.Count -gt 0 -and [string]$_.Properties[0].Value -eq $Session.Sid)
            })
        }
        'SessionId' {
            return @($matched | Where-Object {
                $_.Properties.Count -gt 1 -and [string]$_.Properties[1].Value -eq [string]$Session.SessionId
            })
        }
        'SamName' {
            return @($matched | Where-Object {
                $null -ne $_.DataMap -and
                -not [string]::IsNullOrWhiteSpace($DataField) -and
                $_.DataMap.ContainsKey($DataField) -and
                $_.DataMap[$DataField] -eq $Session.Account
            })
        }
        default {
            return $matched
        }
    }
}

# Pair a start event with its matching end. Group Policy stamps one ActivityId per
# processing cycle, so pairing the newest start with the newest end can straddle two
# cycles and produce a duration that is wrong, or negative. Prefer the ActivityId;
# fall back to the first end after the start.
function Measure-PairedSpan {
    param(
        [object[]]$StartEvents,
        [object[]]$EndEvents
    )

    $start = @($StartEvents | Sort-Object TimeCreated -Descending | Select-Object -First 1)
    if ($start.Count -eq 0) { return $null }
    $start = $start[0]

    $end = $null
    if ($null -ne $start.ActivityId) {
        $end = @($EndEvents | Where-Object {
            $null -ne $_.ActivityId -and $_.ActivityId -eq $start.ActivityId
        } | Select-Object -First 1)
        if ($end.Count -eq 0) { $end = $null } else { $end = $end[0] }
    }

    if ($null -eq $end) {
        $end = @($EndEvents | Where-Object { $_.TimeCreated -ge $start.TimeCreated } |
                    Sort-Object TimeCreated | Select-Object -First 1)
        if ($end.Count -eq 0) { return $null }
        $end = $end[0]
    }

    $span = ($end.TimeCreated - $start.TimeCreated).TotalSeconds
    if ($span -lt 0) { return $null }
    return [math]::Round($span, 2)
}

# Span across every event in a set: first to last. Used where a phase emits one pair
# per item (one 501/502 per redirected folder) and the total span is the measurement.
function Measure-BoundingSpan {
    param([object[]]$Events)
    $ordered = @($Events | Sort-Object TimeCreated)
    if ($ordered.Count -eq 0) { return $null }
    if ($ordered.Count -eq 1) { return 0 }
    return [math]::Round(($ordered[-1].TimeCreated - $ordered[0].TimeCreated).TotalSeconds, 2)
}
#endregion

#region --- Phase resolution ---
# Decide which events belong to this session and how much to trust the attribution.
#
# A declared discriminator is preferred, but it is not guaranteed to exist on every OS
# build -- so when a phase has events in the window that the discriminator did not
# match, fall back to time-only semantics instead of silently reporting Unknown. That
# fallback is only honest when this session was the only logon in the window; with
# overlapping logons the phase reports Ambiguous rather than borrowing another user's
# events.
function Resolve-PhaseEvents {
    param(
        [object[]]$Events,
        [int]$Id,
        $Session,
        [string]$Correlation,
        [string]$DataField,
        [int]$ConcurrentLogons
    )

    $inWindow = @($Events | Where-Object { $_.Id -eq $Id })
    if ($inWindow.Count -eq 0) {
        return @{ Events = @(); Mode = 'None' }
    }

    if ($Correlation -eq 'TimeOnly') {
        if ($ConcurrentLogons -le 1) { return @{ Events = $inWindow; Mode = 'TimeOnly' } }
        return @{ Events = @(); Mode = 'Ambiguous' }
    }

    $scoped = Select-SessionEvents -Events $inWindow -Id $Id -Session $Session `
                  -Correlation $Correlation -DataField $DataField
    if ($scoped.Count -gt 0) {
        return @{ Events = $scoped; Mode = 'Scoped' }
    }

    # Events exist but none carried this session's identity. Either they belong to
    # someone else, or this build does not populate the field we correlate on.
    if ($ConcurrentLogons -le 1) {
        return @{ Events = $inWindow; Mode = 'TimeOnly' }
    }
    return @{ Events = @(); Mode = 'Ambiguous' }
}

# Translate a phase outcome into the value a sensor will read. The distinction that
# matters: Ambiguous means "measurable, but not attributable to this user", which is a
# different operational problem from "could not measure" and must not look the same.
function Resolve-PhaseValue {
    param(
        $Measurement,
        [string]$Mode,
        [string]$SourceKey
    )

    if ($Mode -eq 'Ambiguous')  { return 'Ambiguous' }
    if ($null -ne $Measurement) { return $Measurement }
    if ($Mode -eq 'None')       { return (Get-SourceSentinel -SourceKey $SourceKey) }
    return 'Unknown'
}
#endregion

#region --- Per-session measurement ---
function Measure-Session {
    param(
        $Session,
        [hashtable]$EventSets,
        [hashtable]$ShellStarts,
        [int]$ConcurrentLogons
    )

    $logonTime = $Session.LogonTime
    $windowEnd = $logonTime.AddMinutes($script:PhaseWindowMinutes)
    $diag      = [ordered]@{}

    # Phase windows are per session, so a sweep that harvested a wide span does not let
    # one user's events leak into another's measurement on the time axis.
    $window = {
        param([object[]]$Set)
        return @($Set | Where-Object {
            $_.TimeCreated -ge $logonTime.AddSeconds(-30) -and $_.TimeCreated -le $windowEnd
        })
    }

    #region Shell ready and total logon duration
    # explorer.exe creation, joined by session ID. Winlogon 7001 is not usable here:
    # its EventData is TSId and UserSid, and it fires in the same second as the logon,
    # so it cannot measure time to desktop.
    $shellReadyTime   = $null
    $totalLogonDurSec = $null
    $shellSource      = 'Unavailable'

    if ($ShellStarts.ContainsKey($Session.SessionId)) {
        $candidate = $ShellStarts[$Session.SessionId]
        # Session IDs are reused, so an explorer.exe from an earlier tenant of this
        # session ID must not be credited to this logon.
        if ($candidate -ge $logonTime -and $candidate -le $windowEnd) {
            $shellReadyTime   = $candidate
            $totalLogonDurSec = [math]::Round(($shellReadyTime - $logonTime).TotalSeconds, 2)
            $shellSource      = 'ExplorerProcess'
        }
        else {
            $shellSource = 'ExplorerOutsideWindow'
        }
    }
    elseif (-not $Session.IsLive) {
        $shellSource = 'SessionEnded'
    }
    $diag['ShellReady'] = $shellSource
    #endregion

    #region Group Policy total (4001 start -> 8001 finish)
    $gpSet          = & $window $EventSets['GroupPolicy']
    $gpStartResolve = Resolve-PhaseEvents -Events $gpSet -Id 4001 -Session $Session `
                          -Correlation 'SamName' -DataField 'PrincipalSamName' -ConcurrentLogons $ConcurrentLogons
    $gpEndResolve   = Resolve-PhaseEvents -Events $gpSet -Id 8001 -Session $Session `
                          -Correlation 'SamName' -DataField 'PrincipalSamName' -ConcurrentLogons $ConcurrentLogons

    $gpStartTime   = $null
    $gpDurationSec = $null
    if ($gpStartResolve.Events.Count -gt 0) {
        $gpStartTime   = @($gpStartResolve.Events | Sort-Object TimeCreated -Descending)[0].TimeCreated
        $gpDurationSec = Measure-PairedSpan -StartEvents $gpStartResolve.Events -EndEvents $gpEndResolve.Events
    }
    $diag['GroupPolicy'] = $gpStartResolve.Mode
    #endregion

    #region Group Policy logon scripts (4018 start -> 5018 finish, ScriptType 1)
    # ScriptType 1 is logon scripts; 2 is logoff. Measuring both together would report
    # the previous session's logoff scripts as this session's logon cost.
    $scriptStartAll = @($gpSet | Where-Object {
        $_.Id -eq 4018 -and $null -ne $_.DataMap -and $_.DataMap['ScriptType'] -eq '1'
    })
    $scriptEndAll = @($gpSet | Where-Object {
        $_.Id -eq 5018 -and $null -ne $_.DataMap -and $_.DataMap['ScriptType'] -eq '1'
    })

    $gpScriptsDurSec = $null
    $scriptMode      = 'None'
    if ($scriptStartAll.Count -gt 0) {
        $scriptStartScoped = @($scriptStartAll | Where-Object { $_.DataMap['PrincipalSamName'] -eq $Session.Account })
        $scriptEndScoped   = @($scriptEndAll   | Where-Object { $_.DataMap['PrincipalSamName'] -eq $Session.Account })

        if ($scriptStartScoped.Count -gt 0) {
            $scriptMode      = 'Scoped'
            $gpScriptsDurSec = Measure-PairedSpan -StartEvents $scriptStartScoped -EndEvents $scriptEndScoped
        }
        elseif ($ConcurrentLogons -le 1) {
            $scriptMode      = 'TimeOnly'
            $gpScriptsDurSec = Measure-PairedSpan -StartEvents $scriptStartAll -EndEvents $scriptEndAll
        }
        else {
            $scriptMode = 'Ambiguous'
        }
    }
    $diag['GPScripts'] = $scriptMode
    #endregion

    #region Folder Redirection (501 start -> 502 finish, one pair per folder)
    # No user or session discriminator exists in this log, so it is measurable only
    # when this session was the sole logon in the window.
    $frSet     = & $window $EventSets['FolderRedirection']
    $frResolve = Resolve-PhaseEvents -Events $frSet -Id 501 -Session $Session `
                     -Correlation 'TimeOnly' -DataField '' -ConcurrentLogons $ConcurrentLogons

    $folderRedirDurSec = $null
    if ($frResolve.Mode -eq 'TimeOnly' -and $frResolve.Events.Count -gt 0) {
        $frEnd = @($frSet | Where-Object { $_.Id -eq 502 } | Sort-Object TimeCreated -Descending)
        if ($frEnd.Count -gt 0) {
            $frFirst = @($frResolve.Events | Sort-Object TimeCreated)[0]
            $span    = ($frEnd[0].TimeCreated - $frFirst.TimeCreated).TotalSeconds
            if ($span -ge 0) { $folderRedirDurSec = [math]::Round($span, 2) }
        }
    }
    $diag['FolderRedirection'] = $frResolve.Mode
    #endregion

    #region User profile load (User Profiles Service 1 start -> 2 finish)
    # Correlated on the SID in the Security element. The single-session collector
    # queried the provider as "User Profile Service" -- that is the log name, not the
    # provider name, which is "User Profiles Service" -- so this phase never resolved
    # there.
    $profSet        = & $window $EventSets['Profile']
    $profStartSolve = Resolve-PhaseEvents -Events $profSet -Id 1 -Session $Session `
                          -Correlation 'Sid' -DataField '' -ConcurrentLogons $ConcurrentLogons
    $profEndSolve   = Resolve-PhaseEvents -Events $profSet -Id 2 -Session $Session `
                          -Correlation 'Sid' -DataField '' -ConcurrentLogons $ConcurrentLogons

    $profileDurationSec = $null
    if ($profStartSolve.Events.Count -gt 0) {
        # Properties[0] is the session ID, so when several of this user's logons sit in
        # the window the right pair can still be isolated.
        $startBySession = @($profStartSolve.Events | Where-Object {
            $_.Properties.Count -gt 0 -and [string]$_.Properties[0].Value -eq [string]$Session.SessionId
        })
        $endBySession = @($profEndSolve.Events | Where-Object {
            $_.Properties.Count -gt 0 -and [string]$_.Properties[0].Value -eq [string]$Session.SessionId
        })

        if ($startBySession.Count -gt 0 -and $endBySession.Count -gt 0) {
            $profileDurationSec = Measure-PairedSpan -StartEvents $startBySession -EndEvents $endBySession
        }
        else {
            $profileDurationSec = Measure-PairedSpan -StartEvents $profStartSolve.Events -EndEvents $profEndSolve.Events
        }
    }
    $diag['ProfileLoad'] = $profStartSolve.Mode
    #endregion

    #region FSLogix container attach
    # Time-only, like Folder Redirection. N/A rather than Unknown when the log is
    # absent: a device without FSLogix has no container to attach.
    $fsSet              = & $window $EventSets['FSLogix']
    $fslogixDurationSec = $null
    $fsMode             = 'None'

    if ($script:SourceState['FSLogix'].Status -ne 'OK') {
        $fsMode = 'None'
    }
    elseif ($ConcurrentLogons -gt 1) {
        $fsMode = 'Ambiguous'
    }
    elseif ($fsSet.Count -gt 0) {
        $fsMode             = 'TimeOnly'
        $fslogixDurationSec = Measure-BoundingSpan -Events $fsSet
    }
    $diag['FSLogix'] = $fsMode
    #endregion

    #region ActiveSetup (Shell-Core 62170 start -> 62171 finish)
    $asSet        = & $window $EventSets['ActiveSetup']
    $asStartSolve = Resolve-PhaseEvents -Events $asSet -Id 62170 -Session $Session `
                        -Correlation 'Sid' -DataField '' -ConcurrentLogons $ConcurrentLogons
    $asEndSolve   = Resolve-PhaseEvents -Events $asSet -Id 62171 -Session $Session `
                        -Correlation 'Sid' -DataField '' -ConcurrentLogons $ConcurrentLogons

    $activeSetupDurSec = $null
    if ($asStartSolve.Events.Count -gt 0 -and $asEndSolve.Events.Count -gt 0) {
        $asFirst = @($asStartSolve.Events | Sort-Object TimeCreated)[0]
        $asLast  = @($asEndSolve.Events   | Sort-Object TimeCreated -Descending)[0]
        $span    = ($asLast.TimeCreated - $asFirst.TimeCreated).TotalSeconds
        if ($span -ge 0) { $activeSetupDurSec = [math]::Round($span, 2) }
    }
    $diag['ActiveSetup'] = $asStartSolve.Mode
    #endregion

    #region AppX / UWP package load (AppReadiness 209)
    # 209 marks UWP state transitions, with the user SID in Properties[0]. The From/To
    # pair that brackets package loading varies between builds, so the transition pair
    # is preferred and the span of all this user's events is the fallback.
    $appxSet    = & $window $EventSets['AppX']
    $appxSolve  = Resolve-PhaseEvents -Events $appxSet -Id 209 -Session $Session `
                      -Correlation 'Sid' -DataField '' -ConcurrentLogons $ConcurrentLogons
    $appxDurSec = $null

    if ($appxSolve.Events.Count -gt 0) {
        $ordered   = @($appxSolve.Events | Sort-Object TimeCreated)
        $appxStart = @($ordered | Where-Object {
            $_.Properties.Count -ge 3 -and [string]$_.Properties[1].Value -eq '2' -and [string]$_.Properties[2].Value -eq '0'
        } | Select-Object -First 1)
        $appxEnd = @($ordered | Where-Object {
            $_.Properties.Count -ge 3 -and [string]$_.Properties[1].Value -eq '1' -and [string]$_.Properties[2].Value -eq '2'
        } | Select-Object -First 1)

        if ($appxStart.Count -gt 0 -and $appxEnd.Count -gt 0) {
            $span = ($appxEnd[0].TimeCreated - $appxStart[0].TimeCreated).TotalSeconds
            if ($span -ge 0) { $appxDurSec = [math]::Round($span, 2) }
        }
        if ($null -eq $appxDurSec -and $ordered.Count -ge 2) {
            $appxDurSec = Measure-BoundingSpan -Events $ordered
        }
    }
    $diag['AppX'] = $appxSolve.Mode
    #endregion

    #region Printer mapping (PrintService 300 -> 306)
    $printSet      = & $window $EventSets['PrintService']
    $printSolve    = Resolve-PhaseEvents -Events $printSet -Id 300 -Session $Session `
                         -Correlation 'Sid' -DataField '' -ConcurrentLogons $ConcurrentLogons
    $printerCount  = $null
    $printerDurSec = $null

    if ($script:SourceState['PrintService'].Status -eq 'OK' -and $printSolve.Mode -ne 'Ambiguous') {
        if ($printSolve.Events.Count -eq 0) {
            # The log is on and nothing happened: zero printers is a measurement, not a
            # missing value.
            $printerCount  = 0
            $printerDurSec = 0
        }
        else {
            $printerCount = $printSolve.Events.Count
            $endResolve   = Resolve-PhaseEvents -Events $printSet -Id 306 -Session $Session `
                                -Correlation 'Sid' -DataField '' -ConcurrentLogons $ConcurrentLogons
            if ($endResolve.Events.Count -gt 0) {
                $firstStart = @($printSolve.Events | Sort-Object TimeCreated)[0]
                $lastEnd    = @($endResolve.Events | Sort-Object TimeCreated -Descending)[0]
                $span       = ($lastEnd.TimeCreated - $firstStart.TimeCreated).TotalSeconds
                if ($span -ge 0) { $printerDurSec = [math]::Round($span, 2) }
            }
        }
    }
    $diag['PrinterMapping'] = $printSolve.Mode
    #endregion

    #region Scheduled tasks at logon (TaskScheduler 100 -> 102)
    # EID 100 carries UserContext, so logon tasks can be attributed per session. Only
    # the first five minutes count: beyond that a task is no longer competing with the
    # logon.
    $taskWindowEnd = $logonTime.AddMinutes(5)
    $taskSet = @($EventSets['TaskScheduler'] | Where-Object {
        $_.TimeCreated -ge $logonTime -and $_.TimeCreated -le $taskWindowEnd
    })
    $taskSolve = Resolve-PhaseEvents -Events $taskSet -Id 100 -Session $Session `
                     -Correlation 'SamName' -DataField 'UserContext' -ConcurrentLogons $ConcurrentLogons

    $logonTaskCount    = $null
    $logonTaskTotalSec = $null

    if ($script:SourceState['TaskScheduler'].Status -eq 'OK' -and $taskSolve.Mode -ne 'Ambiguous') {
        if ($taskSolve.Events.Count -eq 0) {
            $logonTaskCount    = 0
            $logonTaskTotalSec = 0
        }
        else {
            $logonTaskCount = $taskSolve.Events.Count
            $taskEndSolve   = Resolve-PhaseEvents -Events $taskSet -Id 102 -Session $Session `
                                  -Correlation 'SamName' -DataField 'UserContext' -ConcurrentLogons $ConcurrentLogons
            if ($taskEndSolve.Events.Count -gt 0) {
                $firstStart = @($taskSolve.Events    | Sort-Object TimeCreated)[0]
                $lastEnd    = @($taskEndSolve.Events | Sort-Object TimeCreated -Descending)[0]
                $span       = ($lastEnd.TimeCreated - $firstStart.TimeCreated).TotalSeconds
                if ($span -ge 0) { $logonTaskTotalSec = [math]::Round($span, 2) }
            }
        }
    }
    $diag['LogonTasks'] = $taskSolve.Mode
    #endregion

    #region Assemble the record
    # The first eighteen value names and their order match the single-session collector
    # exactly, so every existing sensor reads this record unchanged.
    $record = [ordered]@{
        Username                  = $Session.Account
        LogonTime                 = Format-Stamp  $logonTime
        ShellReadyTime            = Format-Stamp  $shellReadyTime
        TotalLogonDurationSec     = Format-Metric (Resolve-PhaseValue $totalLogonDurSec   'Scoped'              'Logon')
        GPStartTime               = Format-Stamp  $gpStartTime
        GPDurationSec             = Format-Metric (Resolve-PhaseValue $gpDurationSec      $gpStartResolve.Mode  'GroupPolicy')
        GPScriptsDurationSec      = Format-Metric (Resolve-PhaseValue $gpScriptsDurSec    $scriptMode           'GroupPolicy')
        FolderRedirDurationSec    = Format-Metric (Resolve-PhaseValue $folderRedirDurSec  $frResolve.Mode       'FolderRedirection')
        ProfileLoadDurationSec    = Format-Metric (Resolve-PhaseValue $profileDurationSec $profStartSolve.Mode  'Profile')
        FSLogixAttachDurationSec  = Format-Metric (Resolve-PhaseValue $fslogixDurationSec $fsMode               'FSLogix')
        ActiveSetupDurationSec    = Format-Metric (Resolve-PhaseValue $activeSetupDurSec  $asStartSolve.Mode    'ActiveSetup')
        AppXLoadDurationSec       = Format-Metric (Resolve-PhaseValue $appxDurSec         $appxSolve.Mode       'AppX')
        PrintersMappedCount       = Format-Metric (Resolve-PhaseValue $printerCount       $printSolve.Mode      'PrintService')
        PrinterMappingDurationSec = Format-Metric (Resolve-PhaseValue $printerDurSec      $printSolve.Mode      'PrintService')
        LogonTaskCount            = Format-Metric (Resolve-PhaseValue $logonTaskCount     $taskSolve.Mode       'TaskScheduler')
        LogonTaskTotalDurationSec = Format-Metric (Resolve-PhaseValue $logonTaskTotalSec  $taskSolve.Mode       'TaskScheduler')
        DataCollectedAt           = Format-Stamp  (Get-Date)
        CollectorVersion          = $script:Version
    }

    # Multi-session additions. Existing sensors ignore value names they do not read.
    $record['Sid']              = if ($Session.Sid) { $Session.Sid } else { 'Unknown' }
    $record['SessionId']        = Format-Metric $Session.SessionId
    $record['SessionType']      = $Session.SessionType
    $record['SourceAddress']    = $Session.Source
    $record['SessionIsLive']    = [string]$Session.IsLive
    $record['LogonTimeUtc']     = Format-StampUtc $logonTime
    $record['ConcurrentLogons'] = Format-Metric $ConcurrentLogons
    $record['ShellReadySource'] = $shellSource

    # Why each phase reports what it reports. Without this, a wrong provider name and a
    # genuinely unmeasurable phase are indistinguishable -- which is how two headline
    # metrics in the single-session collector stayed broken without anyone noticing.
    $record['PhaseDiagnostics'] = (($diag.Keys | ForEach-Object { "$_=$($diag[$_])" }) -join ';')

    # Still inside the window where missing events could yet appear, so mark the record
    # for one more look on a later sweep rather than freezing an incomplete measurement.
    $required    = @('TotalLogonDurationSec', 'ProfileLoadDurationSec')
    $incomplete  = @($required | Where-Object { $record[$_] -eq 'Unknown' }).Count -gt 0
    $insideFlush = ((Get-Date) - $logonTime).TotalMinutes -lt $script:PhaseWindowMinutes
    $record['Provisional'] = [string]($incomplete -and $insideFlush)
    #endregion

    return [PSCustomObject]@{
        Session = $Session
        Values  = $record
    }
}
#endregion

#region --- Registry persistence ---
# Per-user records are kept indefinitely otherwise, which on a session host means one
# key per person who has ever logged on. Bounded instead.
$script:RecordRetentionDays = 30

function Set-RegistryRecord {
    param(
        [string]$Path,
        $Values
    )

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null
    }

    # Registry writes are the one place a silenced error would be invisible and fatal
    # to every downstream sensor, so failures are counted and surfaced.
    $failures = 0
    foreach ($name in $Values.Keys) {
        Set-ItemProperty -Path $Path -Name $name -Value ([string]$Values[$name]) -Type String `
            -Force -ErrorAction SilentlyContinue -ErrorVariable writeErr
        if ($writeErr) { $failures++ }
    }
    return $failures
}

function Write-SessionRecord {
    param($Measurement)

    $sid = $Measurement.Values['Sid']
    if ([string]::IsNullOrWhiteSpace($sid) -or $sid -eq 'Unknown') {
        # Without a SID there is no stable key to file the record under. The flat key
        # still receives it if it is the newest logon.
        return 0
    }

    $values = [ordered]@{}
    foreach ($name in $Measurement.Values.Keys) { $values[$name] = $Measurement.Values[$name] }

    # Attempt count drives re-measurement of provisional records, so it accumulates
    # across sweeps rather than resetting each time.
    $key      = "$($script:SessionsRoot)\$sid"
    $existing = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    $attempts = 0
    if ($existing) {
        $storedLogon = ConvertFrom-StampUtc ([string]$existing.LogonTimeUtc)
        if ($storedLogon -and [math]::Abs(($storedLogon - $Measurement.Session.LogonTime).TotalSeconds) -le 2) {
            [void][int]::TryParse([string]$existing.MeasureAttempts, [ref]$attempts)
        }
    }
    $values['MeasureAttempts'] = [string]($attempts + 1)

    return (Set-RegistryRecord -Path $key -Values $values)
}

# The flat key is the device's most recent logon, which is both what the existing
# sensors expect and the answer to "the last logged-on user". Guarded so a sweep that
# re-measures an older provisional record cannot move it backwards.
function Write-FlatRecord {
    param($Measurement)

    $existing = Get-ItemProperty -Path $script:RegRoot -ErrorAction SilentlyContinue
    if ($existing) {
        $storedLogon = ConvertFrom-StampUtc ([string]$existing.LogonTimeUtc)
        if ($storedLogon -and $storedLogon -gt $Measurement.Session.LogonTime) {
            return -1
        }
    }

    return (Set-RegistryRecord -Path $script:RegRoot -Values $Measurement.Values)
}

function Remove-StaleSessionRecords {
    if (-not (Test-Path $script:SessionsRoot)) { return 0 }

    $cutoff  = (Get-Date).AddDays(-$script:RecordRetentionDays)
    $removed = 0

    foreach ($key in (Get-ChildItem -Path $script:SessionsRoot -ErrorAction SilentlyContinue)) {
        $record = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $record) { continue }

        $logon = ConvertFrom-StampUtc ([string]$record.LogonTimeUtc)
        if ($null -ne $logon -and $logon -lt $cutoff) {
            Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }
    return $removed
}

# A Workspace ONE sensor returns one scalar per device, so a fifty-session host has to
# be reduced to a distribution somewhere. Doing it here means the sensors stay trivial
# and the reduction is auditable in the registry rather than hidden in a sensor.
function Write-Aggregate {
    param(
        [int]$WindowHours,
        [object[]]$Current = @()
    )

    $cutoff  = (Get-Date).AddHours(-$WindowHours)
    $samples = New-Object 'System.Collections.Generic.List[double]'
    $byKey   = [ordered]@{}

    foreach ($key in (Get-ChildItem -Path $script:SessionsRoot -ErrorAction SilentlyContinue)) {
        $record = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $record) { continue }

        $logon = ConvertFrom-StampUtc ([string]$record.LogonTimeUtc)
        if ($null -eq $logon -or $logon -lt $cutoff) { continue }

        $byKey[$key.PSChildName] = [PSCustomObject]@{
            Username    = [string]$record.Username
            SessionType = [string]$record.SessionType
            Provisional = ([string]$record.Provisional -eq 'True')
            Total       = ConvertTo-Measurement ([string]$record.TotalLogonDurationSec)
            LogonTime   = $logon
        }
    }

    # This run's own measurements are merged in rather than re-read, so the aggregate
    # describes what was actually measured even when a registry write failed. Reading
    # the tree back alone would report zero sessions on an unelevated run, which looks
    # like "no logons" rather than "could not persist".
    foreach ($measurement in $Current) {
        if ($measurement.Session.LogonTime -lt $cutoff) { continue }

        $sid = [string]$measurement.Values['Sid']
        # Without a SID there is no per-user key, so fall back to a composite that
        # still prevents the same logon being counted twice.
        if ([string]::IsNullOrWhiteSpace($sid) -or $sid -eq 'Unknown') {
            $sid = "$($measurement.Values['Username'])|$($measurement.Values['SessionId'])"
        }

        # One entry per user, holding their newest logon. Deduplicating by user is what
        # keeps a single person's reconnects from dominating the device percentiles, but
        # it has to keep the newest of them rather than whichever was iterated last.
        if ($byKey.Contains($sid) -and $byKey[$sid].LogonTime -gt $measurement.Session.LogonTime) {
            continue
        }

        $byKey[$sid] = [PSCustomObject]@{
            Username    = [string]$measurement.Values['Username']
            SessionType = [string]$measurement.Values['SessionType']
            Provisional = ([string]$measurement.Values['Provisional'] -eq 'True')
            Total       = ConvertTo-Measurement ([string]$measurement.Values['TotalLogonDurationSec'])
            LogonTime   = $measurement.Session.LogonTime
        }
    }

    $sessions = @($byKey.Values)

    foreach ($session in $sessions) {
        if ($null -ne $session.Total) { $samples.Add($session.Total) }
    }

    $values = [ordered]@{
        LastRun          = Format-Stamp (Get-Date)
        CollectorVersion = $script:Version
        WindowHours      = Format-Metric $WindowHours
        SessionCount     = Format-Metric $sessions.Count
        SampleCount      = Format-Metric $samples.Count
        ConsoleSessions  = Format-Metric @($sessions | Where-Object { $_.SessionType -eq 'Console' }).Count
        RemoteSessions   = Format-Metric @($sessions | Where-Object { $_.SessionType -eq 'Remote'  }).Count
        ProvisionalCount = Format-Metric @($sessions | Where-Object { $_.Provisional }).Count
    }

    if ($samples.Count -gt 0) {
        $array   = $samples.ToArray()
        $slowest = @($sessions | Where-Object { $null -ne $_.Total } | Sort-Object Total -Descending)[0]

        $values['TotalLogonP50Sec']  = Format-Metric (Get-Percentile -Values $array -Percentile 50)
        $values['TotalLogonP95Sec']  = Format-Metric (Get-Percentile -Values $array -Percentile 95)
        $values['TotalLogonMaxSec']  = Format-Metric ([math]::Round(($array | Measure-Object -Maximum).Maximum, 2))
        $values['TotalLogonMeanSec'] = Format-Metric ([math]::Round(($array | Measure-Object -Average).Average, 2))
        $values['SlowestUser']       = $slowest.Username
        $values['SlowestLogonSec']   = Format-Metric $slowest.Total
    }
    else {
        # No measurement in the window is not a zero. Sentinels, so a sensor reports
        # "no data" rather than a flattering number nobody earned.
        $values['TotalLogonP50Sec']  = 'Unknown'
        $values['TotalLogonP95Sec']  = 'Unknown'
        $values['TotalLogonMaxSec']  = 'Unknown'
        $values['TotalLogonMeanSec'] = 'Unknown'
        $values['SlowestUser']       = 'Unknown'
        $values['SlowestLogonSec']   = 'Unknown'
    }

    [void](Set-RegistryRecord -Path $script:AggRoot -Values $values)
    return $values
}
#endregion

#region --- Registry readback ---
# Registry enumeration order is not insertion order, so without a declared order the
# dump reshuffles between runs and the eighteen values a sensor reads are scattered
# among the multi-session additions. Known names print first, in record order.
$script:RecordValueOrder = @(
    'Username', 'LogonTime', 'ShellReadyTime', 'TotalLogonDurationSec',
    'GPStartTime', 'GPDurationSec', 'GPScriptsDurationSec', 'FolderRedirDurationSec',
    'ProfileLoadDurationSec', 'FSLogixAttachDurationSec', 'ActiveSetupDurationSec',
    'AppXLoadDurationSec', 'PrintersMappedCount', 'PrinterMappingDurationSec',
    'LogonTaskCount', 'LogonTaskTotalDurationSec', 'DataCollectedAt', 'CollectorVersion',
    'Sid', 'SessionId', 'SessionType', 'SourceAddress', 'SessionIsLive',
    'LogonTimeUtc', 'ConcurrentLogons', 'ShellReadySource', 'PhaseDiagnostics',
    'Provisional', 'MeasureAttempts'
)

# The provider's own properties, which are not values an admin wrote or a sensor reads.
$script:RegistryMetaNames = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')

function Write-RegistryValues {
    param(
        [string]$Path,
        [string]$Indent = '     '
    )

    if (-not (Test-Path $Path)) {
        Write-Output "$Indent(key does not exist)"
        return
    }

    $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        Write-Output "$Indent(key could not be read)"
        return
    }

    $names = @($item.PSObject.Properties |
        Where-Object { $script:RegistryMetaNames -notcontains $_.Name } |
        ForEach-Object { $_.Name })

    if ($names.Count -eq 0) {
        Write-Output "$Indent(no values)"
        return
    }

    $ordered = @($names | Sort-Object {
        $index = $script:RecordValueOrder.IndexOf($_)
        if ($index -lt 0) { [int]::MaxValue } else { $index }
    }, { $_ })

    $width = ($ordered | Measure-Object -Property Length -Maximum).Maximum
    foreach ($name in $ordered) {
        Write-Output ("$Indent{0} : {1}" -f $name.PadRight($width), [string]$item.$name)
    }
}

# Everything this script wrote, re-read from the registry. Re-reading rather than
# echoing the in-memory record is the point: a write that silently failed shows up here
# as a stale or absent value, which is exactly what an admin verifying a deployment
# needs to see.
function Show-RegistryState {
    # Capped to match the MaxSessions default so an ordinary sweep prints every record
    # it wrote, while a host with hundreds of stored users does not bury the summary.
    # The count omitted is always reported.
    param([int]$MaxSessionsShown = 50)

    Write-Output ''
    Write-Output '-- Registry readback ------------------------------------------------'
    Write-Output "   [$($script:RegRoot)]   (most recent logon -- what the existing sensors read)"
    Write-RegistryValues -Path $script:RegRoot

    if (Test-Path $script:SessionsRoot) {
        $keys = @(Get-ChildItem -Path $script:SessionsRoot -ErrorAction SilentlyContinue)
        Write-Output ''
        Write-Output "   [$($script:SessionsRoot)]   ($($keys.Count) per-user record(s))"

        $shown = 0
        foreach ($key in $keys) {
            if ($shown -ge $MaxSessionsShown) {
                Write-Output "     ... $($keys.Count - $shown) further record(s) not shown"
                break
            }
            $record = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            Write-Output ''
            Write-Output "     $($key.PSChildName)  ($([string]$record.Username))"
            Write-RegistryValues -Path $key.PSPath -Indent '       '
            $shown++
        }
    }
    else {
        Write-Output ''
        Write-Output "   [$($script:SessionsRoot)]   (no per-user records written)"
    }

    Write-Output ''
    Write-Output "   [$($script:AggRoot)]   (device distribution -- what the logon_agg_* sensors read)"
    Write-RegistryValues -Path $script:AggRoot
    Write-Output '---------------------------------------------------------------------'
}
#endregion

#region --- Capture orchestration ---
function Invoke-MultiSessionCapture {
    param(
        [string]$Scope,
        [int]$Lookback,
        [int]$Limit,
        [string]$Target,
        [string]$Exclude,
        [int]$WindowHours,
        [int]$BudgetSeconds
    )

    Resolve-EventSources

    Write-Output ''
    Write-Output '-- Event source resolution ------------------------------------------'
    foreach ($key in $script:SourceTable.Keys) {
        $state = $script:SourceState[$key]
        Write-Output ("   {0,-19} {1,-14} via {2}" -f $key, $state.Status, $state.Resolved)
    }

    if ($script:SourceState['Logon'].Status -ne 'OK') {
        Write-Warning 'TerminalServices-LocalSessionManager is unavailable. Sessions cannot be enumerated.'
        return
    }

    $since     = (Get-Date).AddHours(-$Lookback)
    $inventory = Get-SessionInventory -Since $since

    Write-Output ''
    Write-Output ("-- Sessions: {0} in the last {1}h, scope {2} ------------------------" -f $inventory.Count, $Lookback, $Scope)

    if ($inventory.Count -eq 0) {
        Write-Warning "No interactive logons found in the last $Lookback hour(s). Nothing to measure."
        return
    }

    $inScope = Select-SessionsInScope -Sessions $inventory -Scope $Scope -Target $Target `
                   -Exclude $Exclude -Limit $Limit

    if ($inScope.Count -eq 0) {
        Write-Output '   No sessions in scope need measuring. Refreshing the aggregate only.'
        $agg = Write-Aggregate -WindowHours $WindowHours
        Write-Output ("   Aggregate: {0} session(s), P95 {1}" -f $agg.SessionCount, (Format-WithUnit $agg.TotalLogonP95Sec))
        return
    }

    # One query per source across the whole span. Correlation happens in memory, so
    # cost is flat in the number of sessions rather than linear.
    $harvestStart = (@($inScope | Sort-Object LogonTime)[0]).LogonTime.AddSeconds(-60)
    $harvestEnd   = (@($inScope | Sort-Object LogonTime -Descending)[0]).LogonTime.AddMinutes($script:PhaseWindowMinutes)
    if ($harvestEnd -gt (Get-Date)) { $harvestEnd = (Get-Date).AddMinutes(1) }

    $eventSets = @{}
    foreach ($key in $script:SourceTable.Keys) {
        if ($key -eq 'Logon') { continue }
        $eventSets[$key] = Get-EventSet -SourceKey $key -StartTime $harvestStart -EndTime $harvestEnd
    }

    $shellStarts = Get-ShellStartBySession

    $stopwatch   = [System.Diagnostics.Stopwatch]::StartNew()
    $measured    = @()
    $skipped     = 0

    foreach ($session in $inScope) {
        if ($stopwatch.Elapsed.TotalSeconds -gt $BudgetSeconds) {
            # Stop cleanly and leave the rest for the next sweep rather than being
            # killed mid-write by the task's execution time limit.
            $skipped = $inScope.Count - $measured.Count
            Write-Warning "Time budget of $BudgetSeconds s reached. $skipped session(s) deferred to the next run."
            break
        }

        # Counted against the full inventory, not just the sessions in scope: a logon
        # we are not measuring still overlaps the time-only phases of one we are.
        $phaseEnd   = $session.LogonTime.AddMinutes($script:PhaseWindowMinutes)
        $concurrent = @($inventory | Where-Object {
            $_.LogonTime -ge $session.LogonTime.AddSeconds(-30) -and $_.LogonTime -le $phaseEnd
        }).Count

        $measured += Measure-Session -Session $session -EventSets $eventSets `
                         -ShellStarts $shellStarts -ConcurrentLogons $concurrent
    }
    $stopwatch.Stop()

    #region Persist
    $writeFailures = 0
    foreach ($measurement in $measured) {
        $writeFailures += [math]::Max(0, (Write-SessionRecord -Measurement $measurement))
    }

    $newest = @($measured | Sort-Object { $_.Session.LogonTime } -Descending)[0]
    $flat   = Write-FlatRecord -Measurement $newest
    if ($flat -gt 0) { $writeFailures += $flat }

    # Only non-provisional records advance the mark, so a logon measured before its
    # events flushed is revisited instead of being skipped forever.
    $settled = @($measured | Where-Object { $_.Values['Provisional'] -ne 'True' })
    if ($settled.Count -gt 0) {
        $highWater = (@($settled | Sort-Object { $_.Session.LogonTime } -Descending)[0]).Session.LogonTime
        [void](Set-RegistryRecord -Path $script:RegRoot -Values @{
            LastProcessedLogon = Format-StampUtc $highWater
        })
    }

    $pruned = Remove-StaleSessionRecords
    $agg    = Write-Aggregate -WindowHours $WindowHours -Current $measured
    #endregion

    #region Report
    Write-Output ''
    Write-Output '-- Measured ---------------------------------------------------------'
    Write-Output ("   {0,-28} {1,-4} {2,-8} {3,-10} {4,-10} {5}" -f 'User', 'Sess', 'Type', 'Total(s)', 'Profile(s)', 'Logon')
    foreach ($measurement in ($measured | Sort-Object { $_.Session.LogonTime } -Descending)) {
        Write-Output ("   {0,-28} {1,-4} {2,-8} {3,-10} {4,-10} {5}" -f
            $measurement.Values['Username'],
            $measurement.Values['SessionId'],
            $measurement.Values['SessionType'],
            $measurement.Values['TotalLogonDurationSec'],
            $measurement.Values['ProfileLoadDurationSec'],
            $measurement.Values['LogonTime'])
    }

    Write-Output ''
    Write-Output '-- Aggregate --------------------------------------------------------'
    Write-Output ("   Window {0}h   Sessions {1}   Samples {2}   Console {3}   Remote {4}" -f
        $agg.WindowHours, $agg.SessionCount, $agg.SampleCount, $agg.ConsoleSessions, $agg.RemoteSessions)
    Write-Output ("   Total logon  P50 {0}   P95 {1}   Max {2}   Mean {3}" -f
        (Format-WithUnit $agg.TotalLogonP50Sec), (Format-WithUnit $agg.TotalLogonP95Sec),
        (Format-WithUnit $agg.TotalLogonMaxSec), (Format-WithUnit $agg.TotalLogonMeanSec))
    Write-Output ("   Slowest      {0} at {1}" -f $agg.SlowestUser, (Format-WithUnit $agg.SlowestLogonSec))
    Write-Output '---------------------------------------------------------------------'

    $summary = "Measured $($measured.Count) session(s) in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s"
    if ($skipped -gt 0) { $summary += ", $skipped deferred" }
    if ($pruned  -gt 0) { $summary += ", $pruned stale record(s) pruned" }

    # Reporting success after a failed write would leave an operator believing sensors
    # have fresh data when the key is empty or stale. Say what actually happened.
    if ($writeFailures -eq 0) {
        Write-Output "$summary. Results at '$($script:RegRoot)'."
    }
    else {
        Write-Output "$summary, but $writeFailures registry value(s) could not be written to '$($script:RegRoot)' (elevation required?)."
    }
    #endregion
}
#endregion

#region --- Scheduled task deployment ---
function Install-MultiSessionTask {
    [CmdletBinding()]
    param(
        [string]$Scope,
        [int]$Lookback,
        [int]$Limit,
        [string]$Exclude,
        [int]$WindowHours,
        [int]$BudgetSeconds,
        [int]$Repeat
    )

    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        Write-Warning 'Cannot determine script path ($PSCommandPath is empty). Run from a saved .ps1 file.'
        return
    }

    if (-not (Test-Path $script:ToolsDir)) {
        New-Item -Path $script:ToolsDir -ItemType Directory -Force | Out-Null
    }

    $destScript = Join-Path $script:ToolsDir $script:ScriptName
    Copy-Item -Path $PSCommandPath -Destination $destScript -Force

    # Every setting is passed explicitly so the task can never inherit a machine-level
    # environment variable and re-deploy or re-configure at every logon. Logging setup
    # is a deployment-time concern, not a per-logon one. -Command rather than -File
    # because -File passes $false as the literal string '$false', which a [bool]
    # parameter reads as true.
    $arguments = @(
        "-DeployMode RunNow"
        "-SessionScope $Scope"
        "-LookbackHours $Lookback"
        "-MaxSessions $Limit"
        "-AggregateWindowHours $WindowHours"
        "-TimeBudgetSeconds $BudgetSeconds"
        "-ConfigureLoggingFirst `$false"
    )
    if (-not [string]::IsNullOrWhiteSpace($Exclude)) {
        $arguments += "-ExcludeUserPattern '$($Exclude.Replace("'", "''"))'"
    }

    $taskCommand = "& '$destScript' $($arguments -join ' ')"
    $action = New-ScheduledTaskAction `
        -Execute  'powershell.exe' `
        -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$taskCommand`""

    # Two triggers. The logon trigger catches a single user's logon promptly; the
    # repeating trigger is what actually carries a session host, where logons arrive
    # concurrently and a single-shot run would miss most of them.
    $logonTrigger       = New-ScheduledTaskTrigger -AtLogOn
    $logonTrigger.Delay = 'PT30S'

    $repeatTrigger = $null
    try {
        $repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes $Repeat) `
            -RepetitionDuration ([TimeSpan]::MaxValue) -ErrorAction Stop
    }
    catch {
        # Some builds reject TimeSpan::MaxValue as an indefinite duration.
        $repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes $Repeat) `
            -RepetitionDuration (New-TimeSpan -Days 3650)
    }

    $triggers = @($logonTrigger)
    if ($repeatTrigger) { $triggers += $repeatTrigger }

    $principal = New-ScheduledTaskPrincipal `
        -UserId    'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel  Highest

    # IgnoreNew is correct here, not a limitation: the sweep is catch-up capable, so a
    # run skipped because one is already in flight loses nothing -- the next sweep picks
    # up every logon still past the high-water mark. The limit allows the configured
    # budget plus headroom to finish writing.
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Seconds ($BudgetSeconds + 120)) `
        -MultipleInstances  IgnoreNew `
        -Hidden

    $existing = Get-ScheduledTask -TaskName $script:TaskName -TaskPath '\DEXTools\' -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $script:TaskName -TaskPath '\DEXTools\' -Confirm:$false
    }

    Register-ScheduledTask `
        -TaskName    $script:TaskName `
        -TaskPath    '\DEXTools\' `
        -Action      $action `
        -Trigger     $triggers `
        -Principal   $principal `
        -Settings    $settings `
        -Description "Sweeps per-session logon duration metrics into HKLM at each logon and every $Repeat minutes. Deployed by WorkspaceONE." | Out-Null

    # Registering a SYSTEM principal needs elevation, and $ErrorActionPreference is
    # SilentlyContinue, so a refused registration returns quietly. Announcing success
    # on the strength of having called the cmdlet would leave an operator believing a
    # sweep is scheduled when nothing is. Confirm it exists.
    $registered = Get-ScheduledTask -TaskName $script:TaskName -TaskPath '\DEXTools\' -ErrorAction SilentlyContinue
    if (-not $registered) {
        Write-Warning "Scheduled task '\DEXTools\$($script:TaskName)' was NOT registered. Registering a SYSTEM task requires elevation -- run this as SYSTEM or from an elevated session."
        Write-Output "  Worker script was still copied to: $destScript"
        return
    }

    Write-Output "Scheduled task '\DEXTools\$($script:TaskName)' registered."
    Write-Output "  Worker script : $destScript"
    Write-Output "  Triggers      : AtLogOn (30s delay) + every $Repeat minute(s)"
    Write-Output "  Scope         : $Scope, lookback ${Lookback}h, max $Limit session(s)"
    Write-Output "  Runs as       : $($registered.Principal.UserId)"
}
#endregion

#region --- Logging configuration ---
function Enable-DEXAuditLogs {
    <#
    .SYNOPSIS
        Enables the optional Windows event logs used by this collector. Safe to run
        repeatedly -- already-enabled logs are reported and skipped.
    .PARAMETER Force
        Runs even when the completion marker is already set. Used by DeployMode
        ConfigureLogging, where the admin has explicitly asked for the work.
    #>
    [CmdletBinding()]
    param([switch]$Force)

    if (-not $Force) {
        $marker = (Get-ItemProperty -Path $script:RegRoot -Name 'AuditLogsConfiguredAt' `
                      -ErrorAction SilentlyContinue).AuditLogsConfiguredAt
        if (-not [string]::IsNullOrWhiteSpace($marker)) {
            Write-Output "Audit logs already configured at $marker. Skipping."
            return
        }
    }

    # Logs that are disabled by default but required for full metric coverage.
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
        }
        else {
            try {
                wevtutil.exe sl $target.LogName /e:true 2>&1 | Out-Null
                $verify = Get-WinEvent -ListLog $target.LogName -ErrorAction SilentlyContinue
                if ($verify.IsEnabled) {
                    Write-Output "  [ENABLED]   $($target.LogName)"
                    Write-Output "              Now enabled $($target.Description)"
                }
                else {
                    Write-Output "  [FAILED]    $($target.LogName)"
                    Write-Output "              wevtutil returned success but log still reports disabled."
                }
            }
            catch {
                Write-Output "  [ERROR]     $($target.LogName)"
                Write-Output "              $_"
            }
        }
        Write-Output ''
    }

    # Marker makes ConfigureLoggingFirst a one-time cost rather than a wevtutil call on
    # every single sweep.
    if (-not (Test-Path $script:RegRoot)) {
        New-Item -Path $script:RegRoot -Force | Out-Null
    }
    Set-ItemProperty -Path $script:RegRoot -Name 'AuditLogsConfiguredAt' `
        -Value (Format-Stamp (Get-Date)) -Type String -Force -ErrorAction SilentlyContinue

    Write-Output '=== Configuration complete ==='
    Write-Output 'Re-run with -DeployMode RunNow or DeployScheduledTask when ready.'
}
#endregion

#region --- Entry point ---
Write-Output ''
Write-Output "Measure-LogonDurationMultiSession $($script:Version)  mode=$DeployMode  $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"

switch ($DeployMode) {
    'RunNow' {
        if ($ConfigureLoggingFirst) { Enable-DEXAuditLogs }
        Invoke-MultiSessionCapture `
            -Scope         $SessionScope `
            -Lookback      $LookbackHours `
            -Limit         $MaxSessions `
            -Target        $TargetUser `
            -Exclude       $ExcludeUserPattern `
            -WindowHours   $AggregateWindowHours `
            -BudgetSeconds $TimeBudgetSeconds
    }
    'DeployScheduledTask' {
        if ($ConfigureLoggingFirst) { Enable-DEXAuditLogs }
        # A task that only measured the newest logon would miss most of a session
        # host's traffic, so the deployed default sweeps unless told otherwise.
        $taskScope = if ($PSBoundParameters.ContainsKey('SessionScope')) { $SessionScope } else { 'AllSince' }
        Install-MultiSessionTask `
            -Scope         $taskScope `
            -Lookback      $LookbackHours `
            -Limit         $MaxSessions `
            -Exclude       $ExcludeUserPattern `
            -WindowHours   $AggregateWindowHours `
            -BudgetSeconds $TimeBudgetSeconds `
            -Repeat        $RepeatMinutes
    }
    'ConfigureLogging' {
        # Explicit request, so the marker does not suppress it.
        Enable-DEXAuditLogs -Force
    }
}

# Printed for every mode, not just a capture: after DeployScheduledTask it shows what
# the sensors will read until the first sweep runs, and after ConfigureLogging it
# confirms the marker landed. Unconditional, because the readback is the cheapest
# answer to "did this actually do anything" and a logon-time run writing it to the
# task's output costs nothing.
Show-RegistryState
#endregion
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw. Inputs arrive as environment
# variables and are bound to the function's parameters below.
#
# $args is splatted so the script is also callable with ordinary named parameters from
# a console or a scheduled task. Without the splat a script with no script-scope param
# block silently discards every argument it is given, leaving only the environment-
# variable path working -- which is how the examples in this file's help would read
# correctly and do nothing.

Measure-LogonDurationMultiSession @args
Exit 0
