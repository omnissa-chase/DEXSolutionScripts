#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : hzn_agent_health
    Data Type    : String (JSON)
    Version      : 1.0.1
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-05 (1.0.1: session and Application events read through the .NET EventLogReader; Get-WinEvent fails in every form under Hub's ARM64 PowerShell 7.2 engine)
    Timeout      : One-time / run-once only. Self-enforced 25 s budget, 30 s UEM ceiling.
                   MUST NOT be scheduled as a recurring sensor.
    Built from   : VDI/Horizon/SPEC.md rev 1, section 7.1

    The complete Horizon Agent picture in one on-demand pull from the DEX console: every
    value the collector caches, measured live right now, plus the per-session rows with
    the client-name correlation key, the cached scores of the surrounding components
    (Related), and the next step. Reads no cache for its own component, so it works on a
    device where the collector has never run. Writes nothing.

    Phases, cheapest first, each checked against the budget: registry and services;
    session inventory; Blast/PCoIP counters (one sample); broker DNS and TCP (max 3
    hosts); Application-log errors; related caches; score. A phase skipped by the
    deadline reports -4 and TimedOut is true, in which case HealthScore is a floor.

    Sentinels: -1 unknown, -2 not applicable, -4 timed out. No nulls. Keys are fixed;
    the internal build may add keys (bump SchemaVersion), never rename or remove.

    The deduction table duplicates Invoke-HorizonAgentStateCollection.ps1 on purpose
    (this file must stay self-contained). Change both in the same edit;
    _AutomatedTesting/Test-HorizonScoreParity.ps1 asserts they agree. One divergence:
    TimeSyncStale here uses the W32Time registry (a sensor may not launch w32tm.exe).

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

$script:TimeoutSeconds = 25
$script:NetTimeoutMs = 2000
$script:MaxProbeHosts = 3
$script:EventLookbackHours = 24
$script:SessionLookbackHours = 72
$script:MaxEventsScanned = 2000
$script:MaxSessionRows = 10
# Thresholds identical to the collector.
$script:BlastRttWarnMs = 250; $script:BlastLossWarnPpm = 20000; $script:DisconnectedStaleMinutes = 480
$script:AgentErrorWarnCount = 10; $script:SyncStaleHours = 48

# KB resolution points, identical to the collector (VDI/Horizon/SPEC.md section 3).
$AgentRegistryRoots = @('HKLM:\SOFTWARE\Omnissa\Horizon\Agent', 'HKLM:\SOFTWARE\VMware, Inc.\VMware VDM\Agent')
$AgentServiceNames = @('wsnm'); $BlastServiceNames = @('VMBlast')
$AgentServiceDisplayPattern = '(?i)Horizon.*Agent|VMware View Agent'; $BlastServiceDisplayPattern = '(?i)Blast'
$FeatureServiceInclude = '(?i)Horizon|Blast|ThinPrint|TP AutoConnect|USB Arbitration|View Agent|Omnissa'
$FeatureServiceExclude = '(?i)VMware Tools|Assist|App Volumes|Workspace ONE|Intelligent Hub|VGAuth|vm3d|VMwareCAF'
$BrokerValueCandidates = @('Broker', 'BrokerList', 'Brokers', 'ConnectionServer')
$BrokerPorts = @(4001, 4002)
$BlastSessionCounterSets = @('VMware Blast Session Counters', 'Omnissa Blast Session Counters')
$BlastImagingCounterSets = @('VMware Blast Imaging Counters', 'Omnissa Blast Imaging Counters')
$BlastCounterNames = @{ Rtt = 'RTT'; Loss = 'Packet Loss (Uplink)'; Bandwidth = 'Estimated Bandwidth (Uplink)'; Fps = 'Frame Rate' }
$AgentFirewallRulePattern = '(?i)Horizon|Blast|PCoIP|VMware View|Omnissa'
$BlastConfigRoots = @('HKLM:\SOFTWARE\Omnissa\Horizon\Blast\Config', 'HKLM:\SOFTWARE\VMware, Inc.\VMware Blast\Config')
$BlastUdpValueName = 'UdpEnabled'
$AgentEventProviderPattern = '(?i)Horizon|VMware View|VMware Blast|Omnissa'
$AgentLogDirs = @("$env:ProgramData\Omnissa\logs", "$env:ProgramData\VMware\VDM\logs")
$ViewClientVarNames = @{ Machine = 'ViewClient_Machine_Name'; Ip = 'ViewClient_IP_Address'; Protocol = 'ViewClient_Protocol'; Broker = 'ViewClient_Broker_DNS_Name' }
$AgentUninstallPattern = '(?i)^(Omnissa|VMware) Horizon.*Agent'
$PcoipCounterSets = @('PCoIP Session Network Statistics')
$PcoipCounterNames = @{ Rtt = 'Round Trip Latency ms'; RxLoss = 'RX Packet Loss Percent'; TxLoss = 'TX Packet Loss Percent' }
$RelatedCaches = @{ AppVolumes = 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\AppVolumes'; FSLogix = 'HKLM:\Software\AirWatch\Extensions\VDI\Shared\FSLogix'
                    DEM = 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\DEM'; VPN = 'HKLM:\Software\AirWatch\Extensions\VPN' }

$ErrorActionPreference = 'SilentlyContinue'; $ProgressPreference = 'SilentlyContinue'
$UNKNOWN = -1; $NOTAPPL = -2; $TIMEDOUT = -4

$r = [ordered]@{
    SchemaVersion = 1; Component = 'HorizonAgent'; Platform = 'Horizon'; Role = 'SessionHost'
    Collected = (Get-Date -Format 's'); ElapsedMs = $UNKNOWN; TimedOut = $false
    Installed = $false; Version = ''; BrandRoot = ''; AgentServiceName = ''
    AgentServiceRunning = $false; BlastServicePresent = $false; BlastServiceRunning = $false; AgentServiceStartMode = ''
    FeatureServiceCount = $UNKNOWN; FirewallRuleCount = $UNKNOWN; FirewallRulesDisabled = $UNKNOWN; FeatureServicesStopped = @()
    UptimeMinutes = $UNKNOWN; CloneType = 'Unknown'; Persistence = 'Unknown'; BlastUdpEnabled = $UNKNOWN; SyncAgeHours = $UNKNOWN
    SessionCount = $UNKNOWN; DisconnectedSessionCount = $UNKNOWN; OldestDisconnectedMinutes = $UNKNOWN
    BlastSessionCount = $UNKNOWN; BlastRttMsMax = $UNKNOWN; BlastPacketLossPpmMax = $UNKNOWN; BlastBandwidthKbpsMin = $UNKNOWN; BlastFpsMin = $UNKNOWN
    BlastTcpFallbackSessions = $UNKNOWN; BlastCounterSet = ''
    PcoipSessionCount = $UNKNOWN; PcoipRttMsMax = $UNKNOWN; PcoipLossPpmMax = $UNKNOWN
    BrokerCount = $UNKNOWN; BrokerList = @(); BrokerSource = 'None'; BrokerResolvable = $false; BrokerReachable = $false; BrokerProbeResult = 'NotProbed'; BrokerProbeMs = $UNKNOWN
    AgentErrorCount24h = $UNKNOWN; Errors24h = @()
    Sessions = @(); Related = [ordered]@{}
    HealthScore = $UNKNOWN; HealthReason = 'Unknown'; Deductions = @(); NextStep = 'NONE'; NextStepDetail = ''
}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
function Test-Budget { if ($sw.Elapsed.TotalSeconds -lt $script:TimeoutSeconds) { return $true }; $r.TimedOut = $true; return $false }
function Write-Result {
    $sw.Stop(); $r.ElapsedMs = [int]$sw.Elapsed.TotalMilliseconds
    try { Write-Output (ConvertTo-Json -InputObject $r -Depth 5 -Compress) } catch { Write-Output '{"SchemaVersion":1,"Component":"HorizonAgent","HealthReason":"SerializationFailed"}' }
}
function Test-TcpPort {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try { $ar = $tcp.BeginConnect($TargetHost, $Port, $null, $null); if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $tcp.EndConnect($ar); return [bool]$tcp.Connected }; return $false }
    catch { return $false } finally { $tcp.Close() }
}
function Get-HostName { param([string]$Raw) if ($Raw -match '^(?:[a-z]+://)?([^/:\s]+)') { return $matches[1].ToLower() }; return '' }
function Read-SessionCounters {
    param([string[]]$Sets, [string[]]$Names)
    foreach ($set in $Sets) {
        try {
            $c = Get-Counter -Counter @($Names | ForEach-Object { "\$set(*)\$_" }) -MaxSamples 1 -ErrorAction Stop
            $rows = @{}
            foreach ($smp in @($c.CounterSamples)) { if ($smp.Path -notmatch '(?i)session id:\s*(\d+)') { continue }; $id = [int]$matches[1]; if (-not $rows.ContainsKey($id)) { $rows[$id] = @{} }; $rows[$id][$smp.Path.Split('\')[-1]] = [double]$smp.CookedValue }
            return @{ Set = $set; Rows = $rows }
        } catch { }
    }
    return $null
}
function Set-NextStep {
    param([string]$Reason)
    $map = @{
        AgentServiceStopped = @('AUTO', 'Invoke-AutoRemediateHorizonAgent.ps1 step 1'); BlastServiceStopped = @('AUTO', 'Invoke-AutoRemediateHorizonAgent.ps1 step 2')
        FeatureServiceStopped = @('AUTO', 'Invoke-AutoRemediateHorizonAgent.ps1 step 3'); FirewallRulesDisabled = @('AUTO', 'Invoke-AutoRemediateHorizonAgent.ps1 step 4')
        BrokerUnresolvable = @('AUTO', 'Invoke-AutoRemediateHorizonAgent.ps1 step 5 (flush); ADMIN if it persists')
        BrokerUnreachable = @('ADMIN', 'Connection Server / UAG / firewall path; see Runbook-Horizon-Agent.md phase 2')
        NotPaired = @('ADMIN', 'Connection Server / UAG / firewall path; see Runbook-Horizon-Agent.md phase 2'); NoBrokerKnown = @('ADMIN', 'Connection Server / UAG / firewall path; see Runbook-Horizon-Agent.md phase 2')
        HighPacketLoss = @('ADMIN', 'network path; correlate with the endpoint via LastClientName'); HighRtt = @('ADMIN', 'network path; correlate with the endpoint via LastClientName'); BlastTcpFallback = @('ADMIN', 'network path; correlate with the endpoint via LastClientName')
        StaleDisconnectedSessions = @('AUTO', 'Invoke-AutoRemediateHorizonAgent.ps1 step 7 (opt-in)'); AgentErrorsElevated = @('ADMIN', 'Runbook-Horizon-Agent.md phase 6')
        TimeSyncStale = @('AUTO', 'GenericTroubleshooting/TimeSyncHealth')
    }
    if ($map.ContainsKey($Reason)) { $r.NextStep = $map[$Reason][0]; $r.NextStepDetail = $map[$Reason][1] } else { $r.NextStep = 'NONE'; $r.NextStepDetail = '' }
}

try {
    # -- Phase 1: registry, services, config --------------------------------------------------------
    $agentRoot = ''
    foreach ($p in $AgentRegistryRoots) { if (Test-Path -LiteralPath $p) { $agentRoot = $p; break } }
    $uninst = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' | Where-Object { $_.DisplayName -match $AgentUninstallPattern })
    $allSvc = @(Get-Service); $agentSvc = $null; $blastSvc = $null
    foreach ($s in $allSvc) { if ($AgentServiceNames -contains $s.Name) { $agentSvc = $s; break } }
    if (-not $agentSvc) { foreach ($s in $allSvc) { if ($s.DisplayName -match $AgentServiceDisplayPattern -and $s.DisplayName -notmatch $BlastServiceDisplayPattern) { $agentSvc = $s; break } } }
    foreach ($s in $allSvc) { if ($BlastServiceNames -contains $s.Name) { $blastSvc = $s; break } }
    if (-not $blastSvc) { foreach ($s in $allSvc) { if ($s.DisplayName -match $BlastServiceDisplayPattern -and $s.DisplayName -match '(?i)Horizon|VMware|Omnissa') { $blastSvc = $s; break } } }
    $r.Installed = [bool]($agentRoot -or $agentSvc -or $uninst.Count -gt 0)
    if ($uninst.Count -gt 0) { $r.Version = [string]$uninst[0].DisplayVersion }
    $r.BrandRoot = if ($agentRoot -match '(?i)Omnissa' -or ($uninst.Count -gt 0 -and $uninst[0].DisplayName -match '(?i)Omnissa')) { 'Omnissa' } elseif ($r.Installed) { 'VMware' } else { '' }

    if (-not $r.Installed) {
        $r.HealthScore = $UNKNOWN; $r.HealthReason = 'NotInstalled'
        foreach ($k in @('FeatureServiceCount','FirewallRuleCount','FirewallRulesDisabled','BlastUdpEnabled','SessionCount','DisconnectedSessionCount','OldestDisconnectedMinutes','BlastSessionCount','BlastRttMsMax','BlastPacketLossPpmMax','BlastBandwidthKbpsMin','BlastFpsMin','BlastTcpFallbackSessions','PcoipSessionCount','PcoipRttMsMax','PcoipLossPpmMax','BrokerCount','BrokerProbeMs','AgentErrorCount24h')) { $r[$k] = $NOTAPPL }
        $r.BrokerProbeResult = 'NotApplicable'
        Write-Result; return
    }

    if ($agentSvc) {
        $r.AgentServiceName = $agentSvc.Name; $r.AgentServiceRunning = ($agentSvc.Status -eq 'Running')
        $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($agentSvc.Name)'"; $r.AgentServiceStartMode = if ($cim) { [string]$cim.StartMode } else { [string]$agentSvc.StartType }
    }
    if ($blastSvc) { $r.BlastServicePresent = $true; $r.BlastServiceRunning = ($blastSvc.Status -eq 'Running') }
    $feat = @($allSvc | Where-Object { $_.DisplayName -match $FeatureServiceInclude -and $_.DisplayName -notmatch $FeatureServiceExclude -and (-not $agentSvc -or $_.Name -ne $agentSvc.Name) -and (-not $blastSvc -or $_.Name -ne $blastSvc.Name) -and [string]$_.StartType -eq 'Automatic' })
    $r.FeatureServiceCount = $feat.Count; $r.FeatureServicesStopped = @($feat | Where-Object { $_.Status -ne 'Running' } | ForEach-Object { $_.Name })
    $rules = @(Get-NetFirewallRule | Where-Object { $_.DisplayName -match $AgentFirewallRulePattern -or $_.DisplayGroup -match $AgentFirewallRulePattern })
    $r.FirewallRuleCount = $rules.Count; $r.FirewallRulesDisabled = @($rules | Where-Object { [string]$_.Enabled -ne 'True' }).Count
    foreach ($p in $BlastConfigRoots) { if (Test-Path -LiteralPath $p) { $v = (Get-ItemProperty -Path $p -Name $BlastUdpValueName).$BlastUdpValueName; if ($null -ne $v) { $r.BlastUdpEnabled = [int]([int]$v -ne 0) }; break } }
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    if ($os -and $os.LastBootUpTime) { $r.UptimeMinutes = [int]((Get-Date) - [datetime]$os.LastBootUpTime).TotalMinutes }
    foreach ($d in $AgentLogDirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $hit = @(Get-ChildItem -Path $d -Filter '*cloneprep*' -File)
        if ($hit.Count -eq 0) { $hit = @(Get-ChildItem -Path $d -Directory | ForEach-Object { Get-ChildItem -Path $_.FullName -Filter '*cloneprep*' -File }) }
        if ($hit.Count -gt 0) { $r.CloneType = 'InstantClone'; break }
    }
    $r.Persistence = if ($r.CloneType -eq 'InstantClone') { 'NonPersistent' } elseif ($r.CloneType -in @('FullClone', 'Physical')) { 'Persistent' } else { 'Unknown' }
    $lkg = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config' -Name 'LastKnownGoodTime').LastKnownGoodTime
    if ($lkg) { try { $r.SyncAgeHours = [int][math]::Round(((Get-Date) - [datetime]::FromFileTime([int64]$lkg)).TotalHours) } catch { } }

    # -- Phase 2: sessions -------------------------------------------------------------------------------
    $sessions = @{}; $brokersSeen = New-Object System.Collections.Generic.List[string]
    if (Test-Budget) {
        try {
            $ev = @(Get-DexEvent -LogName 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational' -Id 21, 23, 24, 25 -StartTime (Get-Date).AddHours(-$script:SessionLookbackHours) -MaxEvents $script:MaxEventsScanned -ErrorStop)
            $decided = @{}
            foreach ($e in $ev) {
                $u = ([xml]$e.ToXml()).Event.UserData.EventXML; $sid = [int]$u.SessionID; if ($sid -le 0) { continue }
                $user = [string]$u.User; if ($user -match '(^|\\)(DWM-|UMFD-)') { continue }
                if (-not $decided.ContainsKey($sid)) {
                    $decided[$sid] = $true; if ($e.Id -eq 23) { continue }
                    $sessions[$sid] = [ordered]@{ Id = $sid; User = $user; ClientName = ''; ClientIp = [string]$u.Address; Protocol = ''; Broker = ''; State = $(if ($e.Id -eq 24) { 'Disconnected' } else { 'Active' })
                                                 RttMs = $UNKNOWN; LossPpm = $UNKNOWN; DurationMin = [int]((Get-Date) - $e.TimeCreated).TotalMinutes; DisconnectedMin = $(if ($e.Id -eq 24) { [int]((Get-Date) - $e.TimeCreated).TotalMinutes } else { $UNKNOWN }) }
                }
                elseif ($sessions.ContainsKey($sid) -and $e.Id -eq 21) { $sessions[$sid].DurationMin = [int]((Get-Date) - $e.TimeCreated).TotalMinutes }
            }
            foreach ($sid in @($sessions.Keys)) {
                $s = $sessions[$sid]; $usid = ''
                try { $usid = ([Security.Principal.NTAccount]$s.User).Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
                if (-not $usid) { continue }
                foreach ($k in @("Registry::HKEY_USERS\$usid\Volatile Environment\$sid", "Registry::HKEY_USERS\$usid\Volatile Environment")) {
                    $ve = Get-ItemProperty -Path $k
                    if ($ve -and $ve.PSObject.Properties[$ViewClientVarNames.Machine]) {
                        $s.ClientName = [string]$ve.($ViewClientVarNames.Machine); if ($ve.($ViewClientVarNames.Ip)) { $s.ClientIp = [string]$ve.($ViewClientVarNames.Ip) }
                        $proto = [string]$ve.($ViewClientVarNames.Protocol); $s.Protocol = switch -Regex ($proto) { '(?i)blast' { 'Blast' } '(?i)pcoip' { 'PCoIP' } '(?i)rdp' { 'RDP' } default { $proto } }
                        $s.Broker = Get-HostName ([string]$ve.($ViewClientVarNames.Broker)); if ($s.Broker -and -not $brokersSeen.Contains($s.Broker)) { $brokersSeen.Add($s.Broker) }
                        break
                    }
                }
            }
            $r.SessionCount = @($sessions.Values | Where-Object { $_.State -eq 'Active' }).Count
            $r.DisconnectedSessionCount = @($sessions.Values | Where-Object { $_.State -eq 'Disconnected' }).Count
            $disc = @($sessions.Values | Where-Object { $_.State -eq 'Disconnected' } | Sort-Object { [int]$_.DisconnectedMin } -Descending)
            if ($disc.Count -gt 0) { $r.OldestDisconnectedMinutes = [int]$disc[0].DisconnectedMin }
        }
        catch { if ($_.Exception.Message -match 'No events were found') { $r.SessionCount = 0; $r.DisconnectedSessionCount = 0 } }
    } else { $r.SessionCount = $TIMEDOUT; $r.DisconnectedSessionCount = $TIMEDOUT }

    # -- Phase 3: counters ---------------------------------------------------------------------------------
    if (Test-Budget) {
        $bl = Read-SessionCounters -Sets $BlastSessionCounterSets -Names @($BlastCounterNames.Rtt, $BlastCounterNames.Loss, $BlastCounterNames.Bandwidth)
        if ($bl) {
            $r.BlastCounterSet = $bl.Set; $r.BlastSessionCount = $bl.Rows.Count
            $im = Read-SessionCounters -Sets $BlastImagingCounterSets -Names @($BlastCounterNames.Fps)
            foreach ($id in $bl.Rows.Keys) {
                $row = $bl.Rows[$id]
                $rtt = if ($row.ContainsKey($BlastCounterNames.Rtt)) { [int]$row[$BlastCounterNames.Rtt] } else { $UNKNOWN }
                $loss = if ($row.ContainsKey($BlastCounterNames.Loss)) { [int]($row[$BlastCounterNames.Loss] * 10000) } else { $UNKNOWN }
                $bw = if ($row.ContainsKey($BlastCounterNames.Bandwidth)) { [int]$row[$BlastCounterNames.Bandwidth] } else { $UNKNOWN }
                $fps = $UNKNOWN; if ($im -and $im.Rows.ContainsKey($id) -and $im.Rows[$id].ContainsKey($BlastCounterNames.Fps)) { $fps = [int]$im.Rows[$id][$BlastCounterNames.Fps] }
                if ($rtt -gt $r.BlastRttMsMax) { $r.BlastRttMsMax = $rtt }; if ($loss -gt $r.BlastPacketLossPpmMax) { $r.BlastPacketLossPpmMax = $loss }
                if ($bw -ge 0 -and ($r.BlastBandwidthKbpsMin -lt 0 -or $bw -lt $r.BlastBandwidthKbpsMin)) { $r.BlastBandwidthKbpsMin = $bw }
                if ($fps -ge 0 -and ($r.BlastFpsMin -lt 0 -or $fps -lt $r.BlastFpsMin)) { $r.BlastFpsMin = $fps }
                if ($sessions.ContainsKey($id)) { $sessions[$id].RttMs = $rtt; $sessions[$id].LossPpm = $loss; if (-not $sessions[$id].Protocol) { $sessions[$id].Protocol = 'Blast' } }
            }
        } else { $r.BlastSessionCount = 0 }
        $pc = Read-SessionCounters -Sets $PcoipCounterSets -Names @($PcoipCounterNames.Rtt, $PcoipCounterNames.RxLoss, $PcoipCounterNames.TxLoss)
        if ($pc) {
            $r.PcoipSessionCount = $pc.Rows.Count
            foreach ($id in $pc.Rows.Keys) {
                $row = $pc.Rows[$id]; $rtt = if ($row.ContainsKey($PcoipCounterNames.Rtt)) { [int]$row[$PcoipCounterNames.Rtt] } else { $UNKNOWN }
                $lp = 0.0; foreach ($n in @($PcoipCounterNames.RxLoss, $PcoipCounterNames.TxLoss)) { if ($row.ContainsKey($n) -and $row[$n] -gt $lp) { $lp = $row[$n] } }
                $loss = [int]($lp * 10000); if ($rtt -gt $r.PcoipRttMsMax) { $r.PcoipRttMsMax = $rtt }; if ($loss -gt $r.PcoipLossPpmMax) { $r.PcoipLossPpmMax = $loss }
                if ($sessions.ContainsKey($id)) { $sessions[$id].RttMs = $rtt; $sessions[$id].LossPpm = $loss; if (-not $sessions[$id].Protocol) { $sessions[$id].Protocol = 'PCoIP' } }
            }
        } else { $r.PcoipSessionCount = 0 }
    } else { foreach ($k in @('BlastSessionCount','BlastRttMsMax','BlastPacketLossPpmMax','BlastBandwidthKbpsMin','BlastFpsMin','PcoipSessionCount','PcoipRttMsMax','PcoipLossPpmMax')) { $r[$k] = $TIMEDOUT } }
    $r.Sessions = @($sessions.Values | Sort-Object { [int]$_.RttMs } -Descending | Select-Object -First $script:MaxSessionRows)

    # -- Phase 4: broker ------------------------------------------------------------------------------------
    $brokers = New-Object System.Collections.Generic.List[string]; $fromReg = $false
    if ($agentRoot) {
        foreach ($k in @($agentRoot, (Join-Path $agentRoot 'Configuration'), (Join-Path (Split-Path $agentRoot -Parent) 'Node Manager'))) {
            if (-not (Test-Path -LiteralPath $k)) { continue }; $p = Get-ItemProperty -Path $k
            foreach ($vn in $BrokerValueCandidates) { if ($null -eq $p.$vn) { continue }; foreach ($piece in ((([string[]]$p.$vn) -join ' ') -split '[;,\s]+')) { $h = Get-HostName $piece; if ($h -and -not $brokers.Contains($h)) { $brokers.Add($h); $fromReg = $true } } }
        }
    }
    $fromSess = $false; foreach ($b in $brokersSeen) { if (-not $brokers.Contains($b)) { $brokers.Add($b) }; $fromSess = $true }
    $r.BrokerCount = $brokers.Count; $r.BrokerList = @($brokers)
    $r.BrokerSource = if ($fromReg -and $fromSess) { 'Both' } elseif ($fromReg) { 'Registry' } elseif ($fromSess) { 'Session' } else { 'None' }
    if ($brokers.Count -eq 0) { $r.BrokerProbeResult = 'NoBroker'; $r.BrokerProbeMs = $NOTAPPL }
    elseif (-not (Test-Budget)) { $r.BrokerProbeResult = 'TimedOut'; $r.BrokerProbeMs = $TIMEDOUT }
    else {
        $psw = [System.Diagnostics.Stopwatch]::StartNew(); $anyResolved = $false; $reach = $false
        foreach ($b in ($brokers | Select-Object -First $script:MaxProbeHosts)) {
            if (-not (Test-Budget)) { break }
            $ok = $false; try { $ok = [bool](Resolve-DnsName -Name $b -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' }) } catch { }
            if (-not $ok) { continue }; $anyResolved = $true
            foreach ($port in $BrokerPorts) { if (Test-TcpPort -TargetHost $b -Port $port -TimeoutMs $script:NetTimeoutMs) { $reach = $true; break } }
            if ($reach) { break }
        }
        $psw.Stop(); $r.BrokerProbeMs = [int]$psw.Elapsed.TotalMilliseconds; $r.BrokerResolvable = $anyResolved; $r.BrokerReachable = $reach
        $r.BrokerProbeResult = if ($r.TimedOut) { 'TimedOut' } elseif (-not $anyResolved) { 'Unresolvable' } elseif ($reach) { 'Reachable' } else { 'Unreachable' }
    }

    # -- Phase 5: errors --------------------------------------------------------------------------------------
    if (Test-Budget) {
        try {
            $errs = @(Get-DexEvent -LogName 'Application' -Level 1, 2 -StartTime (Get-Date).AddHours(-$script:EventLookbackHours) -MaxEvents $script:MaxEventsScanned -ErrorStop | Where-Object { $_.ProviderName -match $AgentEventProviderPattern })
            $r.AgentErrorCount24h = $errs.Count
            $r.Errors24h = @($errs | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { [ordered]@{ Id = [int]$_.Name; Count = [int]$_.Count } })
        }
        catch { if ($_.Exception.Message -match 'No events were found') { $r.AgentErrorCount24h = 0 } }
    } else { $r.AgentErrorCount24h = $TIMEDOUT }

    # -- Phase 6: related caches ------------------------------------------------------------------------------
    foreach ($name in @('AppVolumes', 'FSLogix', 'DEM', 'VPN')) {
        $c = Get-ItemProperty -Path $RelatedCaches[$name]; $sc = $UNKNOWN; $rs = ''; $age = $UNKNOWN
        if ($c) {
            $d = 0.0; if ($null -ne $c.HealthScore -and [double]::TryParse([string]$c.HealthScore, [ref]$d)) { $sc = [int]$d }
            if ($c.HealthReason) { $rs = [string]$c.HealthReason }
            $t = [datetime]::MinValue; if ($c.LastRun -and [datetime]::TryParse([string]$c.LastRun, [ref]$t)) { $age = [int]((Get-Date) - $t).TotalMinutes }
        }
        $r.Related[$name] = [ordered]@{ Score = $sc; Reason = $rs; CacheAgeMin = $age }
    }

    # -- Phase 7: score (mirrors the collector; -1/-2/-4 never deduct) ------------------------------------------
    $ded = New-Object System.Collections.Generic.List[object]
    function Ded { param([string]$R, [int]$P) $ded.Add([ordered]@{ Reason = $R; Points = $P }) }
    if (-not $r.AgentServiceRunning) { Ded 'AgentServiceStopped' 40 }
    if ($r.BrokerCount -gt 0 -and $r.BrokerProbeResult -eq 'Unresolvable') { Ded 'BrokerUnresolvable' 30 }
    if ($r.BrokerCount -gt 0 -and $r.BrokerProbeResult -eq 'Unreachable') { Ded 'BrokerUnreachable' 30 }
    if ($r.BlastServicePresent -and -not $r.BlastServiceRunning) { Ded 'BlastServiceStopped' 25 }
    if ($r.BlastPacketLossPpmMax -gt $script:BlastLossWarnPpm -or $r.PcoipLossPpmMax -gt $script:BlastLossWarnPpm) { Ded 'HighPacketLoss' 20 }
    if ($r.BlastRttMsMax -gt $script:BlastRttWarnMs -or $r.PcoipRttMsMax -gt $script:BlastRttWarnMs) { Ded 'HighRtt' 15 }
    if ($r.BlastTcpFallbackSessions -gt 0 -and $r.BlastUdpEnabled -eq 1) { Ded 'BlastTcpFallback' 15 }
    if ($r.FirewallRulesDisabled -gt 0) { Ded 'FirewallRulesDisabled' 15 }
    if ($r.BrokerCount -eq 0) { Ded 'NoBrokerKnown' 10 }
    if ($r.AgentErrorCount24h -ge $script:AgentErrorWarnCount) { Ded 'AgentErrorsElevated' 10 }
    if ($r.OldestDisconnectedMinutes -gt $script:DisconnectedStaleMinutes) { Ded 'StaleDisconnectedSessions' 10 }
    if (@($r.FeatureServicesStopped).Count -gt 0) { Ded 'FeatureServiceStopped' 5 }
    if ($r.SyncAgeHours -gt $script:SyncStaleHours) { Ded 'TimeSyncStale' 5 }
    $score = 100; foreach ($d in $ded) { $score -= $d.Points }; if ($score -lt 0) { $score = 0 }
    $r.HealthScore = $score
    $r.Deductions = @($ded | Sort-Object { $_.Points } -Descending)
    $r.HealthReason = if ($ded.Count -eq 0) { 'Healthy' } else { $r.Deductions[0].Reason }
    Set-NextStep $r.HealthReason
    Write-Result
    return
}
catch {
    $r.HealthReason = 'CollectionError'; $r.NextStepDetail = [string]$_.Exception.Message
    Write-Result
    return
}
