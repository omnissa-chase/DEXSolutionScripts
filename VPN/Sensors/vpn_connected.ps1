#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_connected
    Data Type    : Boolean
    Version      : 1.1.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02 (1.1.0: reads the Connected DWORD from the cache behind the self-refreshing gate instead of enumerating adapters itself; see Invoke-VpnStateCollection.ps1 1.1.0)
    Timeout      : < 5 seconds on the fast path; up to 45 seconds when the gate reruns the collector
    Requires     : Invoke-VpnStateCollection.ps1 1.1.0 scheduled every 15-30 minutes

    True when a tunnel adapter is Up with a routable IPv4 address.

    1.0 read the adapters live because a 30-minute-stale connection state is
    misleading. The gate below removes that objection: adapter Status is part of the
    fingerprint, so a tunnel that came up or went down since the last collection
    triggers a collector rerun before this value is read.

    Vendor-agnostic: a tunnel is an Up adapter with HardwareInterface = $false that
    holds a routable IPv4 address and is not known virtual infrastructure. No vendor
    product names are matched.

    No value is emitted when the cache has never been written: there is no safe
    boolean fallback.
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
try {
    $k = 'HKLM:\Software\AirWatch\Extensions\VPN'
    $c = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
    $t = [datetime]::MinValue
    $s = if ($c.LastChecked) { $c.LastChecked } else { $c.LastRun }
    [void][datetime]::TryParse([string]$s, [ref]$t)
    if ($t -lt (Get-Date).AddMinutes(-15)) {
        $now = Get-Date -Format 'o'
        if ($null -ne $c.StateFingerprint -and (Get-VpnStateFingerprint) -eq [string]$c.StateFingerprint) {
            Set-ItemProperty -Path $k -Name 'LastChecked' -Value $now -Type String
        }
        elseif ($c.CollectorHash -and $c.CollectorPath -and (Test-Path -LiteralPath $c.CollectorPath) -and
                (Get-FileHash -LiteralPath $c.CollectorPath -Algorithm SHA256).Hash -eq $c.CollectorHash) {
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
# -- End of gate --------------------------------------------------------------------------------

try {
    $cached = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\VPN" `
                  -Name "Connected" -ErrorAction SilentlyContinue

    if ($null -eq $cached -or $null -eq $cached.Connected) {
        # No safe boolean fallback - return without a value.
        return
    }

    Write-Output ([bool][int]$cached.Connected)
    return
}
catch {
    return
}
