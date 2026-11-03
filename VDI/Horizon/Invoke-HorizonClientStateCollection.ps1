<#
.SYNOPSIS
    Horizon Client state collection for Workspace ONE UEM sensors (endpoint side).

.DESCRIPTION
    Measures the Horizon Client on a physical endpoint once, scores it, and caches every
    value to HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Client so the hzn_client_*
    sensors read in milliseconds. Runs as SYSTEM but reads the console user's own
    configuration (HKCU server list, certificate-check mode) and the tail of that user's
    client log, because connection failures live there and nowhere else. Phases:
    install, version, USB service, console user; configured servers (policy, then user);
    client log tail (success/failure counts, last server, last connect); DNS, TCP 443 and
    Blast-port probes; VPN and network-stack caches on this endpoint; score.

    Contract (value table, deductions, sensors, KB resolution points): VDI/Horizon/SPEC.md
    rev 1. KB-HZN-nn variables below hold candidate lists the internal build replaces with
    the settled answer, keeping the fallback. Never rename them.

.NOTES
    Script Name  : Invoke-HorizonClientStateCollection.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03
    Timeout      : 30 seconds budget (deploy with a 60 second UEM timeout)
    Schedule     : Every 30-60 minutes on endpoints
    Built from   : VDI/Horizon/SPEC.md rev 1

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
function Invoke-HorizonClientStateCollection {
[CmdletBinding()]
param()

$SCRIPT_VERSION = '1.0.0'
$SCRIPT_VARIANT = ''      # internal build: 'internal'
$RegPath = 'HKLM:\Software\AirWatch\Extensions\VDI\Horizon\Client'
$LogPath = "$env:SystemRoot\Temp\UEM_HorizonClientStateCollection.log"

# -- Tunables --
$ConnectFailureWarnCount = 5
$NetTimeoutMs            = 2000
$MaxProbeHosts           = 3
$ClientVersionFloor      = ''          # KB-HZN-20: '' disables the ClientOutdated reason
$LogTailBytes            = 524288
$LogLookbackHours        = 24
$MaxServers              = 10

# -- KB resolution points (VDI/Horizon/SPEC.md section 3) --
$ClientUninstallPattern      = '(?i)^(Omnissa|VMware) Horizon Client'                                                        # KB-HZN-14
$ClientRegistryRoots         = @('SOFTWARE\Omnissa\Horizon\Client', 'SOFTWARE\VMware, Inc.\VMware VDM\Client')              # KB-HZN-15 (relative to HKU\<SID>)
$ClientPolicyRoots           = @('HKLM:\SOFTWARE\Policies\Omnissa\Horizon\Client', 'HKLM:\SOFTWARE\Policies\VMware, Inc.\VMware VDM\Client')
$ClientServerValueCandidates = @('Server', 'ServerURL', 'DefaultServer', 'RecentServers')
$CertCheckValueName          = 'CertCheckMode'
$ClientLogDirs               = @('AppData\Local\Omnissa\Horizon\Logs', 'AppData\Local\VMware\VDM\Logs')                    # KB-HZN-16 (relative to the profile)
$ClientLogFilePatterns       = @('*horizon*client*.txt', 'vmware-horizon-client-*.txt', 'vmware-horizon-client*.log')
$ClientLogSuccessRegex       = '(?i)connected to|session.*established|login succeeded|authentication succeeded'
$ClientLogFailureRegex       = '(?i)connect(ion)? (failed|error|refused)|unable to (connect|resolve)|certificate.*(invalid|rejected)|authentication failed|tunnel.*(failed|error)'
$ClientUsbServiceNames       = @('vmware-usbarbitrator')                                                                      # KB-HZN-17
$ClientUsbDisplayPattern     = '(?i)USB Arbitration'
$ClientBlastPorts            = @(8443, 22443)                                                                                 # KB-HZN-19: UAG first, then direct
$VpnCachePath                = 'HKLM:\Software\AirWatch\Extensions\VPN'
$NetworkStackCachePaths      = @('HKLM:\Software\AirWatch\Extensions\NetworkStack\Remediation', 'HKLM:\Software\AirWatch\Extensions\NetworkStack')

# -- Run header --
$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Output "[$RunEventId] Executing Invoke-HorizonClientStateCollection, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'"
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
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    if ($Raw -match '^(?:[a-z]+://)?([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9-]{2,})') { return $matches[1].ToLower() }
    return ''
}

