#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_tunnel_mtu
    Data Type    : Integer
    Version      : 1.1.2
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03 (1.1.2: the gate holds the named mutex Global\DEX-VpnSensorGate while it decides and refreshes, so sensors on Hub's parallel threads no longer launch two collectors at once; 1.1.1: gate hashes the collector copy with .NET SHA256; Get-FileHash did not resolve in the child powershell.exe that Hub's sensor host spawned)
                   2026-11-02 (1.1.0: reads TunnelMtu from the cache behind the self-refreshing gate instead of querying the interface itself; see Invoke-VpnStateCollection.ps1 1.1.0)
    Timeout      : < 5 seconds on the fast path; up to 45 seconds when the gate reruns the collector, plus up to 45 seconds queued behind a sibling sensor's refresh (Hub allows 120)
    Requires     : Invoke-VpnStateCollection.ps1 1.1.0 scheduled every 15-30 minutes

    IPv4 MTU of the active tunnel adapter. -1 means no active tunnel.

    A VPN adds encapsulation overhead, so a healthy tunnel MTU is below the 1500-byte
    Ethernet default -- typically 1400 (IPsec), 1420 (WireGuard), or 1350-1400 (SSL).
    A tunnel still reporting 1500 risks an MTU black hole: oversized packets are
    dropped in transit and, where firewalls block the ICMP "Fragmentation Needed"
    response, the sender is never told. The symptom is a connection that pings fine
    but stalls on large transfers. Below 1280 (the IPv6 minimum) is pathological.

    NlMtu is part of the gate's fingerprint, so an MTU change since the last
    collection triggers a collector rerun before this value is read.
#>

# -- Self-refreshing cache gate. Identical in every vpn_* sensor; emits nothing. -----------------
# Cache fresh (LastChecked < 15 min)       -> read as is.
# Stale but adapter fingerprint unchanged  -> stamp LastChecked, read as is.
# Fingerprint changed                      -> rerun the collector's persisted copy after a
#                                             SHA-256 check (bounded at 40 s), then read.
# Anything else                            -> read the existing cache and mark $stale.
$stale = $false
function Get-VpnStateFingerprint {
    $x = '(?i)(vEthernet|Hyper-V|WSL|Docker|VMware|VirtualBox|Bluetooth|Loopback|Npcap|Wi-Fi Direct|Kernel Debug|Teredo|ISATAP|6to4|VirtualPCNet|TeamViewer|Parsec)'
    $e = foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue)) {
        $hw = $true
        if ($a.PSObject.Properties['HardwareInterface']) { $hw = [bool]$a.HardwareInterface }
        elseif ($a.PSObject.Properties['ConnectorPresent']) { $hw = [bool]$a.ConnectorPresent }
        if ($hw -or $a.Name -match $x -or $a.InterfaceDescription -match $x) { continue }
        $m = (Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).NlMtu
        $d = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses) -join ','
        "$($a.ifIndex)|$($a.Status)|$m|$d"
    }
    return ((@($e) | Sort-Object) -join ';')
}
$mx = $null
try {
    $k = 'HKLM:\Software\AirWatch\Extensions\VPN'
    $c = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
    $t = [datetime]::MinValue
    $s = if ($c.LastChecked) { $c.LastChecked } else { $c.LastRun }
    [void][datetime]::TryParse([string]$s, [ref]$t)
    if ($t -lt (Get-Date).AddMinutes(-15)) {
        # One sensor refreshes at a time: Hub runs sensors on several threads, and two
        # gate-launched collector reruns collided on 2026-11-03 (TEST-VALIDATION 13.2.u).
        # Re-read after the wait so a sensor queued behind a refresh takes the fast path.
        $mx = New-Object System.Threading.Mutex($false, 'Global\DEX-VpnSensorGate')
        $got = $false
        try { $got = $mx.WaitOne(45000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { $mx.Dispose(); $mx = $null; throw 'gate busy' }
        $c = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        $s = if ($c.LastChecked) { $c.LastChecked } else { $c.LastRun }
        [void][datetime]::TryParse([string]$s, [ref]$t)
    }
    if ($t -lt (Get-Date).AddMinutes(-15)) {
        $now = Get-Date -Format 'o'
        if ($null -ne $c.StateFingerprint -and (Get-VpnStateFingerprint) -eq [string]$c.StateFingerprint) {
            Set-ItemProperty -Path $k -Name 'LastChecked' -Value $now -Type String
        }
        elseif ($c.CollectorHash -and $c.CollectorPath -and (Test-Path -LiteralPath $c.CollectorPath) -and
                ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($c.CollectorPath))) -replace '-', '') -eq $c.CollectorHash) {
            # Claim first so sibling sensors running now take the fast path instead of each starting a collector.
            Set-ItemProperty -Path $k -Name 'LastChecked' -Value $now -Type String
            $env:VPN_COLLECTOR_QUIET = '1'
            $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden -PassThru `
                     -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$($c.CollectorPath)`""
            if (-not $p.WaitForExit(40000)) { $p.Kill(); $stale = $true }
            elseif ($p.ExitCode -ne 0) { $stale = $true }
        }
        else { $stale = $true }
    }
}
catch { $stale = $true }
finally { if ($mx) { try { $mx.ReleaseMutex() } catch { }; $mx.Dispose() } }
# -- End of gate --------------------------------------------------------------------------------

try {
    $cached = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\VPN" `
                  -Name "TunnelMtu" -ErrorAction SilentlyContinue

    if ($null -eq $cached -or [string]::IsNullOrEmpty($cached.TunnelMtu)) {
        Write-Output -1
        return
    }

    Write-Output ([int]$cached.TunnelMtu)
    return
}
catch {
    Write-Output -1
    return
}
