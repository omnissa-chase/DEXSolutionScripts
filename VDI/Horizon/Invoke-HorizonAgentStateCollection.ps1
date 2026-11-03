<#
.SYNOPSIS
    Horizon Agent state collection for Workspace ONE UEM sensors (session host side).

.DESCRIPTION
    Measures the Horizon Agent on a session host once, scores it, and caches every value
    to HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Agent (plus Sessions\<Id>) so the
    hzn_agent_* and hzn_blast_* sensors read in milliseconds. Phases, cheapest first:
    services and config; session inventory (LSM events + ViewClient_* volatile env);
    Blast/PCoIP counters; broker DNS/TCP probe; Application-log errors; clone type,
    time sync, boot; score and FaultPresentAtBoot (decided once per boot, SPEC 5.3).

    Contract (value table, deductions, sensors, KB resolution points): VDI/Horizon/SPEC.md
    rev 1. KB-HZN-nn variables below hold candidate lists the internal build replaces with
    the settled answer, keeping the fallback. Never rename them.

.NOTES
    Script Name  : Invoke-HorizonAgentStateCollection.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : 30 seconds budget (deploy with a 60 second UEM timeout)
    Schedule     : Every 15-30 minutes on session hosts
    Built from   : VDI/Horizon/SPEC.md rev 1

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Invoke-HorizonAgentStateCollection {
[CmdletBinding()]
param()

$SCRIPT_VERSION = '1.0.0'
$SCRIPT_VARIANT = ''      # internal build: 'internal' (ScriptVersion is written as <version>+internal)
$RegPath = 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Agent'
$LogPath = "$env:SystemRoot\Temp\UEM_HorizonAgentStateCollection.log"

# -- Tunables (hard-coded on purpose: UEM variables are per script object, not per assignment) --
$BlastRttWarnMs           = 250
$BlastLossWarnPpm         = 20000     # 2 percent
$DisconnectedStaleMinutes = 480
$AgentErrorWarnCount      = 10
$SyncStaleHours           = 48
$TimeSkewWarnSeconds      = 120
$NetTimeoutMs             = 2000
$MaxProbeHosts            = 3
$EventLookbackHours       = 24
$SessionLookbackHours     = 72
$MaxEventsScanned         = 2000
$MaxSessionsCached        = 50

# -- KB resolution points (VDI/Horizon/SPEC.md section 3). Candidate order matters. --
$AgentRegistryRoots = @('HKLM:\SOFTWARE\Omnissa\Horizon\Agent', 'HKLM:\SOFTWARE\VMware, Inc.\VMware VDM\Agent')  # KB-HZN-01
$AgentServiceNames = @('wsnm'); $BlastServiceNames = @('VMBlast')                                                # KB-HZN-02
$AgentServiceDisplayPattern = '(?i)Horizon.*Agent|VMware View Agent'; $BlastServiceDisplayPattern = '(?i)Blast'
$FeatureServiceInclude = '(?i)Horizon|Blast|ThinPrint|TP AutoConnect|USB Arbitration|View Agent|Omnissa'        # KB-HZN-03
$FeatureServiceExclude = '(?i)VMware Tools|Assist|App Volumes|Workspace ONE|Intelligent Hub|VGAuth|vm3d|VMwareCAF'
$BrokerValueCandidates = @('Broker', 'BrokerList', 'Brokers', 'ConnectionServer')                                # KB-HZN-04
$BrokerPorts = @(4001, 4002)                                                                                     # KB-HZN-05
$BlastSessionCounterSets = @('VMware Blast Session Counters', 'Omnissa Blast Session Counters')                  # KB-HZN-06
$BlastImagingCounterSets = @('VMware Blast Imaging Counters', 'Omnissa Blast Imaging Counters')
$BlastCounterNames = @{ Rtt = 'RTT'; Loss = 'Packet Loss (Uplink)'; Bandwidth = 'Estimated Bandwidth (Uplink)'; Fps = 'Frame Rate' }
$AgentFirewallRulePattern = '(?i)Horizon|Blast|PCoIP|VMware View|Omnissa'                                        # KB-HZN-07
$BlastConfigRoots = @('HKLM:\SOFTWARE\Omnissa\Horizon\Blast\Config', 'HKLM:\SOFTWARE\VMware, Inc.\VMware Blast\Config')  # KB-HZN-08
$BlastUdpValueName = 'UdpEnabled'
$BlastTransportSource = 'None'                                                                                   # KB-HZN-09: not measured in this build
$CloneTypeDetection = 'Heuristic'                                                                                # KB-HZN-10
$AgentEventProviderPattern = '(?i)Horizon|VMware View|VMware Blast|Omnissa'                                      # KB-HZN-11
$AgentLogDirs = @("$env:ProgramData\Omnissa\logs", "$env:ProgramData\VMware\VDM\logs")                           # KB-HZN-12
$ViewClientVarNames = @{ Machine = 'ViewClient_Machine_Name'; Ip = 'ViewClient_IP_Address'; Protocol = 'ViewClient_Protocol'
                         Broker = 'ViewClient_Broker_DNS_Name'; User = 'ViewClient_LoggedOn_Username'; Type = 'ViewClient_Type' }  # KB-HZN-13
$AgentUninstallPattern = '(?i)^(Omnissa|VMware) Horizon.*Agent'                                                  # KB-HZN-14 (agent form)
$PcoipCounterSets = @('PCoIP Session Network Statistics')                                                        # KB-HZN-21
$PcoipCounterNames = @{ Rtt = 'Round Trip Latency ms'; RxLoss = 'RX Packet Loss Percent'; TxLoss = 'TX Packet Loss Percent' }

# -- Run header --
$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Output "[$RunEventId] Executing Invoke-HorizonAgentStateCollection, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'"
$HEAD = "`r`n[$RunEventId]"
$sw   = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Test-TcpPort {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $tcp.BeginConnect($TargetHost, $Port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $tcp.EndConnect($ar); return [bool]$tcp.Connected }
        return $false
    }
    catch { return $false }
    finally { $tcp.Close() }
}