$m = [ordered]@{
    Installed = 0; Version = ''; BrandRoot = ''; InstallLocation = ''
    ClientUser = ''; ClientUserSid = ''
    UsbServiceName = ''; UsbServiceRunning = -1
    ServerCount = 0; ServerList = ''; ServerSource = 'None'
    ServerResolvable = 0; Server443Reachable = 0; BlastPortReachable = -1; BlastPortProbed = ''; ProbeResult = 'NotProbed'; ProbeMs = -1
    CertCheckMode = ''
    LogFileUsed = ''; LogParseResult = 'NoLog'; ConnectFailureCount24h = -1; ConnectSuccessCount24h = -1
    LastConnectTime = ''; LastServer = ''; LastProtocol = ''
    VpnHealthScore = -1; VpnHealthReason = ''; NetworkStackStatus = ''
    HealthScore = -1; HealthReason = 'CollectionError'; Deductions = ''; Status = 'CollectionError'
}

function Write-Cache {
    param([bool]$Commit)
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null }
    $ver = if ($SCRIPT_VARIANT) { "$SCRIPT_VERSION+$SCRIPT_VARIANT" } else { $SCRIPT_VERSION }
    Set-ItemProperty -Path $RegPath -Name 'ScriptVersion' -Value $ver -Type String -ErrorAction Stop
    $dwords = @('Installed', 'ServerResolvable', 'Server443Reachable')
    foreach ($k in $m.Keys) {
        if ($dwords -contains $k) { Set-ItemProperty -Path $RegPath -Name $k -Value ([int]$m[$k]) -Type DWord -ErrorAction Stop }
        else                      { Set-ItemProperty -Path $RegPath -Name $k -Value ([string]$m[$k]) -Type String -ErrorAction Stop }
    }
    Set-ItemProperty -Path $RegPath -Name 'CollectionDurationMs' -Value ([string][int]$sw.Elapsed.TotalMilliseconds) -Type String -ErrorAction Stop
    if ($Commit) { Set-ItemProperty -Path $RegPath -Name 'LastRun' -Value (Get-Date -Format 'o') -Type String -ErrorAction Stop }
}

