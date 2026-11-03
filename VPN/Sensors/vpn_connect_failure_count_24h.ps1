#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_connect_failure_count_24h
    Data Type    : Integer
    Version      : 1.1.1
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03 (1.1.1: gate hashes the collector copy with .NET SHA256; Get-FileHash did not resolve in the child powershell.exe that Hub's sensor host spawned)
                   2026-11-02 (1.1.0: self-refreshing cache gate; see Invoke-VpnStateCollection.ps1 1.1.0)
    Timeout      : < 5 seconds on the fast path; up to 45 seconds when the gate reruns the collector
    Requires     : Invoke-VpnStateCollection.ps1 1.1.0 scheduled every 15-30 minutes

    Failed VPN connection attempts in the last 24 hours. -1 means unknown.

    Counted from RasClient event 20227, which only the Windows built-in RAS stack
    writes. Third-party clients log failures in vendor-specific locations, so 0 on
    a device running a third-party client means "none observed", not "none
    occurred". Treat this as a floor, and pair it with vpn_flap_count_24h, which
    is vendor-agnostic.
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
# -- End of gate --------------------------------------------------------------------------------

try {
    $cached = Get-ItemProperty -Path "HKLM:\Software\AirWatch\Extensions\VPN" `
                  -Name "ConnectFailureCount24h" -ErrorAction SilentlyContinue

    if ($null -eq $cached -or [string]::IsNullOrEmpty($cached.ConnectFailureCount24h)) {
        Write-Output -1
        return
    }

    Write-Output ([int]$cached.ConnectFailureCount24h)
    return
}
catch {
    Write-Output -1
    return
}
