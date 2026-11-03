#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_dns_configured
    Data Type    : Boolean
    Version      : 1.1.2
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03 (1.1.2: the gate holds the named mutex Global\DEX-VpnSensorGate while it decides and refreshes, so sensors on Hub's parallel threads no longer launch two collectors at once; 1.1.1: gate hashes the collector copy with .NET SHA256; Get-FileHash did not resolve in the child powershell.exe that Hub's sensor host spawned)
                   2026-11-02 (1.1.0: reads the DnsConfigured DWORD from the cache behind the self-refreshing gate instead of querying the DNS client itself; see Invoke-VpnStateCollection.ps1 1.1.0)
    Timeout      : < 5 seconds on the fast path; up to 45 seconds when the gate reruns the collector, plus up to 45 seconds queued behind a sibling sensor's refresh (Hub allows 120)
    Requires     : Invoke-VpnStateCollection.ps1 1.1.0 scheduled every 15-30 minutes

    True when the active tunnel adapter has at least one IPv4 DNS server assigned.

    1.0 read the DNS client live because a stale DNS state on a tunnel that has since
    changed is worse than no sample. The gate below removes that objection: each
    candidate adapter's IPv4 DNS servers are part of the fingerprint, so a change
    triggers a collector rerun before this value is read.

    A tunnel with no DNS is the classic "VPN says connected but nothing internal
    resolves" failure. Name resolution falls back to the physical adapter's public
    resolvers, so internal hostnames fail while the tunnel itself looks perfectly
    healthy.

    No value is emitted when there is no active tunnel (cached Connected is 0): false
    would read as a real misconfiguration on a device that simply is not connected.
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
    $cached = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\VPN" -ErrorAction SilentlyContinue

    if ($null -eq $cached -or $null -eq $cached.DnsConfigured -or [int]$cached.Connected -ne 1) {
        # No active tunnel (or no cache) - no meaningful boolean to report.
        return
    }

    Write-Output ([bool][int]$cached.DnsConfigured)
    return
}
catch {
    return
}