try {
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $RegPath -Name 'LastAttempt' -Value (Get-Date -Format 'o') -Type String -ErrorAction Stop

    # ---- Phase 1: install, USB service, console user ------------------------------------------------
    $uninst = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match $ClientUninstallPattern })
    if ($uninst.Count -gt 0) {
        $m.Installed = 1; $m.Version = [string]$uninst[0].DisplayVersion; $m.InstallLocation = [string]$uninst[0].InstallLocation
        $m.BrandRoot = if ($uninst[0].DisplayName -match '(?i)Omnissa') { 'Omnissa' } else { 'VMware' }
    }
    if ($m.Installed -eq 0) {
        $m.HealthScore = -1; $m.HealthReason = 'NotInstalled'; $m.Status = 'NotApplicable'; $m.Deductions = ''
        Write-Cache -Commit $true
        Write-Output "$HEAD No Horizon Client detected on this device. Cached NotInstalled to $RegPath"
        Write-Log 'No Horizon Client detected. Exiting.'
        exit 0
    }

    $allSvc = @(Get-Service -ErrorAction SilentlyContinue)
    $usb = $null
    foreach ($s in $allSvc) { if ($ClientUsbServiceNames -contains $s.Name) { $usb = $s; break } }
    if (-not $usb) { foreach ($s in $allSvc) { if ($s.DisplayName -match $ClientUsbDisplayPattern) { $usb = $s; break } } }
    if ($usb) { $m.UsbServiceName = $usb.Name; $m.UsbServiceRunning = [int]($usb.Status -eq 'Running') }

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $profilePath = ''
    if ($cs -and $cs.UserName) {
        $m.ClientUser = [string]$cs.UserName
        try { $m.ClientUserSid = ([Security.Principal.NTAccount]$m.ClientUser).Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
        if ($m.ClientUserSid) {
            $pl = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($m.ClientUserSid)" -ErrorAction SilentlyContinue
            if ($pl -and $pl.ProfileImagePath) { $profilePath = [string]$pl.ProfileImagePath }
        }
    }

    # ---- Phase 2: configured servers --------------------------------------------------------------------
    $servers = New-Object System.Collections.Generic.List[string]
    $srcPolicy = $false; $srcUser = $false; $srcLog = $false
    function Add-ServersFromKey {
        param([string]$Key)
        $added = $false
        if (-not (Test-Path -LiteralPath $Key)) { return $false }
        $p = Get-ItemProperty -Path $Key -ErrorAction SilentlyContinue
        foreach ($vn in $ClientServerValueCandidates) {
            $raw = $p.$vn
            if ($null -eq $raw) { continue }
            foreach ($piece in ((([string[]]$raw) -join ' ') -split '[;,\s]+')) {
                $h = Get-HostName $piece
                if ($h -and -not $servers.Contains($h) -and $servers.Count -lt $MaxServers) { $servers.Add($h); $added = $true }
            }
        }
        foreach ($sub in @(Get-ChildItem -Path $Key -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '(?i)server' })) {
            $h = Get-HostName $sub.PSChildName
            if ($h -and -not $servers.Contains($h) -and $servers.Count -lt $MaxServers) { $servers.Add($h); $added = $true }
            $sp = Get-ItemProperty -Path $sub.PSPath -ErrorAction SilentlyContinue
            foreach ($prop in @($sp.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and $_.Value -is [string] })) {
                $h = Get-HostName ([string]$prop.Value)
                if ($h -and -not $servers.Contains($h) -and $servers.Count -lt $MaxServers) { $servers.Add($h); $added = $true }
            }
            foreach ($leaf in @(Get-ChildItem -Path $sub.PSPath -ErrorAction SilentlyContinue)) {
                $h = Get-HostName $leaf.PSChildName
                if ($h -and -not $servers.Contains($h) -and $servers.Count -lt $MaxServers) { $servers.Add($h); $added = $true }
            }
        }
        return $added
    }
    foreach ($k in $ClientPolicyRoots) { if (Add-ServersFromKey -Key $k) { $srcPolicy = $true } }
    if ($m.ClientUserSid) {
        foreach ($rel in $ClientRegistryRoots) {
            $k = "Registry::HKEY_USERS\$($m.ClientUserSid)\$rel"
            if (Add-ServersFromKey -Key $k) { $srcUser = $true }
            $cc = (Get-ItemProperty -Path $k -Name $CertCheckValueName -ErrorAction SilentlyContinue).$CertCheckValueName
            if ($null -ne $cc -and -not $m.CertCheckMode) { $m.CertCheckMode = [string]$cc }
        }
        foreach ($k in $ClientPolicyRoots) {
            $cc = (Get-ItemProperty -Path $k -Name $CertCheckValueName -ErrorAction SilentlyContinue).$CertCheckValueName
            if ($null -ne $cc) { $m.CertCheckMode = [string]$cc }   # policy wins
        }
    }

    # ---- Phase 3: client log tail ------------------------------------------------------------------------
    if (-not $profilePath) { $m.LogParseResult = 'NoUser' }
    else {
        $logFile = $null
        foreach ($rel in $ClientLogDirs) {
            $dir = Join-Path $profilePath $rel
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            foreach ($pat in $ClientLogFilePatterns) {
                $f = Get-ChildItem -Path $dir -Filter $pat -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($f) { if (-not $logFile -or $f.LastWriteTime -gt $logFile.LastWriteTime) { $logFile = $f } }
            }
        }
        if (-not $logFile) { $m.LogParseResult = 'NoLog' }
        else {
            $m.LogFileUsed = $logFile.FullName
            try {
                $fs = [System.IO.File]::Open($logFile.FullName, 'Open', 'Read', 'ReadWrite')
                try {
                    $len = $fs.Length; $take = [math]::Min($len, $LogTailBytes)
                    $fs.Seek($len - $take, 'Begin') | Out-Null
                    $buf = New-Object byte[] $take; $fs.Read($buf, 0, $take) | Out-Null
                }
                finally { $fs.Close() }
                $text = [System.Text.Encoding]::UTF8.GetString($buf)
                $since = (Get-Date).AddHours(-$LogLookbackHours)
                $fail = 0; $succ = 0; $lastOk = [datetime]::MinValue
                foreach ($line in ($text -split "`r?`n")) {
                    if ($line -notmatch '^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})') { continue }
                    $ts = [datetime]::MinValue
                    if (-not [datetime]::TryParse($matches[1].Replace('T', ' '), [ref]$ts)) { continue }
                    if ($ts -lt $since) { continue }
                    if ($line -match $ClientLogFailureRegex) { $fail++ }
                    elseif ($line -match $ClientLogSuccessRegex) {
                        $succ++
                        if ($ts -gt $lastOk) {
                            $lastOk = $ts
                            if ($line -match '(?i)(?:server|broker|host|url)[=:\s"]+(?:[a-z]+://)?([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9-]{2,})') { $m.LastServer = $matches[1].ToLower() }
                            if ($line -match '(?i)blast') { $m.LastProtocol = 'Blast' } elseif ($line -match '(?i)pcoip') { $m.LastProtocol = 'PCoIP' } elseif ($line -match '(?i)\brdp\b') { $m.LastProtocol = 'RDP' }
                        }
                    }
                }
                $m.ConnectFailureCount24h = $fail; $m.ConnectSuccessCount24h = $succ
                if ($lastOk -gt [datetime]::MinValue) { $m.LastConnectTime = $lastOk.ToString('s') }
                $m.LogParseResult = 'Parsed'
                if ($m.LastServer -and -not $servers.Contains($m.LastServer) -and $servers.Count -lt $MaxServers) { $servers.Add($m.LastServer); $srcLog = $true }
            }
            catch { $m.LogParseResult = 'Error'; Write-Log "Log parse failed: $($_.Exception.Message)" -Level 'WARN' }
        }
    }
    $m.ServerCount = $servers.Count; $m.ServerList = ($servers -join ';')
    $srcN = @($srcPolicy, $srcUser, $srcLog | Where-Object { $_ }).Count
    $m.ServerSource = if ($srcN -gt 1) { 'Multiple' } elseif ($srcPolicy) { 'Policy' } elseif ($srcUser) { 'User' } elseif ($srcLog) { 'Log' } else { 'None' }

    # ---- Phase 4: probes ------------------------------------------------------------------------------------
    if ($servers.Count -eq 0) { $m.ProbeResult = 'NoServer' }
    else {
        $psw = [System.Diagnostics.Stopwatch]::StartNew()
        $anyResolved = $false; $reach443 = $false
        foreach ($h in ($servers | Select-Object -First $MaxProbeHosts)) {
            $ok = $false
            try { $ok = [bool](Resolve-DnsName -Name $h -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' }) } catch { }
            if (-not $ok) { continue }
            $anyResolved = $true
            if (Test-TcpPort -TargetHost $h -Port 443 -TimeoutMs $NetTimeoutMs) {
                $reach443 = $true
                $m.BlastPortReachable = 0
                foreach ($bp in $ClientBlastPorts) { if (Test-TcpPort -TargetHost $h -Port $bp -TimeoutMs $NetTimeoutMs) { $m.BlastPortReachable = 1; $m.BlastPortProbed = [string]$bp; break } }
                break
            }
        }
        $psw.Stop(); $m.ProbeMs = [int]$psw.Elapsed.TotalMilliseconds
        $m.ServerResolvable = [int]$anyResolved; $m.Server443Reachable = [int]$reach443
        $m.ProbeResult = if (-not $anyResolved) { 'Unresolvable' } elseif ($reach443) { 'Reachable' } else { 'Unreachable' }
    }

    # ---- Phase 5: related caches on this endpoint -------------------------------------------------------------
    $vpn = Get-ItemProperty -Path $VpnCachePath -ErrorAction SilentlyContinue
    if ($vpn) {
        $vs = 0.0
        if ($null -ne $vpn.HealthScore -and [double]::TryParse([string]$vpn.HealthScore, [ref]$vs)) { $m.VpnHealthScore = [int]$vs }
        if ($vpn.HealthReason) { $m.VpnHealthReason = [string]$vpn.HealthReason }
    }
    foreach ($k in $NetworkStackCachePaths) {
        $ns = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if ($ns -and $ns.Status) { $m.NetworkStackStatus = [string]$ns.Status; break }
    }

    # ---- Phase 6: score (SPEC 5.2) ------------------------------------------------------------------------------
    $ded = New-Object System.Collections.Generic.List[object]
    function Ded { param([string]$R, [int]$P) $ded.Add(@{ R = $R; P = $P }) }
    if ($m.ServerCount -gt 0 -and $m.ProbeResult -eq 'Unresolvable') { Ded 'ServerUnresolvable' 35 }
    if ($m.ServerCount -gt 0 -and $m.ProbeResult -eq 'Unreachable') { Ded 'ServerUnreachable443' 35 }
    if ($m.Server443Reachable -eq 1 -and $m.BlastPortReachable -eq 0) { Ded 'BlastPortUnreachable' 25 }
    if ($m.ConnectFailureCount24h -ge $ConnectFailureWarnCount) { Ded 'RepeatedConnectFailures' 25 }
    if ($m.ServerCount -eq 0) { Ded 'NoServerKnown' 10 }
    if ($m.UsbServiceRunning -eq 0) { Ded 'UsbServiceStopped' 10 }
    if ($ClientVersionFloor -and $m.Version) {
        try { if ([version]$m.Version -lt [version]$ClientVersionFloor) { Ded 'ClientOutdated' 10 } } catch { }
    }
    if ($m.CertCheckMode -eq '0') { Ded 'CertCheckDisabled' 5 }
    if ($m.VpnHealthScore -ge 0 -and $m.VpnHealthScore -lt 50) { Ded 'VpnDegraded' 5 }

    $score = 100; foreach ($d in $ded) { $score -= $d.P }; if ($score -lt 0) { $score = 0 }
    $m.HealthScore = $score
    $m.HealthReason = if ($ded.Count -eq 0) { 'Healthy' } else { ($ded | Sort-Object { $_.P } -Descending | Select-Object -First 1).R }
    $m.Deductions = (@($ded | Sort-Object { $_.P } -Descending | ForEach-Object { "$($_.R):$($_.P)" }) -join ';')
    $m.Status = if ($ded.Count -eq 0) { 'Healthy' } else { 'Degraded' }

    Write-Cache -Commit $true
    Write-Output "$HEAD Horizon Client $($m.Version) ($($m.BrandRoot)) for '$($m.ClientUser)': score $($m.HealthScore) ($($m.HealthReason)); servers $($m.ProbeResult) [$($m.ServerList)] from $($m.ServerSource); Blast port $($m.BlastPortReachable) ($($m.BlastPortProbed)); log $($m.LogParseResult) failures24h $($m.ConnectFailureCount24h) last connect '$($m.LastConnectTime)'; VPN $($m.VpnHealthScore)"
    Write-Output "$HEAD Deductions: $(if ($m.Deductions) { $m.Deductions } else { 'none' }). Cached to $RegPath in $([int]$sw.Elapsed.TotalMilliseconds) ms."
    Write-Log "Score $($m.HealthScore) ($($m.HealthReason)) deductions [$($m.Deductions)] servers $($m.ProbeResult) log $($m.LogParseResult) in $([int]$sw.Elapsed.TotalMilliseconds) ms"
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
Invoke-HorizonClientStateCollection