function Get-HostName {
    # 'https://cs1.corp.local:443/x' or 'cs1.corp.local' -> 'cs1.corp.local'
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    if ($Raw -match '^(?:[a-z]+://)?([^/:\s]+)') { return $matches[1].ToLower() }
    return ''
}

# Pre-seeded to sentinels so an exception part-way still writes a coherent row.
$m = [ordered]@{
    Installed = 0; Version = ''; BrandRoot = ''; AgentRegistryRoot = ''
    AgentServiceName = ''; AgentServiceRunning = 0; AgentServiceStartMode = ''
    BlastServicePresent = 0; BlastServiceRunning = 0
    FeatureServiceCount = -1; FeatureServicesStopped = ''
    FirewallRuleCount = -1; FirewallRulesDisabled = -1
    BrokerCount = 0; BrokerList = ''; BrokerSource = 'None'; BrokerResolvable = 0; BrokerReachable = 0; BrokerProbeResult = 'NotProbed'; BrokerProbeMs = -1
    SessionCount = -1; DisconnectedSessionCount = -1; OldestDisconnectedMinutes = -1
    LastUser = ''; LastClientName = ''; LastClientIp = ''; LastProtocol = ''; LastSessionBroker = ''
    BlastSessionCount = -1; BlastCounterSet = ''; BlastRttMsMax = -1; BlastPacketLossPpmMax = -1; BlastBandwidthKbpsMin = -1; BlastFpsMin = -1
    BlastUdpEnabled = -1; BlastTcpFallbackSessions = -1
    PcoipSessionCount = -1; PcoipRttMsMax = -1; PcoipLossPpmMax = -1
    AgentEventProvider = ''; AgentErrorCount24h = -1; AgentTopErrorIds = ''
    CloneType = 'Unknown'; Persistence = 'Unknown'
    TimeSkewSeconds = -1; SyncAgeHours = -1
    BootTime = ''; UptimeMinutes = -1; FaultPresentAtBoot = 0
    HealthScore = -1; HealthReason = 'CollectionError'; Deductions = ''; Status = 'CollectionError'
}
$sessions = @{}   # SessionId -> hashtable

