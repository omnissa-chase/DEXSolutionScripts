#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : hzn_client_health
    Data Type    : String (JSON)
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : One-time / run-once only. Self-enforced 25 s budget, 30 s UEM ceiling.
                   MUST NOT be scheduled as a recurring sensor.
    Built from   : VDI/Horizon/SPEC.md rev 1, section 7.2

    The complete Horizon Client picture on an endpoint in one on-demand pull: install,
    USB service, the console user's configured servers, the tail of that user's client
    log (failures, successes, last server), DNS, 443 and Blast-port probes, the VPN and
    network-stack caches on this endpoint (Related), score and next step. Reads no cache
    for its own component; writes nothing. Phases are budget-checked; a skipped phase
    reports -4 and TimedOut is true.

    Sentinels: -1 unknown, -2 not applicable, -4 timed out. No nulls. Keys are fixed.
    The deduction table duplicates Invoke-HorizonClientStateCollection.ps1 on purpose;
    change both in the same edit (Test-HorizonScoreParity.ps1 asserts they agree).

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

$script:TimeoutSeconds = 25
$script:NetTimeoutMs = 2000
$script:MaxProbeHosts = 3
$script:LogTailBytes = 524288
$script:LogLookbackHours = 24
$script:MaxServers = 10
$script:ConnectFailureWarnCount = 5
$script:ClientVersionFloor = ''      # KB-HZN-20

# KB resolution points, identical to the collector.
$ClientUninstallPattern = '(?i)^(Omnissa|VMware) Horizon Client'
$ClientRegistryRoots = @('SOFTWARE\Omnissa\Horizon\Client', 'SOFTWARE\VMware, Inc.\VMware VDM\Client')
$ClientPolicyRoots = @('HKLM:\SOFTWARE\Policies\Omnissa\Horizon\Client', 'HKLM:\SOFTWARE\Policies\VMware, Inc.\VMware VDM\Client')
$ClientServerValueCandidates = @('Server', 'ServerURL', 'DefaultServer', 'RecentServers')
$CertCheckValueName = 'CertCheckMode'
$ClientLogDirs = @('AppData\Local\Omnissa\Horizon\Logs', 'AppData\Local\VMware\VDM\Logs')
$ClientLogFilePatterns = @('*horizon*client*.txt', 'vmware-horizon-client-*.txt', 'vmware-horizon-client*.log')
$ClientLogSuccessRegex = '(?i)connected to|session.*established|login succeeded|authentication succeeded'
$ClientLogFailureRegex = '(?i)connect(ion)? (failed|error|refused)|unable to (connect|resolve)|certificate.*(invalid|rejected)|authentication failed|tunnel.*(failed|error)'
$ClientUsbServiceNames = @('vmware-usbarbitrator'); $ClientUsbDisplayPattern = '(?i)USB Arbitration'
$ClientBlastPorts = @(8443, 22443)
$RelatedCaches = @{ VPN = 'HKLM:\Software\AirWatch\Extensions\VPN'; NetworkStack = 'HKLM:\Software\AirWatch\Extensions\NetworkStack\Remediation' }

$ErrorActionPreference = 'SilentlyContinue'; $ProgressPreference = 'SilentlyContinue'
$UNKNOWN = -1; $NOTAPPL = -2; $TIMEDOUT = -4

