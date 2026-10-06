#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only discovery probe for Omnissa App Volumes package attach timing. Collects
    the evidence needed to build a mount-duration collector, without measuring anything
    itself and without changing the device.

.DESCRIPTION
    App Volumes attach timing has to be mined from the agent's own log and event stream,
    and the exact markers are not documented or discoverable from a manifest: the
    svservice event provider ships no event metadata (Events.Count is 0), so its event
    IDs are opaque numbers whose meaning is only visible in the message text. The
    driver's ETW manifest defines three events -- driver load, unload, and injection
    registration failure -- none of which bracket a volume attach.

    So the markers must be read off a machine that has actually attached packages. This
    script collects them. It writes one report file and changes nothing else: no
    registry writes, no service calls, no event log configuration. Safe to dot-source,
    and it never calls exit.

    What it gathers:

      1. Agent identity -- install path (Omnissa and legacy CloudVolumes layouts are
         both probed), version from VERSION*.txt and the binary, service states.
      2. Agent configuration from the svservice Parameters key, which says whether
         packages are attached directly, kept local, or delivered as MSIX app attach --
         each of which produces a different log trail. The license blob is dropped.
      3. Every svservice event ID present in the Application log, with counts and a
         sample message, so the attach-related IDs can be identified by their text.
      4. Interactive logons from TerminalServices-LocalSessionManager, used as the
         anchor for every window below. Multi-session hosts get one window per session.
      5. Every svservice.log line inside each logon window -- this is the attach
         sequence itself, and the single most useful artefact here.
      6. Volume and attach vocabulary across the whole log, deduplicated into message
         shapes with counts, so markers outside the sampled windows are still visible.
      7. OS-side disk arrival events in the same windows (VHDMP, Kernel-PnP, Partition,
         Ntfs, Disk). These matter as a fallback: if the agent's markers prove
         unreliable or change between versions, the disk arriving is vendor-independent.
      8. A clock-offset check. svservice.log stamps UTC; the Windows event log hands
         back local time. Measuring across the two without converting is an off-by-
         hours bug that looks like a plausible duration, so the offset is stated
         explicitly rather than assumed.

.PARAMETER LogonCount
    How many recent interactive logons to build windows around. Defaults to
    $env:LogonCount, then 3. On a multi-session host, raise it to capture several users'
    attach sequences -- concurrent attaches are exactly what a per-session collector has
    to disentangle.

.PARAMETER WindowMinutes
    Minutes after each logon to collect. Defaults to $env:WindowMinutes, then 10.

.PARAMETER LookbackHours
    How far back to look for logons. Defaults to $env:LookbackHours, then 168.

.PARAMETER Sanitize
    Replace identifying values with stable tokens before anything is written. Defaults
    to $true, because this report is meant to be sent to someone.

    Replacement is consistent, not blanket redaction: the same username always becomes
    the same token, so correlation between lines survives while the name does not.
    Masked are computer and domain names, usernames, IPv4 addresses, UNC server names,
    App Volumes manager addresses, and package file names. Preserved are every
    timestamp, duration, event ID, function name, and message structure -- everything
    the markers are read from.

    Pass $false to keep the raw text for local inspection.

.PARAMETER CopyFullLog
    Also write a complete copy of svservice.log alongside the report, sanitized under
    the same rules. Off by default because the file can be large; worth enabling if the
    windowed slices turn out not to contain an attach.

.PARAMETER OutputPath
    Report file path. Defaults to $env:OutputPath, then
    %SystemRoot%\Temp\AppVolumes_MountProbe_<host>_<timestamp>.txt, matching where the
    other scripts in this repo log.

.PARAMETER MaxLogLines
    Cap on svservice.log lines emitted per logon window. Defaults to 4000. A guard
    against a pathological log, not an expected limit.

.EXAMPLE
    .\Get-AppVolumesMountProbe.ps1

    The normal case: three most recent logons, sanitized, report path printed at the end.

.EXAMPLE
    .\Get-AppVolumesMountProbe.ps1 -LogonCount 10 -CopyFullLog

    What to run on an RDSH host. Captures ten sessions' attach sequences and the full
    agent log, so concurrent attaches can be told apart.

.EXAMPLE
    .\Get-AppVolumesMountProbe.ps1 -Sanitize $false -OutputPath C:\Temp\raw.txt

    Unsanitized, for reading locally. Do not send this one anywhere.