function Write-Cache {
    param([bool]$Commit)
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null }
    $ver = if ($SCRIPT_VARIANT) { "$SCRIPT_VERSION+$SCRIPT_VARIANT" } else { $SCRIPT_VERSION }
    Set-ItemProperty -Path $RegPath -Name 'ScriptVersion' -Value $ver -Type String -ErrorAction Stop
    $dwords = @('Installed', 'AgentServiceRunning', 'BlastServicePresent', 'BlastServiceRunning', 'BrokerResolvable', 'BrokerReachable', 'FaultPresentAtBoot')
    foreach ($k in $m.Keys) {
        if ($dwords -contains $k) { Set-ItemProperty -Path $RegPath -Name $k -Value ([int]$m[$k]) -Type DWord -ErrorAction Stop }
        else                      { Set-ItemProperty -Path $RegPath -Name $k -Value ([string]$m[$k]) -Type String -ErrorAction Stop }
    }
    Set-ItemProperty -Path $RegPath -Name 'CollectionDurationMs' -Value ([string][int]$sw.Elapsed.TotalMilliseconds) -Type String -ErrorAction Stop
    if ($Commit) {
        $sPath = Join-Path $RegPath 'Sessions'
        if (Test-Path $sPath) { Remove-Item -Path $sPath -Recurse -Force -ErrorAction SilentlyContinue }
        $n = 0
        foreach ($id in ($sessions.Keys | Sort-Object { [int]$_ })) {
            if ($n -ge $MaxSessionsCached) { break }
            $k = Join-Path $sPath ([string]$id)
            New-Item -Path $k -Force -ErrorAction Stop | Out-Null
            foreach ($f in $sessions[$id].Keys) { Set-ItemProperty -Path $k -Name $f -Value ([string]$sessions[$id][$f]) -Type String -ErrorAction Stop }
            $n++
        }
        Set-ItemProperty -Path $RegPath -Name 'LastRun' -Value (Get-Date -Format 'o') -Type String -ErrorAction Stop
    }
}