$r = [ordered]@{
    SchemaVersion = 1; Component = 'HorizonClient'; Platform = 'Horizon'; Role = 'Client'
    Collected = (Get-Date -Format 's'); ElapsedMs = $UNKNOWN; TimedOut = $false
    Installed = $false; Version = ''; BrandRoot = ''; InstallLocation = ''; ClientUser = ''
    UsbServiceName = ''; UsbServiceRunning = $UNKNOWN
    ServerCount = $UNKNOWN; ServerList = @(); ServerSource = 'None'
    ServerResolvable = $false; Server443Reachable = $false; BlastPortReachable = $UNKNOWN; BlastPortProbed = ''; ProbeResult = 'NotProbed'; ProbeMs = $UNKNOWN
    CertCheckMode = ''; LogFileUsed = ''; LogParseResult = 'NoLog'
    ConnectFailureCount24h = $UNKNOWN; ConnectSuccessCount24h = $UNKNOWN; LastConnectTime = ''; LastServer = ''; LastProtocol = ''
    Related = [ordered]@{}
    HealthScore = $UNKNOWN; HealthReason = 'Unknown'; Deductions = @(); NextStep = 'NONE'; NextStepDetail = ''
}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
function Test-Budget { if ($sw.Elapsed.TotalSeconds -lt $script:TimeoutSeconds) { return $true }; $r.TimedOut = $true; return $false }
function Write-Result {
    $sw.Stop(); $r.ElapsedMs = [int]$sw.Elapsed.TotalMilliseconds
    try { Write-Output (ConvertTo-Json -InputObject $r -Depth 5 -Compress) } catch { Write-Output '{"SchemaVersion":1,"Component":"HorizonClient","HealthReason":"SerializationFailed"}' }
}
function Test-TcpPort {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try { $ar = $tcp.BeginConnect($TargetHost, $Port, $null, $null); if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $tcp.EndConnect($ar); return [bool]$tcp.Connected }; return $false }
    catch { return $false } finally { $tcp.Close() }
}
function Get-HostName { param([string]$Raw) if ($Raw -match '^(?:[a-z]+://)?([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9-]{2,})') { return $matches[1].ToLower() }; return '' }
$servers = New-Object System.Collections.Generic.List[string]
function Add-ServersFromKey {
    param([string]$Key)
    $added = $false
    if (-not (Test-Path -LiteralPath $Key)) { return $false }
    $p = Get-ItemProperty -Path $Key
    foreach ($vn in $ClientServerValueCandidates) { if ($null -eq $p.$vn) { continue }; foreach ($piece in ((([string[]]$p.$vn) -join ' ') -split '[;,\s]+')) { $h = Get-HostName $piece; if ($h -and -not $servers.Contains($h) -and $servers.Count -lt $script:MaxServers) { $servers.Add($h); $added = $true } } }
    foreach ($sub in @(Get-ChildItem -Path $Key | Where-Object { $_.PSChildName -match '(?i)server' })) {
        $h = Get-HostName $sub.PSChildName; if ($h -and -not $servers.Contains($h) -and $servers.Count -lt $script:MaxServers) { $servers.Add($h); $added = $true }
        $sp = Get-ItemProperty -Path $sub.PSPath
        foreach ($prop in @($sp.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and $_.Value -is [string] })) { $h = Get-HostName ([string]$prop.Value); if ($h -and -not $servers.Contains($h) -and $servers.Count -lt $script:MaxServers) { $servers.Add($h); $added = $true } }
        foreach ($leaf in @(Get-ChildItem -Path $sub.PSPath)) { $h = Get-HostName $leaf.PSChildName; if ($h -and -not $servers.Contains($h) -and $servers.Count -lt $script:MaxServers) { $servers.Add($h); $added = $true } }
    }
    return $added
}
function Set-NextStep {
    param([string]$Reason)
    $map = @{
        ServerUnresolvable = @('AUTO', 'Invoke-AutoRemediateHorizonClient.ps1 step 3')
        ServerUnreachable443 = @('ADMIN', 'network / UAG; WindowsAutoRemediation/Invoke-AutoRemediateNetworkStack.ps1 first'); BlastPortUnreachable = @('ADMIN', 'network / UAG; WindowsAutoRemediation/Invoke-AutoRemediateNetworkStack.ps1 first')
        RepeatedConnectFailures = @('USER', 'Runbook-Horizon-Client.md phase 3'); UsbServiceStopped = @('AUTO', 'Invoke-AutoRemediateHorizonClient.ps1 step 1')
        ClientOutdated = @('ADMIN', 'deploy current client via UEM apps'); CertCheckDisabled = @('ADMIN', 'client policy')
        VpnDegraded = @('AUTO', 'VPN/Invoke-AutoRemediateGenericVPN.ps1'); NoServerKnown = @('USER', 'open the client and add the server')
    }
    if ($map.ContainsKey($Reason)) { $r.NextStep = $map[$Reason][0]; $r.NextStepDetail = $map[$Reason][1] } else { $r.NextStep = 'NONE'; $r.NextStepDetail = '' }
}