.NOTES
    Script Name  : Get-AppVolumesMountProbe.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System (Administrator is enough; SYSTEM also works)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-10-06
    Timeout      : 120 seconds

    PowerShell 5.1 compatible. Read-only: writes only the report file.

    Run it as an administrator. The agent log lives under Program Files and the
    Parameters key under HKLM\SYSTEM, both of which a standard user cannot read -- the
    probe reports what it could not open rather than silently emitting an empty section.

    Verified against App Volumes agent 4.21.0.5081 for paths, log format, and provider
    identity. The attach markers themselves are what this probe exists to discover, so
    they are deliberately not hard-coded anywhere in it.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Get-AppVolumesMountProbe {
[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$LogonCount = $(
        $v = 0
        if ([int]::TryParse("$env:LogonCount".Trim(), [ref]$v) -and $v -ge 1 -and $v -le 100) { $v } else { 3 }
    ),

    [ValidateRange(1, 120)]
    [int]$WindowMinutes = $(
        $v = 0
        if ([int]::TryParse("$env:WindowMinutes".Trim(), [ref]$v) -and $v -ge 1 -and $v -le 120) { $v } else { 10 }
    ),

    [ValidateRange(1, 8760)]
    [int]$LookbackHours = $(
        $v = 0
        if ([int]::TryParse("$env:LookbackHours".Trim(), [ref]$v) -and $v -ge 1 -and $v -le 8760) { $v } else { 168 }
    ),

    [bool]$Sanitize = $(
        if ([string]::IsNullOrWhiteSpace($env:Sanitize)) { $true }
        elseif ($env:Sanitize.Trim() -in @('false', '0', 'no', 'n')) { $false }
        else { $true }
    ),

    [switch]$CopyFullLog = [bool](
        $env:CopyFullLog -and $env:CopyFullLog.Trim() -in @('true', '1', 'yes', 'y')
    ),

    [string]$OutputPath = $(
        if ([string]::IsNullOrWhiteSpace($env:OutputPath)) { '' } else { $env:OutputPath.Trim() }
    ),

    [ValidateRange(100, 100000)]
    [int]$MaxLogLines = 4000
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

#region --- Constants ---
# Both layouts are probed: 4.21 installs to the Omnissa path, older builds to the
# legacy CloudVolumes path, and an upgraded machine can have remnants of both.
$script:AgentRoots = @(
    'C:\Program Files\Omnissa\AppVolumes\Agent'
    'C:\Program Files (x86)\Omnissa\AppVolumes\Agent'
    'C:\Program Files (x86)\CloudVolumes\Agent'
    'C:\Program Files\CloudVolumes\Agent'
)

$script:ServiceNames = @('svservice', 'svdriver', 'avsubservice')

# Tolerant of a missing UTC marker: older agent builds stamp local time with no suffix,
# and a line that fails to parse must not take the whole slice with it.
$script:LogLineRegex = [regex]'^\[(?<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})(?<zone> UTC)?\]\s*\[(?<ctx>[^\]]*)\]\s*(?<msg>.*)$'

# Vocabulary worth pulling out of the log. Deliberately broad -- this is discovery, and
# a marker missed here is a phase the collector cannot measure.
$script:VolumeVocabulary = @(
    'attach', 'detach', 'mount', 'dismount', 'volume', 'package', 'appstack',
    'writable', 'vhd', 'vmdk', 'snapvolume', 'svd', 'csvdriver', 'installpackage',
    'addvolume', 'removevolume', 'lun', 'scsi', 'reparse', 'overlay'
)

# Console plumbing that contains the word "attach" but has nothing to do with volumes.
# Without this the vocabulary report is dominated by it.
$script:VocabularyNoise = @(
    'AttachToParentConsole', 'GetConsoleMode', 'GetStandardHandlesRedirectedState'
)

# OS-side disk arrival. A fallback measurement that does not depend on agent message
# text, which is the part most likely to change between agent versions.
$script:DiskSources = @(
    @{ Label = 'VHDMP';          LogName = 'Microsoft-Windows-VHDMP-Operational' }
    @{ Label = 'VHDMP/Admin';    LogName = 'Microsoft-Windows-VHDMP/Admin' }
    @{ Label = 'Kernel-PnP';     LogName = 'Microsoft-Windows-Kernel-PnP/Configuration' }
    @{ Label = 'Partition';      LogName = 'Microsoft-Windows-Partition/Diagnostic' }
    @{ Label = 'Ntfs';           LogName = 'Microsoft-Windows-Ntfs/Operational' }
    @{ Label = 'Disk';           LogName = 'Microsoft-Windows-Disk/Operational' }
    @{ Label = 'StorageDisk';    LogName = 'Microsoft-Windows-Storage-Disk/Operational' }
    @{ Label = 'System(disk)';   LogName = 'System'; Providers = @('disk', 'partmgr', 'volmgr', 'volsnap') }
)

$script:Version = '1.0.0'
$script:Report  = New-Object 'System.Collections.Generic.List[string]'
$script:Redactions = New-Object 'System.Collections.Generic.List[object]'
#endregion

#region --- Report buffer ---
function Add-Line {
    param([string]$Text = '')
    $script:Report.Add($Text)
}

function Add-Section {
    param([string]$Title)
    Add-Line ''
    Add-Line ('=' * 78)
    Add-Line "== $Title"
    Add-Line ('=' * 78)
}

function Add-SubSection {
    param([string]$Title)
    Add-Line ''
    # Parenthesised: without them PowerShell reads the trailing .PadRight() as a second
    # positional argument to Add-Line and silently drops it, leaving unpadded headers.
    Add-Line ("-- $Title ".PadRight(78, '-'))
}
#endregion

#region --- Sanitiser ---
# Consistent tokens rather than blanket redaction. The same username becomes the same
# token every time, so a reader can still follow which lines belong together -- which
# is the whole point of sending the log to someone.
function Register-Redaction {
    param([string]$Value, [string]$Token)
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    if ($Value.Length -lt 3) { return }
    if ($script:Redactions | Where-Object { $_.Value -eq $Value }) { return }
    $script:Redactions.Add([PSCustomObject]@{ Value = $Value; Token = $Token })
}

function Initialize-Redactions {
    Register-Redaction -Value $env:COMPUTERNAME -Token 'HOST01'
    Register-Redaction -Value $env:USERDOMAIN   -Token 'DOMAIN'
    Register-Redaction -Value $env:USERDNSDOMAIN -Token 'domain.local'

    $dnsDomain = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Domain
    Register-Redaction -Value $dnsDomain -Token 'domain.local'

    # Every local profile, so usernames in log paths are covered as well as the ones
    # with a current session.
    $index = 0
    foreach ($profilePath in (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
                                Where-Object { -not $_.Special } |
                                Select-Object -ExpandProperty LocalPath)) {
        $index++
        Register-Redaction -Value (Split-Path $profilePath -Leaf) -Token ("USER{0:D2}" -f $index)
    }

    # Manager addresses from the agent config.
    $params = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\svservice\Parameters' -ErrorAction SilentlyContinue
    if ($params) {
        $m = 0
        foreach ($property in $params.PSObject.Properties) {
            if ($property.Name -notlike 'Manager*') { continue }
            $m++
            $address = ([string]$property.Value) -replace ':\d+$', ''
            Register-Redaction -Value $address -Token ("AVMANAGER{0:D2}" -f $m)
        }
    }

    # Longest first, so a domain is not partly consumed by a shorter overlapping match.
    $sorted = @($script:Redactions | Sort-Object { $_.Value.Length } -Descending)
    $script:Redactions.Clear()
    foreach ($entry in $sorted) { $script:Redactions.Add($entry) }
}

function Protect-Text {
    param([string]$Text)
    if (-not $Sanitize -or [string]::IsNullOrEmpty($Text)) { return $Text }

    $out = $Text
    foreach ($entry in $script:Redactions) {
        $out = [regex]::Replace($out, [regex]::Escape($entry.Value), $entry.Token, 'IgnoreCase')
    }

    # Structural masks, applied after the named ones.
    $out = [regex]::Replace($out, '\b(?:\d{1,3}\.){3}\d{1,3}\b', 'IP-REDACTED')

    # UNC server names, but only at a real token boundary. The agent logs JSON in which
    # every path separator is escaped, so "C:\\Users\\bob" contains doubled backslashes
    # that a naive \\host\ pattern happily eats -- turning a local path into nonsense and
    # destroying the structure of exactly the messages worth reading.
    $out = [regex]::Replace($out, '(?<=^|[\s"''\[=(,;])\\\\([A-Za-z0-9._-]+)\\', '\\FILESERVER01\')

    # Package file names: keep the extension, since VHD versus VMDK changes the trail.
    # No spaces in the character class and no alphanumeric immediately before: with
    # either, "Attaching volume from package Office.vhd" matches from "Attaching"
    # onwards and the whole message is replaced by the token.
    $out = [regex]::Replace($out, '(?<![A-Za-z0-9])[A-Za-z0-9_.\-()]+\.(vhdx?|vmdk)\b', 'PACKAGE-REDACTED.$1', 'IgnoreCase')
    return $out
}
#endregion

#region --- Agent discovery ---
function Get-AgentInfo {
    $found = @()
    foreach ($root in $script:AgentRoots) {
        if (-not (Test-Path $root)) { continue }

        $exe     = Join-Path $root 'svservice.exe'
        $version = $null
        foreach ($versionFile in (Get-ChildItem (Join-Path $root 'VERSION*.txt') -ErrorAction SilentlyContinue)) {
            $version = ((Get-Content $versionFile.FullName -Raw -ErrorAction SilentlyContinue) -replace "`r?`n", ' | ').Trim()
            break
        }

        $found += [PSCustomObject]@{
            Root        = $root
            Exe         = $exe
            ExePresent  = (Test-Path $exe)
            FileVersion = (Get-Item $exe -ErrorAction SilentlyContinue).VersionInfo.FileVersion
            VersionText = $version
            LogDir      = (Join-Path $root 'Logs')
        }
    }
    return $found
}

function Write-AgentSection {
    param([object[]]$Agents)

    Add-Section 'Agent identity'

    if ($Agents.Count -eq 0) {
        Add-Line '  No App Volumes agent install directory found in any known location:'
        foreach ($root in $script:AgentRoots) { Add-Line "    $root" }
        Add-Line ''
        Add-Line '  If the agent is installed elsewhere, the attach markers will not be in this'
        Add-Line '  report. Check the svservice service ImagePath below for the real path.'
    }

    foreach ($agent in $Agents) {
        Add-Line "  Install root : $($agent.Root)"
        Add-Line "  svservice.exe: $(if ($agent.ExePresent) { 'present' } else { 'MISSING' })  FileVersion $($agent.FileVersion)"
        Add-Line "  VERSION file : $($agent.VersionText)"
        Add-Line "  Log dir      : $($agent.LogDir)"
        foreach ($file in (Get-ChildItem $agent.LogDir -File -ErrorAction SilentlyContinue)) {
            Add-Line ("    {0,-24} {1,12:N0} bytes   {2}" -f $file.Name, $file.Length, $file.LastWriteTime)
        }
        Add-Line ''
    }

    Add-SubSection 'Services'
    foreach ($name in $script:ServiceNames) {
        $key = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -ErrorAction SilentlyContinue
        if (-not $key) { Add-Line ("  {0,-14} not registered" -f $name); continue }
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        Add-Line ("  {0,-14} state={1,-10} start={2}" -f $name, $(if ($service) { $service.Status } else { 'n/a' }), $key.Start)
        Add-Line ("  {0,-14} image={1}" -f '', (Protect-Text ([string]$key.ImagePath)))
    }

    Add-SubSection 'MSIX app attach / other delivery binaries present'
    foreach ($agent in $Agents) {
        foreach ($binary in @('MSIXAppAttach.exe', 'avsubservice.exe', 'AppVolumes.exe', 'AppCapture.exe')) {
            $path = Join-Path $agent.Root $binary
            if (Test-Path $path) { Add-Line "  present: $binary" }
        }
    }
}
#endregion

#region --- Agent configuration ---
function Write-ConfigSection {
    Add-Section 'Agent configuration (svservice Parameters)'
    Add-Line '  Delivery mode is what decides which log trail an attach leaves, so these'
    Add-Line '  values determine what the collector should be looking for.'
    Add-Line ''

    foreach ($name in @('svservice', 'svdriver')) {
        $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$name\Parameters"
        Add-SubSection "$name\Parameters"

        if (-not (Test-Path $path)) {
            Add-Line '  (key not present -- or not readable without elevation)'
            continue
        }

        $params = Get-ItemProperty $path -ErrorAction SilentlyContinue
        if (-not $params) { Add-Line '  (unreadable -- run elevated)'; continue }

        foreach ($property in ($params.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | Sort-Object Name)) {
            # A licence token is not diagnostic data and has no business in a file
            # that gets emailed.
            if ($property.Name -match 'License|Licence') {
                Add-Line ("  {0,-34} <{1} bytes of licence data, omitted>" -f $property.Name, @($property.Value).Count)
                continue
            }
            $value = (@($property.Value) -join ' ')
            if ($value.Length -gt 400) { $value = $value.Substring(0, 400) + ' ...[truncated]' }
            Add-Line ("  {0,-34} {1}" -f $property.Name, (Protect-Text $value))
        }
    }
}
#endregion

#region --- svservice event provider ---
function Write-EventIdSection {
    param([object[]]$Events)

    Add-Section 'svservice event IDs in the Application log'
    Add-Line '  The provider ships no event metadata, so these IDs are opaque. The sample'
    Add-Line '  message is the only way to tell which ones bracket an attach.'
    Add-Line ''

    if ($Events.Count -eq 0) {
        Add-Line '  No svservice events found. Either the agent has never run, or the'
        Add-Line '  Application log has rolled over.'
        return
    }

    $oldest = ($Events | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated
    $newest = ($Events | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
    Add-Line "  $($Events.Count) event(s), $oldest .. $newest  (local time)"
    Add-Line ''

    foreach ($group in ($Events | Group-Object Id | Sort-Object { [int]$_.Name })) {
        $sample = (($group.Group[0].Message -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
        Add-Line ("  EID {0,-6} n={1,-6} {2}" -f $group.Name, $group.Count, (Protect-Text $sample.Trim()))
    }

    Add-SubSection 'Full message text, one example per event ID'
    foreach ($group in ($Events | Group-Object Id | Sort-Object { [int]$_.Name })) {
        Add-Line ''
        Add-Line "  --- EID $($group.Name) ---"
        foreach ($line in ($group.Group[0].Message -split "`n")) {
            if ($line.Trim()) { Add-Line "    $(Protect-Text $line.TrimEnd())" }
        }
    }
}
#endregion

#region --- Logon anchors ---
# Same source the logon-duration collectors use: properties are
# [DOMAIN\user, SessionId, SourceNetworkAddress], so one query yields the user, the
# session, and whether the session arrived locally or over the network.
function Get-LogonAnchors {
    param([int]$Hours, [int]$Count)

    $events = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
        Id        = @(21, 25)
        StartTime = (Get-Date).AddHours(-$Hours)
    } -ErrorAction SilentlyContinue

    $anchors = @()
    foreach ($evt in $events) {
        if ($evt.Properties.Count -lt 2) { continue }
        $account = [string]$evt.Properties[0].Value
        if ([string]::IsNullOrWhiteSpace($account)) { continue }
        if ($account -match '^(NT AUTHORITY|NT SERVICE|Window Manager|Font Driver Host)\\') { continue }

        $sessionId = 0
        if (-not [int]::TryParse([string]$evt.Properties[1].Value, [ref]$sessionId)) { continue }

        $anchors += [PSCustomObject]@{
            Account    = $account
            SessionId  = $sessionId
            LocalTime  = $evt.TimeCreated
            UtcTime    = $evt.TimeCreated.ToUniversalTime()
            Kind       = if ($evt.Id -eq 25) { 'reconnect' } else { 'logon' }
            Source     = if ($evt.Properties.Count -ge 3) { [string]$evt.Properties[2].Value } else { '' }
        }
    }

    return @($anchors | Sort-Object LocalTime -Descending | Select-Object -First $Count)
}
#endregion

#region --- svservice.log ---
function Get-ParsedLogLines {
    param([string]$Path)

    $parsed = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Test-Path $Path)) { return $parsed }

    foreach ($line in (Get-Content $Path -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $match = $script:LogLineRegex.Match($line)
        if (-not $match.Success) {
            # Continuation of a multi-line message; keep it, timestamped as unknown, so
            # a stack trace or JSON blob is not lost from the middle of a sequence.
            $parsed.Add([PSCustomObject]@{ Utc = $null; Context = ''; Message = $line; Raw = $line })
            continue
        }

        $stamp = [datetime]::MinValue
        $ok = [datetime]::TryParseExact(
            $match.Groups['ts'].Value, 'yyyy-MM-dd HH:mm:ss.fff',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$stamp)
        if (-not $ok) { continue }

        # The agent stamps UTC when it says so, and local time when it does not.
        $utc = if ($match.Groups['zone'].Success) { [datetime]::SpecifyKind($stamp, 'Utc') } else { $stamp.ToUniversalTime() }

        $parsed.Add([PSCustomObject]@{
            Utc     = $utc
            Context = $match.Groups['ctx'].Value
            Message = $match.Groups['msg'].Value
            Raw     = $line
        })
    }
    return $parsed
}

function Write-ClockSection {
    param([object[]]$LogLines, [object[]]$Events)

    Add-Section 'Clock offset check'
    Add-Line '  svservice.log stamps UTC; the Windows event log returns local time.'
    Add-Line '  Measuring across the two without converting produces a plausible-looking'
    Add-Line '  duration that is wrong by the UTC offset, so it is stated here explicitly.'
    Add-Line ''
    Add-Line "  Local time now            : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Add-Line "  UTC now                   : $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
    Add-Line "  Current UTC offset        : $([System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)))"
    Add-Line "  Time zone                 : $([System.TimeZoneInfo]::Local.Id)"

    $stamped = @($LogLines | Where-Object { $_.Utc })
    if ($stamped.Count -gt 0) {
        $newest = ($stamped | Sort-Object Utc -Descending | Select-Object -First 1).Utc
        Add-Line "  Newest svservice.log line : $($newest.ToString('yyyy-MM-dd HH:mm:ss.fff')) UTC"
    }
    if ($Events.Count -gt 0) {
        $newestEvent = ($Events | Sort-Object TimeCreated -Descending | Select-Object -First 1)
        Add-Line "  Newest svservice event    : $($newestEvent.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')) local = $($newestEvent.TimeCreated.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC"
    }
}

function Write-VocabularySection {
    param([object[]]$LogLines)

    Add-Section 'Volume and attach vocabulary across the whole log'
    Add-Line '  Message shapes, with digits normalised to # and counted. Markers outside'
    Add-Line '  the sampled logon windows still show up here.'
    Add-Line ''

    $pattern = ($script:VolumeVocabulary | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $noise   = ($script:VocabularyNoise  | ForEach-Object { [regex]::Escape($_) }) -join '|'

    $matched = @($LogLines | Where-Object {
        $_.Message -and
        [regex]::IsMatch($_.Message, $pattern, 'IgnoreCase') -and
        -not [regex]::IsMatch($_.Message, $noise, 'IgnoreCase')
    })

    Add-Line "  $($matched.Count) matching line(s) of $($LogLines.Count) total"
    Add-Line ''

    $shapes = $matched |
        ForEach-Object { [regex]::Replace((Protect-Text $_.Message), '\d+', '#') } |
        Group-Object | Sort-Object Count -Descending

    foreach ($shape in $shapes) {
        $text = $shape.Name
        if ($text.Length -gt 220) { $text = $text.Substring(0, 220) + ' ...' }
        Add-Line ("  n={0,-5} {1}" -f $shape.Count, $text)
    }
}

function Write-WindowSection {
    param([object[]]$LogLines, [object[]]$Anchors, [object[]]$Events)

    Add-Section 'Per-logon windows (the attach sequence)'
    Add-Line '  For each logon: every svservice.log line, every svservice event, and every'
    Add-Line '  OS-side disk arrival inside the window. This is the artefact the collector'
    Add-Line '  gets built from.'

    if ($Anchors.Count -eq 0) {
        Add-Line ''
        Add-Line "  No interactive logons found in the last $LookbackHours hour(s)."
        Add-Line '  Raise -LookbackHours, or run this after a fresh logon.'
        return
    }

    foreach ($anchor in $Anchors) {
        $startUtc = $anchor.UtcTime.AddSeconds(-60)
        $endUtc   = $anchor.UtcTime.AddMinutes($WindowMinutes)

        Add-Line ''
        Add-Line ('#' * 78)
        Add-Line "# $($anchor.Kind.ToUpper())  $(Protect-Text $anchor.Account)  session $($anchor.SessionId)  source $(Protect-Text $anchor.Source)"
        Add-Line "#   local $($anchor.LocalTime.ToString('yyyy-MM-dd HH:mm:ss'))   UTC $($anchor.UtcTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        Add-Line "#   window UTC $($startUtc.ToString('HH:mm:ss')) .. $($endUtc.ToString('HH:mm:ss'))"
        Add-Line ('#' * 78)

        #region svservice.log slice
        Add-SubSection 'svservice.log'
        $slice = @($LogLines | Where-Object { $_.Utc -and $_.Utc -ge $startUtc -and $_.Utc -le $endUtc })
        if ($slice.Count -eq 0) {
            Add-Line '  (no log lines in this window -- the log may have rolled, or the agent'
            Add-Line '   was not running for this logon)'
        }
        else {
            $emit = @($slice | Select-Object -First $MaxLogLines)
            foreach ($entry in $emit) {
                Add-Line ("  {0}  [{1}] {2}" -f $entry.Utc.ToString('HH:mm:ss.fff'), $entry.Context, (Protect-Text $entry.Message))
            }
            if ($slice.Count -gt $emit.Count) {
                Add-Line "  ... $($slice.Count - $emit.Count) further line(s) suppressed by -MaxLogLines"
            }
        }
        #endregion

        #region svservice events
        Add-SubSection 'svservice Application events'
        $windowEvents = @($Events | Where-Object {
            $_.TimeCreated.ToUniversalTime() -ge $startUtc -and $_.TimeCreated.ToUniversalTime() -le $endUtc
        } | Sort-Object TimeCreated)

        if ($windowEvents.Count -eq 0) {
            Add-Line '  (none)'
        }
        else {
            foreach ($evt in $windowEvents) {
                $first = (($evt.Message -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
                Add-Line ("  {0} UTC  EID {1,-6} {2}" -f $evt.TimeCreated.ToUniversalTime().ToString('HH:mm:ss.fff'), $evt.Id, (Protect-Text $first.Trim()))
            }
        }
        #endregion

        #region OS-side disk arrival
        Add-SubSection 'OS-side disk / volume arrival'
        Add-Line '  A vendor-independent fallback: if the agent markers move between versions,'
        Add-Line '  the disk still arrives. Disabled channels are reported, not skipped.'
        Add-Line ''

        foreach ($source in $script:DiskSources) {
            $log = Get-WinEvent -ListLog $source.LogName -ErrorAction SilentlyContinue
            if (-not $log) {
                Add-Line ("  {0,-16} channel not present" -f $source.Label)
                continue
            }
            if (-not $log.IsEnabled) {
                Add-Line ("  {0,-16} channel DISABLED (enable to capture this trail)" -f $source.Label)
                continue
            }

            $filter = @{
                LogName   = $source.LogName
                StartTime = $startUtc.ToLocalTime()
                EndTime   = $endUtc.ToLocalTime()
            }
            if ($source.Providers) { $filter['ProviderName'] = $source.Providers }

            $diskEvents = @(Get-WinEvent -FilterHashtable $filter -MaxEvents 80 -ErrorAction SilentlyContinue | Sort-Object TimeCreated)
            if ($diskEvents.Count -eq 0) {
                Add-Line ("  {0,-16} no events in window" -f $source.Label)
                continue
            }

            Add-Line ("  {0,-16} {1} event(s):" -f $source.Label, $diskEvents.Count)
            foreach ($group in ($diskEvents | Group-Object Id | Sort-Object { [int]$_.Name })) {
                $first = (($group.Group[0].Message -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
                $when  = $group.Group[0].TimeCreated.ToUniversalTime().ToString('HH:mm:ss.fff')
                Add-Line ("      EID {0,-6} n={1,-4} first@{2} UTC  {3}" -f $group.Name, $group.Count, $when, (Protect-Text $first.Trim()))
            }
        }
        #endregion
    }
}
#endregion

#region --- Volume snapshot ---
function Write-VolumeSection {
    Add-Section 'Current volume and disk snapshot'
    Add-Line '  What is attached right now, for comparison against the attach sequences above.'

    Add-SubSection 'Disks'
    foreach ($disk in (Get-Disk -ErrorAction SilentlyContinue | Sort-Object Number)) {
        Add-Line ("  disk {0,-3} {1,-12} {2,10:N0} MB  bus={3,-10} {4}" -f
            $disk.Number, $disk.OperationalStatus, ($disk.Size / 1MB), $disk.BusType, (Protect-Text [string]$disk.FriendlyName))
    }

    Add-SubSection 'Volumes'
    foreach ($volume in (Get-Volume -ErrorAction SilentlyContinue | Sort-Object DriveLetter)) {
        Add-Line ("  {0,-3} {1,-10} {2,10:N0} MB  {3}" -f
            $volume.DriveLetter, $volume.FileSystemType, ($volume.Size / 1MB), (Protect-Text [string]$volume.FileSystemLabel))
    }

    Add-SubSection 'App Volumes filesystem artefacts'
    foreach ($path in @('C:\SnapVolumesTemp', 'C:\SnapVolumesTemp.old', 'C:\SVROOT', 'C:\AppVolumesData')) {
        if (Test-Path $path) {
            $count = @(Get-ChildItem $path -ErrorAction SilentlyContinue).Count
            Add-Line "  present: $path  ($count immediate child item(s))"
        }
        else {
            Add-Line "  absent : $path"
        }
    }
}
#endregion

#region --- Main ---
# Built first, before anything is written. Protect-Text against an empty map is a no-op,
# so any Add-Line that sanitises before this point leaks the real value into a file whose
# entire purpose is to be sent to someone else.
if ($Sanitize) { Initialize-Redactions }

Add-Line "App Volumes mount-timing discovery probe v$($script:Version)"
Add-Line "Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') local / $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Add-Line "Host $(if ($Sanitize) { 'HOST01 (sanitised)' } else { $env:COMPUTERNAME })"
Add-Line "OS   $((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption)"
Add-Line "Settings: LogonCount=$LogonCount WindowMinutes=$WindowMinutes LookbackHours=$LookbackHours Sanitize=$Sanitize"

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$isElevated = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
                  [Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Line "Running as $(Protect-Text $identity.Name), elevated=$isElevated"
if (-not $isElevated) {
    Add-Line ''
    Add-Line '*** NOT ELEVATED. The agent log under Program Files and the Parameters key'
    Add-Line '*** under HKLM\SYSTEM are likely unreadable, so sections below may be empty.'
    Add-Line '*** Re-run as an administrator.'
}

if ($Sanitize) { Initialize-Redactions }

$agents = Get-AgentInfo
Write-AgentSection -Agents $agents
Write-ConfigSection

$svEvents = @(Get-WinEvent -FilterHashtable @{
    ProviderName = 'svservice'
    StartTime    = (Get-Date).AddHours(-$LookbackHours)
} -ErrorAction SilentlyContinue)
Write-EventIdSection -Events $svEvents

# The newest log wins when an upgraded machine has both layouts on disk.
$logPath  = $null
$logLines = New-Object 'System.Collections.Generic.List[object]'
$candidates = @()
foreach ($agent in $agents) {
    $candidate = Join-Path $agent.LogDir 'svservice.log'
    if (Test-Path $candidate) { $candidates += (Get-Item $candidate) }
}
if ($candidates.Count -gt 0) {
    $logPath  = (@($candidates | Sort-Object LastWriteTime -Descending)[0]).FullName
    $logLines = Get-ParsedLogLines -Path $logPath
}

Add-Section 'svservice.log'
if (-not $logPath) {
    Add-Line '  svservice.log not found under any agent install root.'
    Add-Line '  Without it the attach sequence cannot be read -- check the paths above.'
}
else {
    Add-Line "  Path   : $logPath"
    Add-Line "  Lines  : $($logLines.Count) parsed"
    $stamped = @($logLines | Where-Object { $_.Utc })
    if ($stamped.Count -gt 0) {
        Add-Line "  Span   : $((@($stamped | Sort-Object Utc)[0]).Utc.ToString('yyyy-MM-dd HH:mm:ss')) .. $((@($stamped | Sort-Object Utc -Descending)[0]).Utc.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
    }
}

Write-ClockSection    -LogLines $logLines -Events $svEvents
Write-VocabularySection -LogLines $logLines

$anchors = Get-LogonAnchors -Hours $LookbackHours -Count $LogonCount
Write-WindowSection -LogLines $logLines -Anchors $anchors -Events $svEvents
Write-VolumeSection

#region Closing notes
Add-Section 'What to send back'
Add-Line '  This whole file. The sections that determine whether a mount-duration'
Add-Line '  collector can be built at all are:'
Add-Line '    - "svservice event IDs in the Application log"  (which EIDs bracket an attach)'
Add-Line '    - "Per-logon windows"                           (the attach sequence itself)'
Add-Line '    - "Volume and attach vocabulary"                (markers outside the windows)'
Add-Line ''
Add-Line '  If the per-logon windows contain no attach activity, the most likely causes are'
Add-Line '  that the log has rolled over since the last logon, or that this host attaches'
Add-Line '  nothing. Re-run with -CopyFullLog after a fresh logon on a host that does.'
if ($Sanitize) {
    Add-Line ''
    Add-Line "  Sanitised: $($script:Redactions.Count) named value(s) tokenised, plus IPv4"
    Add-Line '  addresses, UNC server names and package file names. Timestamps, durations,'
    Add-Line '  event IDs, function names and message structure are untouched.'
}
#endregion

#region Write the report
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
    $hostLabel  = if ($Sanitize) { 'HOST01' } else { $env:COMPUTERNAME }
    $OutputPath = Join-Path "$env:SystemRoot\Temp" "AppVolumes_MountProbe_${hostLabel}_$stamp.txt"
}

$written = $true
try {
    $parent = Split-Path $OutputPath -Parent
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -Path $parent -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    Set-Content -Path $OutputPath -Value $script:Report -Encoding UTF8 -ErrorAction Stop
}
catch {
    $written = $false
    Write-Warning "Could not write the report to '$OutputPath': $($_.Exception.Message)"
}

if ($CopyFullLog -and $logPath) {
    $logCopy = [System.IO.Path]::ChangeExtension($OutputPath, $null) + 'svservice-full.log'
    try {
        if ($Sanitize) {
            $sanitised = foreach ($line in (Get-Content $logPath -ErrorAction Stop)) { Protect-Text $line }
            Set-Content -Path $logCopy -Value $sanitised -Encoding UTF8 -ErrorAction Stop
        }
        else {
            Copy-Item -Path $logPath -Destination $logCopy -Force -ErrorAction Stop
        }
        Write-Output "Full agent log copied to : $logCopy"
    }
    catch {
        Write-Warning "Could not copy the full agent log: $($_.Exception.Message)"
    }
}
#endregion

#region Console summary
Write-Output ''
Write-Output "-- App Volumes mount probe v$($script:Version) ------------------------------"
Write-Output ("   Agent install     : {0}" -f $(if ($agents.Count -gt 0) { $agents[0].Root } else { 'NOT FOUND' }))
Write-Output ("   Agent version     : {0}" -f $(if ($agents.Count -gt 0) { $agents[0].FileVersion } else { 'n/a' }))
Write-Output ("   svservice.log     : {0}" -f $(if ($logPath) { "$($logLines.Count) line(s)" } else { 'NOT FOUND' }))
Write-Output ("   svservice events  : {0} in the last {1}h, {2} distinct EID(s)" -f $svEvents.Count, $LookbackHours, @($svEvents | Group-Object Id).Count)
Write-Output ("   Logon windows     : {0}" -f $anchors.Count)
Write-Output ("   Elevated          : {0}" -f $isElevated)
Write-Output ("   Sanitised         : {0}" -f $Sanitize)
if ($written) {
    Write-Output ''
    Write-Output "   Report written to : $OutputPath"
    Write-Output '   Send that file back. Nothing on this device was modified.'
}
Write-Output '-----------------------------------------------------------------------'
#endregion
#endregion
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function to match the other scripts in this repo: the
# Workspace ONE script engine does not recognise a param block at script scope. $args is
# splatted so named parameters bind when it is run by hand, which without the splat a
# script with no script-scope param block silently discards.
#
# Deliberately no 'exit': this is a read-only diagnostic an admin runs interactively,
# and a script-scope exit would terminate their session when the file is dot-sourced or
# pasted into a console.

Get-AppVolumesMountProbe @args
