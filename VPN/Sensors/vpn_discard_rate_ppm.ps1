#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_discard_rate_ppm
    Data Type    : Integer
    Version      : 1.1.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02 (1.1.0: self-refreshing cache gate; see Invoke-VpnStateCollection.ps1 1.1.0)
    Timeout      : < 5 seconds on the fast path; up to 45 seconds when the gate reruns the collector
    Requires     : Invoke-VpnStateCollection.ps1 1.1.0 scheduled every 15-30 minutes

    Discarded packets per million on the active tunnel adapter. -1 means no active
    tunnel or no statistics available.

    Read from cache so it agrees with the deduction applied by vpn_health_score.

    Parts per million is used because tunnel discard rates are small enough that a
    whole-number percentage rounds every real problem to 0. A healthy tunnel sits
    near 0; sustained values above roughly 1000 ppm (0.1%) indicate an MTU mismatch,
    a saturated link, or an unstable path.

    The underlying counters are cumulative since adapter initialisation, so this is
    a lifetime average, not an instantaneous rate. On a long-lived tunnel it lags
    behind a problem that started recently.
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
                  -Name "DiscardRatePpm" -ErrorAction SilentlyContinue

    if ($null -eq $cached -or [string]::IsNullOrEmpty($cached.DiscardRatePpm)) {
        Write-Output -1
        return
    }

    Write-Output ([int]$cached.DiscardRatePpm)
    return
}
catch {
    Write-Output -1
    return
}