try {
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null }
    $prior = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $RegPath -Name 'LastAttempt' -Value (Get-Date -Format 'o') -Type String -ErrorAction Stop

    # ---- Phase 1: install, services, firewall, Blast config -------------------------------------
    foreach ($r in $AgentRegistryRoots) { if (Test-Path -LiteralPath $r) { $m.AgentRegistryRoot = $r; break } }
    if ($m.AgentRegistryRoot) { $m.BrandRoot = if ($m.AgentRegistryRoot -match '(?i)Omnissa') { 'Omnissa' } else { 'VMware' } }

    $uninst = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match $AgentUninstallPattern })
    if ($uninst.Count -gt 0) {
        $m.Version = [string]$uninst[0].DisplayVersion
        if (-not $m.BrandRoot) { $m.BrandRoot = if ($uninst[0].DisplayName -match '(?i)Omnissa') { 'Omnissa' } else { 'VMware' } }
    }

    $allSvc   = @(Get-Service -ErrorAction SilentlyContinue)
    $agentSvc = $null; $blastSvc = $null
    foreach ($s in $allSvc) { if ($AgentServiceNames -contains $s.Name) { $agentSvc = $s; break } }
    if (-not $agentSvc) { foreach ($s in $allSvc) { if ($s.DisplayName -match $AgentServiceDisplayPattern -and $s.DisplayName -notmatch $BlastServiceDisplayPattern) { $agentSvc = $s; break } } }
    foreach ($s in $allSvc) { if ($BlastServiceNames -contains $s.Name) { $blastSvc = $s; break } }
    if (-not $blastSvc) { foreach ($s in $allSvc) { if ($s.DisplayName -match $BlastServiceDisplayPattern -and $s.DisplayName -match '(?i)Horizon|VMware|Omnissa') { $blastSvc = $s; break } } }

    $m.Installed = [int]([bool]$m.AgentRegistryRoot -or [bool]$agentSvc -or $uninst.Count -gt 0)

    if ($m.Installed -eq 0) {
        $m.HealthScore = -1; $m.HealthReason = 'NotInstalled'; $m.Status = 'NotApplicable'; $m.Deductions = ''
        $m.CloneType = 'Unknown'; $m.Persistence = 'Unknown'
        Write-Cache -Commit $true
        Write-Output "$HEAD No Horizon Agent detected on this device. Cached NotInstalled to $RegPath"
        Write-Log 'No Horizon Agent detected. Exiting.'
        exit 0
    }

    if ($agentSvc) {
        $m.AgentServiceName = $agentSvc.Name
        $m.AgentServiceRunning = [int]($agentSvc.Status -eq 'Running')
        $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($agentSvc.Name)'" -ErrorAction SilentlyContinue
        $m.AgentServiceStartMode = if ($cim) { [string]$cim.StartMode } else { [string]$agentSvc.StartType }
    }
    if ($blastSvc) { $m.BlastServicePresent = 1; $m.BlastServiceRunning = [int]($blastSvc.Status -eq 'Running') }

    $feat = @($allSvc | Where-Object { $_.DisplayName -match $FeatureServiceInclude -and $_.DisplayName -notmatch $FeatureServiceExclude -and
                                       $_.Name -ne $m.AgentServiceName -and (-not $blastSvc -or $_.Name -ne $blastSvc.Name) -and
                                       [string]$_.StartType -eq 'Automatic' })
    $m.FeatureServiceCount = $feat.Count
    $m.FeatureServicesStopped = (@($feat | Where-Object { $_.Status -ne 'Running' } | ForEach-Object { $_.Name }) -join ';')

    try {
        $rules = @(Get-NetFirewallRule -ErrorAction Stop | Where-Object { $_.DisplayName -match $AgentFirewallRulePattern -or $_.DisplayGroup -match $AgentFirewallRulePattern })
        $m.FirewallRuleCount = $rules.Count
        $m.FirewallRulesDisabled = @($rules | Where-Object { [string]$_.Enabled -ne 'True' }).Count
    }
    catch { Write-Log "Firewall rule read failed: $($_.Exception.Message)" -Level 'WARN' }

    foreach ($r in $BlastConfigRoots) {
        if (Test-Path -LiteralPath $r) {
            $v = (Get-ItemProperty -Path $r -Name $BlastUdpValueName -ErrorAction SilentlyContinue).$BlastUdpValueName
            if ($null -ne $v) { $m.BlastUdpEnabled = [int]([int]$v -ne 0) }
            break
        }
    }

    # ---- Phase 2: session inventory --------------------------------------------------------------
    $brokersSeen = New-Object System.Collections.Generic.List[string]
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Id = 21, 23, 24, 25
                                                 StartTime = (Get-Date).AddHours(-$SessionLookbackHours) } -MaxEvents $MaxEventsScanned -ErrorAction Stop)
        $decided = @{}
        foreach ($e in $ev) {   # newest first: the first event per session decides its state
            $x = [xml]$e.ToXml(); $u = $x.Event.UserData.EventXML
            $sid = [int]$u.SessionID; if ($sid -le 0) { continue }
            $user = [string]$u.User; if ($user -match '^(DWM-|UMFD-)' -or $user -match '\\(DWM-|UMFD-)') { continue }
            if (-not $decided.ContainsKey($sid)) {
                $decided[$sid] = $true
                if ($e.Id -eq 23) { continue }
                $sessions[$sid] = @{ User = $user; Sid = ''; State = $(if ($e.Id -eq 24) { 'Disconnected' } else { 'Active' })
                                     ClientName = ''; ClientIp = [string]$u.Address; Protocol = ''; Broker = ''
                                     LogonTime = $e.TimeCreated.ToString('s'); DisconnectTime = $(if ($e.Id -eq 24) { $e.TimeCreated.ToString('s') } else { '' })
                                     DurationMin = -1; DisconnectedMin = -1; RttMs = -1; LossPpm = -1; BandwidthKbps = -1; Fps = -1 }
            }
            elseif ($sessions.ContainsKey($sid) -and $e.Id -eq 21) { $sessions[$sid].LogonTime = $e.TimeCreated.ToString('s') }  # older logon wins
        }
        foreach ($sid in @($sessions.Keys)) {
            $s = $sessions[$sid]
            $s.DurationMin = [int]((Get-Date) - [datetime]$s.LogonTime).TotalMinutes
            if ($s.State -eq 'Disconnected') { $s.DisconnectedMin = [int]((Get-Date) - [datetime]$s.DisconnectTime).TotalMinutes }
            try { $s.Sid = ([Security.Principal.NTAccount]$s.User).Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
            if (-not $s.Sid) {
                $short = $s.User.Split('\')[-1]
                $p = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue |
                     Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath -match "\\$([regex]::Escape($short))$" } | Select-Object -First 1
                if ($p) { $s.Sid = $p.PSChildName }
            }
            if ($s.Sid) {
                $ve = $null
                foreach ($k in @("Registry::HKEY_USERS\$($s.Sid)\Volatile Environment\$sid", "Registry::HKEY_USERS\$($s.Sid)\Volatile Environment")) {
                    $cand = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
                    if ($cand -and $cand.PSObject.Properties[$ViewClientVarNames.Machine]) { $ve = $cand; break }
                }
                if ($ve) {
                    $s.ClientName = [string]$ve.($ViewClientVarNames.Machine)
                    if ($ve.($ViewClientVarNames.Ip)) { $s.ClientIp = [string]$ve.($ViewClientVarNames.Ip) }
                    $proto = [string]$ve.($ViewClientVarNames.Protocol)
                    $s.Protocol = switch -Regex ($proto) { '(?i)blast' { 'Blast' } '(?i)pcoip' { 'PCoIP' } '(?i)rdp' { 'RDP' } default { $proto } }
                    $s.Broker = Get-HostName ([string]$ve.($ViewClientVarNames.Broker))
                    if ($s.Broker -and -not $brokersSeen.Contains($s.Broker)) { $brokersSeen.Add($s.Broker) }
                }
            }
        }
        $m.SessionCount = @($sessions.Values | Where-Object { $_.State -eq 'Active' }).Count
        $m.DisconnectedSessionCount = @($sessions.Values | Where-Object { $_.State -eq 'Disconnected' }).Count
        $disc = @($sessions.Values | Where-Object { $_.State -eq 'Disconnected' } | Sort-Object { [int]$_.DisconnectedMin } -Descending)
        if ($disc.Count -gt 0) { $m.OldestDisconnectedMinutes = [int]$disc[0].DisconnectedMin }
        $latest = @($sessions.Values | Sort-Object { [datetime]$_.LogonTime } -Descending | Select-Object -First 1)
        if ($latest.Count -gt 0) {
            $m.LastUser = $latest[0].User; $m.LastClientName = $latest[0].ClientName; $m.LastClientIp = $latest[0].ClientIp
            $m.LastProtocol = $latest[0].Protocol; $m.LastSessionBroker = $latest[0].Broker
        }
    }
    catch {
        if ($_.Exception.Message -match 'No events were found') { $m.SessionCount = 0; $m.DisconnectedSessionCount = 0 }
        else { Write-Log "Session inventory failed: $($_.Exception.Message)" -Level 'WARN' }
    }

    # ---- Phase 3: Blast / PCoIP counters ----------------------------------------------------------
    function Read-SessionCounters {
        param([string[]]$Sets, [string[]]$Names)
        foreach ($set in $Sets) {
            $paths = @($Names | ForEach-Object { "\$set(*)\$_" })
            try {
                $c = Get-Counter -Counter $paths -MaxSamples 1 -ErrorAction Stop
                $rows = @{}
                foreach ($smp in @($c.CounterSamples)) {
                    if ($smp.Path -notmatch '(?i)session id:\s*(\d+)') { continue }
                    $id = [int]$matches[1]; $cn = $smp.Path.Split('\')[-1]
                    if (-not $rows.ContainsKey($id)) { $rows[$id] = @{} }
                    $rows[$id][$cn] = [double]$smp.CookedValue
                }
                return @{ Set = $set; Rows = $rows }
            }
            catch { }
        }
        return $null
    }
    $bl = Read-SessionCounters -Sets $BlastSessionCounterSets -Names @($BlastCounterNames.Rtt, $BlastCounterNames.Loss, $BlastCounterNames.Bandwidth)
    if ($bl) {
        $m.BlastCounterSet = $bl.Set; $m.BlastSessionCount = $bl.Rows.Count
        $im = Read-SessionCounters -Sets $BlastImagingCounterSets -Names @($BlastCounterNames.Fps)
        foreach ($id in $bl.Rows.Keys) {
            $r = $bl.Rows[$id]
            $rtt = if ($r.ContainsKey($BlastCounterNames.Rtt)) { [int]$r[$BlastCounterNames.Rtt] } else { -1 }
            $loss = if ($r.ContainsKey($BlastCounterNames.Loss)) { [int]($r[$BlastCounterNames.Loss] * 10000) } else { -1 }
            $bw = if ($r.ContainsKey($BlastCounterNames.Bandwidth)) { [int]$r[$BlastCounterNames.Bandwidth] } else { -1 }
            $fps = -1
            if ($im -and $im.Rows.ContainsKey($id) -and $im.Rows[$id].ContainsKey($BlastCounterNames.Fps)) { $fps = [int]$im.Rows[$id][$BlastCounterNames.Fps] }
            if ($rtt -gt $m.BlastRttMsMax) { $m.BlastRttMsMax = $rtt }
            if ($loss -gt $m.BlastPacketLossPpmMax) { $m.BlastPacketLossPpmMax = $loss }
            if ($bw -ge 0 -and ($m.BlastBandwidthKbpsMin -lt 0 -or $bw -lt $m.BlastBandwidthKbpsMin)) { $m.BlastBandwidthKbpsMin = $bw }
            if ($fps -ge 0 -and ($m.BlastFpsMin -lt 0 -or $fps -lt $m.BlastFpsMin)) { $m.BlastFpsMin = $fps }
            if ($sessions.ContainsKey($id)) { $sessions[$id].RttMs = $rtt; $sessions[$id].LossPpm = $loss; $sessions[$id].BandwidthKbps = $bw; $sessions[$id].Fps = $fps; if (-not $sessions[$id].Protocol) { $sessions[$id].Protocol = 'Blast' } }
        }
    }
    else { $m.BlastSessionCount = 0 }
    # KB-HZN-09 hook: the internal build sets $BlastTransportSource and fills BlastTcpFallbackSessions here; this build leaves -1.
    if ($BlastTransportSource -ne 'None') { Write-Log "Blast transport source '$BlastTransportSource' is configured but not implemented in this build; BlastTcpFallbackSessions stays -1" -Level 'WARN' }
    $pc = Read-SessionCounters -Sets $PcoipCounterSets -Names @($PcoipCounterNames.Rtt, $PcoipCounterNames.RxLoss, $PcoipCounterNames.TxLoss)
    if ($pc) {
        $m.PcoipSessionCount = $pc.Rows.Count
        foreach ($id in $pc.Rows.Keys) {
            $r = $pc.Rows[$id]
            $rtt = if ($r.ContainsKey($PcoipCounterNames.Rtt)) { [int]$r[$PcoipCounterNames.Rtt] } else { -1 }
            $lossPct = 0.0
            foreach ($n in @($PcoipCounterNames.RxLoss, $PcoipCounterNames.TxLoss)) { if ($r.ContainsKey($n) -and $r[$n] -gt $lossPct) { $lossPct = $r[$n] } }
            $loss = [int]($lossPct * 10000)
            if ($rtt -gt $m.PcoipRttMsMax) { $m.PcoipRttMsMax = $rtt }
            if ($loss -gt $m.PcoipLossPpmMax) { $m.PcoipLossPpmMax = $loss }
            if ($sessions.ContainsKey($id)) { $sessions[$id].RttMs = $rtt; $sessions[$id].LossPpm = $loss; if (-not $sessions[$id].Protocol) { $sessions[$id].Protocol = 'PCoIP' } }
        }
    }
    else { $m.PcoipSessionCount = 0 }

    # ---- Phase 4: broker list and probe ------------------------------------------------------------
    $brokers = New-Object System.Collections.Generic.List[string]
    $fromReg = $false
    if ($m.AgentRegistryRoot) {
        $keys = @($m.AgentRegistryRoot, (Join-Path $m.AgentRegistryRoot 'Configuration'), (Join-Path (Split-Path $m.AgentRegistryRoot -Parent) 'Node Manager'))
        foreach ($k in $keys) {
            if (-not (Test-Path -LiteralPath $k)) { continue }
            $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
            foreach ($vn in $BrokerValueCandidates) {
                $raw = $p.$vn
                if ($null -eq $raw) { continue }
                foreach ($piece in (([string[]]$raw) -join ' ') -split '[;,\s]+') {
                    $h = Get-HostName $piece
                    if ($h -and -not $brokers.Contains($h)) { $brokers.Add($h); $fromReg = $true }
                }
            }
        }
    }
    $fromSess = $false
    foreach ($b in $brokersSeen) { if (-not $brokers.Contains($b)) { $brokers.Add($b) }; $fromSess = $true }
    $m.BrokerCount = $brokers.Count; $m.BrokerList = ($brokers -join ';')
    $m.BrokerSource = if ($fromReg -and $fromSess) { 'Both' } elseif ($fromReg) { 'Registry' } elseif ($fromSess) { 'Session' } else { 'None' }
    if ($brokers.Count -eq 0) { $m.BrokerProbeResult = 'NoBroker' }
    else {
        $psw = [System.Diagnostics.Stopwatch]::StartNew()
        $anyResolved = $false; $reach = $false
        foreach ($b in ($brokers | Select-Object -First $MaxProbeHosts)) {
            $ok = $false
            try { $ok = [bool](Resolve-DnsName -Name $b -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' }) } catch { }
            if (-not $ok) { continue }
            $anyResolved = $true
            foreach ($port in $BrokerPorts) { if (Test-TcpPort -TargetHost $b -Port $port -TimeoutMs $NetTimeoutMs) { $reach = $true; break } }
            if ($reach) { break }
        }
        $psw.Stop(); $m.BrokerProbeMs = [int]$psw.Elapsed.TotalMilliseconds
        $m.BrokerResolvable = [int]$anyResolved; $m.BrokerReachable = [int]$reach
        $m.BrokerProbeResult = if (-not $anyResolved) { 'Unresolvable' } elseif ($reach) { 'Reachable' } else { 'Unreachable' }
    }

    # ---- Phase 5: agent errors -----------------------------------------------------------------------
    try {
        $errs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2; StartTime = (Get-Date).AddHours(-$EventLookbackHours) } -MaxEvents $MaxEventsScanned -ErrorAction Stop |
                  Where-Object { $_.ProviderName -match $AgentEventProviderPattern })
        $m.AgentErrorCount24h = $errs.Count
        $m.AgentEventProvider = (@($errs | Select-Object -ExpandProperty ProviderName -Unique) -join ';')
        $m.AgentTopErrorIds = (@($errs | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Name):$($_.Count)" }) -join ';')
    }
    catch {
        if ($_.Exception.Message -match 'No events were found') { $m.AgentErrorCount24h = 0 }
        else { Write-Log "Application log read failed: $($_.Exception.Message)" -Level 'WARN' }
    }

    # ---- Phase 6: clone type, persistence, time sync, boot ------------------------------------------
    if ($CloneTypeDetection -eq 'Heuristic') {
        foreach ($d in $AgentLogDirs) {
            if (-not (Test-Path -LiteralPath $d)) { continue }
            $hit = @(Get-ChildItem -Path $d -Filter '*cloneprep*' -File -ErrorAction SilentlyContinue)
            if ($hit.Count -eq 0) { $hit = @(Get-ChildItem -Path $d -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -Path $_.FullName -Filter '*cloneprep*' -File -ErrorAction SilentlyContinue }) }
            if ($hit.Count -gt 0) { $m.CloneType = 'InstantClone'; break }
        }
    }
    $m.Persistence = if ($m.CloneType -eq 'InstantClone') { 'NonPersistent' } elseif ($m.CloneType -in @('FullClone', 'Physical')) { 'Persistent' } else { 'Unknown' }

    try {
        $t = (& w32tm.exe /query /status 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0 -and $t) {
            if ($t -match 'Phase Offset:\s*(-?[\d\.]+)s') { $m.TimeSkewSeconds = [math]::Round([math]::Abs([double]$matches[1]), 1) }
            if ($t -match 'Last Successful Sync Time:\s*(.+)') { $d = [datetime]::MinValue; if ([datetime]::TryParse($matches[1].Trim(), [ref]$d)) { $m.SyncAgeHours = [math]::Round(((Get-Date) - $d).TotalHours, 1) } }
        }
    }
    catch { }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os -and $os.LastBootUpTime) { $m.BootTime = ([datetime]$os.LastBootUpTime).ToString('s'); $m.UptimeMinutes = [int]((Get-Date) - [datetime]$os.LastBootUpTime).TotalMinutes }

    # ---- Phase 7: score ------------------------------------------------------------------------------
    # Deduction table: VDI/Horizon/SPEC.md 5.1. A -1 metric never deducts (every comparison is against a positive threshold).
    $ded = New-Object System.Collections.Generic.List[object]
    function Ded { param([string]$R, [int]$P) $ded.Add(@{ R = $R; P = $P }) }
    if ($m.AgentServiceRunning -eq 0) { Ded 'AgentServiceStopped' 40 }
    # 'NotPaired' (35) is KB-HZN-04 gated: the public build cannot prove unpaired, so it reports NoBrokerKnown instead.
    if ($m.BrokerCount -gt 0 -and $m.BrokerProbeResult -eq 'Unresolvable') { Ded 'BrokerUnresolvable' 30 }
    if ($m.BrokerCount -gt 0 -and $m.BrokerProbeResult -eq 'Unreachable') { Ded 'BrokerUnreachable' 30 }
    if ($m.BlastServicePresent -eq 1 -and $m.BlastServiceRunning -eq 0) { Ded 'BlastServiceStopped' 25 }
    if ($m.BlastPacketLossPpmMax -gt $BlastLossWarnPpm -or $m.PcoipLossPpmMax -gt $BlastLossWarnPpm) { Ded 'HighPacketLoss' 20 }
    if ($m.BlastRttMsMax -gt $BlastRttWarnMs -or $m.PcoipRttMsMax -gt $BlastRttWarnMs) { Ded 'HighRtt' 15 }
    if ($m.BlastTcpFallbackSessions -gt 0 -and $m.BlastUdpEnabled -eq 1) { Ded 'BlastTcpFallback' 15 }   # never true in the public build (KB-HZN-09)
    if ($m.FirewallRulesDisabled -gt 0) { Ded 'FirewallRulesDisabled' 15 }
    if ($m.BrokerCount -eq 0) { Ded 'NoBrokerKnown' 10 }
    if ($m.AgentErrorCount24h -ge $AgentErrorWarnCount) { Ded 'AgentErrorsElevated' 10 }
    if ($m.OldestDisconnectedMinutes -gt $DisconnectedStaleMinutes) { Ded 'StaleDisconnectedSessions' 10 }
    if ($m.FeatureServicesStopped) { Ded 'FeatureServiceStopped' 5 }
    if ($m.SyncAgeHours -gt $SyncStaleHours -or $m.TimeSkewSeconds -gt $TimeSkewWarnSeconds) { Ded 'TimeSyncStale' 5 }

    $score = 100; foreach ($d in $ded) { $score -= $d.P }; if ($score -lt 0) { $score = 0 }
    $m.HealthScore = $score
    $m.HealthReason = if ($ded.Count -eq 0) { 'Healthy' } else { ($ded | Sort-Object { $_.P } -Descending | Select-Object -First 1).R }
    $m.Deductions = (@($ded | Sort-Object { $_.P } -Descending | ForEach-Object { "$($_.R):$($_.P)" }) -join ';')
    $m.Status = if ($ded.Count -eq 0) { 'Healthy' } else { 'Degraded' }

    # FaultPresentAtBoot: decided once per boot, on the first run after it; carried unchanged afterwards (SPEC 5.3).
    $priorBoot = if ($prior) { [string]$prior.BootTime } else { '' }
    if ($m.BootTime -and $priorBoot -ne $m.BootTime) { $m.FaultPresentAtBoot = [int]($m.HealthReason -ne 'Healthy') }
    elseif ($prior -and $null -ne $prior.FaultPresentAtBoot) { $m.FaultPresentAtBoot = [int]$prior.FaultPresentAtBoot }

    Write-Cache -Commit $true

    $sum = "Horizon Agent $($m.Version) ($($m.BrandRoot)): score $($m.HealthScore) ($($m.HealthReason)); deductions [$($m.Deductions)]; sessions $($m.SessionCount)/$($m.DisconnectedSessionCount) disc; broker $($m.BrokerProbeResult) [$($m.BrokerList)]; Blast RTT $($m.BlastRttMsMax) ms loss $($m.BlastPacketLossPpmMax) ppm; clone $($m.CloneType); errors24h $($m.AgentErrorCount24h); boot fault $($m.FaultPresentAtBoot); $([int]$sw.Elapsed.TotalMilliseconds) ms"
    Write-Output "$HEAD $sum"; Write-Output "$HEAD Cached to $RegPath"; Write-Log $sum
    exit 0
}
catch {
    Write-Error "$HEAD ERROR: $($_.Exception.Message)"
    Write-Log "Collection failed: $($_.Exception.Message)" -Level 'ERROR'
    try { $m.HealthScore = -1; $m.HealthReason = 'CollectionError'; $m.Status = 'CollectionError'; Write-Cache -Commit $false } catch { }
    exit 1
}
}

# Entry point. The param block is inside the function because the Workspace ONE engine
# does not bind a script-scope param block.
Invoke-HorizonAgentStateCollection