try {
    # -- Phase 1: install, USB service, console user ------------------------------------------------
    $uninst = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' | Where-Object { $_.DisplayName -match $ClientUninstallPattern })
    if ($uninst.Count -gt 0) { $r.Installed = $true; $r.Version = [string]$uninst[0].DisplayVersion; $r.InstallLocation = [string]$uninst[0].InstallLocation; $r.BrandRoot = if ($uninst[0].DisplayName -match '(?i)Omnissa') { 'Omnissa' } else { 'VMware' } }
    if (-not $r.Installed) {
        $r.HealthScore = $UNKNOWN; $r.HealthReason = 'NotInstalled'
        foreach ($k in @('UsbServiceRunning','ServerCount','BlastPortReachable','ProbeMs','ConnectFailureCount24h','ConnectSuccessCount24h')) { $r[$k] = $NOTAPPL }
        $r.ProbeResult = 'NotApplicable'; $r.LogParseResult = 'NotApplicable'
        Write-Result; return
    }
    $usb = $null
    foreach ($s in @(Get-Service)) { if ($ClientUsbServiceNames -contains $s.Name -or $s.DisplayName -match $ClientUsbDisplayPattern) { $usb = $s; break } }
    if ($usb) { $r.UsbServiceName = $usb.Name; $r.UsbServiceRunning = [int]($usb.Status -eq 'Running') }
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem; $userSid = ''; $profilePath = ''
    if ($cs -and $cs.UserName) {
        $r.ClientUser = [string]$cs.UserName
        try { $userSid = ([Security.Principal.NTAccount]$r.ClientUser).Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
        if ($userSid) { $pl = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$userSid"; if ($pl -and $pl.ProfileImagePath) { $profilePath = [string]$pl.ProfileImagePath } }
    }
    $srcPolicy = $false; $srcUser = $false; $srcLog = $false
    foreach ($k in $ClientPolicyRoots) { if (Add-ServersFromKey -Key $k) { $srcPolicy = $true }; $cc = (Get-ItemProperty -Path $k -Name $CertCheckValueName).$CertCheckValueName; if ($null -ne $cc) { $r.CertCheckMode = [string]$cc } }
    if ($userSid) { foreach ($rel in $ClientRegistryRoots) { $k = "Registry::HKEY_USERS\$userSid\$rel"; if (Add-ServersFromKey -Key $k) { $srcUser = $true }; if (-not $r.CertCheckMode) { $cc = (Get-ItemProperty -Path $k -Name $CertCheckValueName).$CertCheckValueName; if ($null -ne $cc) { $r.CertCheckMode = [string]$cc } } } }

    # -- Phase 2: log tail ----------------------------------------------------------------------------
    if (-not $profilePath) { $r.LogParseResult = 'NoUser' }
    elseif (Test-Budget) {
        $logFile = $null
        foreach ($rel in $ClientLogDirs) {
            $dir = Join-Path $profilePath $rel; if (-not (Test-Path -LiteralPath $dir)) { continue }
            foreach ($pat in $ClientLogFilePatterns) { $f = Get-ChildItem -Path $dir -Filter $pat -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($f -and (-not $logFile -or $f.LastWriteTime -gt $logFile.LastWriteTime)) { $logFile = $f } }
        }
        if (-not $logFile) { $r.LogParseResult = 'NoLog' }
        else {
            $r.LogFileUsed = $logFile.FullName
            try {
                $fs = [System.IO.File]::Open($logFile.FullName, 'Open', 'Read', 'ReadWrite')
                try { $len = $fs.Length; $take = [math]::Min($len, $script:LogTailBytes); $fs.Seek($len - $take, 'Begin') | Out-Null; $buf = New-Object byte[] $take; $fs.Read($buf, 0, $take) | Out-Null } finally { $fs.Close() }
                $since = (Get-Date).AddHours(-$script:LogLookbackHours); $fail = 0; $succ = 0; $lastOk = [datetime]::MinValue
                foreach ($line in ([System.Text.Encoding]::UTF8.GetString($buf) -split "`r?`n")) {
                    if ($line -notmatch '^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})') { continue }
                    $ts = [datetime]::MinValue; if (-not [datetime]::TryParse($matches[1].Replace('T', ' '), [ref]$ts) -or $ts -lt $since) { continue }
                    if ($line -match $ClientLogFailureRegex) { $fail++ }
                    elseif ($line -match $ClientLogSuccessRegex) {
                        $succ++
                        if ($ts -gt $lastOk) { $lastOk = $ts; if ($line -match '(?i)(?:server|broker|host|url)[=:\s"]+(?:[a-z]+://)?([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9-]{2,})') { $r.LastServer = $matches[1].ToLower() }; if ($line -match '(?i)blast') { $r.LastProtocol = 'Blast' } elseif ($line -match '(?i)pcoip') { $r.LastProtocol = 'PCoIP' } elseif ($line -match '(?i)\brdp\b') { $r.LastProtocol = 'RDP' } }
                    }
                }
                $r.ConnectFailureCount24h = $fail; $r.ConnectSuccessCount24h = $succ
                if ($lastOk -gt [datetime]::MinValue) { $r.LastConnectTime = $lastOk.ToString('s') }
                $r.LogParseResult = 'Parsed'
                if ($r.LastServer -and -not $servers.Contains($r.LastServer) -and $servers.Count -lt $script:MaxServers) { $servers.Add($r.LastServer); $srcLog = $true }
            }
            catch { $r.LogParseResult = 'Error' }
        }
    } else { $r.LogParseResult = 'TimedOut'; $r.ConnectFailureCount24h = $TIMEDOUT; $r.ConnectSuccessCount24h = $TIMEDOUT }
    $r.ServerCount = $servers.Count; $r.ServerList = @($servers)
    $srcN = @($srcPolicy, $srcUser, $srcLog | Where-Object { $_ }).Count
    $r.ServerSource = if ($srcN -gt 1) { 'Multiple' } elseif ($srcPolicy) { 'Policy' } elseif ($srcUser) { 'User' } elseif ($srcLog) { 'Log' } else { 'None' }

    # -- Phase 3: probes ----------------------------------------------------------------------------------
    if ($servers.Count -eq 0) { $r.ProbeResult = 'NoServer'; $r.ProbeMs = $NOTAPPL }
    elseif (-not (Test-Budget)) { $r.ProbeResult = 'TimedOut'; $r.ProbeMs = $TIMEDOUT }
    else {
        $psw = [System.Diagnostics.Stopwatch]::StartNew(); $anyResolved = $false; $reach = $false
        foreach ($h in ($servers | Select-Object -First $script:MaxProbeHosts)) {
            if (-not (Test-Budget)) { break }
            $ok = $false; try { $ok = [bool](Resolve-DnsName -Name $h -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' }) } catch { }
            if (-not $ok) { continue }; $anyResolved = $true
            if (Test-TcpPort -TargetHost $h -Port 443 -TimeoutMs $script:NetTimeoutMs) {
                $reach = $true; $r.BlastPortReachable = 0
                foreach ($bp in $ClientBlastPorts) { if (Test-TcpPort -TargetHost $h -Port $bp -TimeoutMs $script:NetTimeoutMs) { $r.BlastPortReachable = 1; $r.BlastPortProbed = [string]$bp; break } }
                break
            }
        }
        $psw.Stop(); $r.ProbeMs = [int]$psw.Elapsed.TotalMilliseconds; $r.ServerResolvable = $anyResolved; $r.Server443Reachable = $reach
        $r.ProbeResult = if ($r.TimedOut) { 'TimedOut' } elseif (-not $anyResolved) { 'Unresolvable' } elseif ($reach) { 'Reachable' } else { 'Unreachable' }
    }

    # -- Phase 4: related caches ---------------------------------------------------------------------------
    foreach ($name in @('VPN', 'NetworkStack')) {
        $c = Get-ItemProperty -Path $RelatedCaches[$name]; $sc = $UNKNOWN; $rs = ''; $age = $UNKNOWN
        if ($c) {
            $d = 0.0; if ($null -ne $c.HealthScore -and [double]::TryParse([string]$c.HealthScore, [ref]$d)) { $sc = [int]$d }
            $rs = if ($c.HealthReason) { [string]$c.HealthReason } elseif ($c.Status) { [string]$c.Status } else { '' }
            $t = [datetime]::MinValue; if ($c.LastRun -and [datetime]::TryParse([string]$c.LastRun, [ref]$t)) { $age = [int]((Get-Date) - $t).TotalMinutes }
        }
        $r.Related[$name] = [ordered]@{ Score = $sc; Reason = $rs; CacheAgeMin = $age }
    }

    # -- Phase 5: score (mirrors the collector) ---------------------------------------------------------------
    $ded = New-Object System.Collections.Generic.List[object]
    function Ded { param([string]$R, [int]$P) $ded.Add([ordered]@{ Reason = $R; Points = $P }) }
    if ($r.ServerCount -gt 0 -and $r.ProbeResult -eq 'Unresolvable') { Ded 'ServerUnresolvable' 35 }
    if ($r.ServerCount -gt 0 -and $r.ProbeResult -eq 'Unreachable') { Ded 'ServerUnreachable443' 35 }
    if ($r.Server443Reachable -and $r.BlastPortReachable -eq 0) { Ded 'BlastPortUnreachable' 25 }
    if ($r.ConnectFailureCount24h -ge $script:ConnectFailureWarnCount) { Ded 'RepeatedConnectFailures' 25 }
    if ($r.ServerCount -eq 0) { Ded 'NoServerKnown' 10 }
    if ($r.UsbServiceRunning -eq 0) { Ded 'UsbServiceStopped' 10 }
    if ($script:ClientVersionFloor -and $r.Version) { try { if ([version]$r.Version -lt [version]$script:ClientVersionFloor) { Ded 'ClientOutdated' 10 } } catch { } }
    if ($r.CertCheckMode -eq '0') { Ded 'CertCheckDisabled' 5 }
    $vpnScore = $r.Related['VPN'].Score
    if ($vpnScore -ge 0 -and $vpnScore -lt 50) { Ded 'VpnDegraded' 5 }
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
