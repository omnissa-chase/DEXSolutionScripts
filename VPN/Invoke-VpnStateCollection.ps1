<#
.SYNOPSIS
    Vendor-agnostic VPN state collection for Workspace ONE UEM sensors.

.DESCRIPTION
    Collects VPN tunnel state without matching on vendor product names, then caches
    every value to the registry so lightweight sensors can read them in milliseconds.

    A tunnel is identified structurally rather than by name: an adapter that is Up,
    reports HardwareInterface = $false, holds a routable IPv4 address, and is not a
    known non-VPN virtual adapter (Hyper-V, WSL, Docker, VMware, Bluetooth PAN, etc.).
    This detects any VPN client -- including ones not yet known to this script.

    Performs the work that sensors are forbidden to do (event log mining, adapter
    statistics, multi-second collection) per the Sensor Authoring Rules, and computes
    the composite health score once so all sensors agree on a single value.

    Cached to: HKLM:\Software\AirWatch\Extensions\VPN

    +----+--------------------------+---------+----------------------------------+
    | #  | Registry Value           | Type    | Consumed By Sensor               |
    +----+--------------------------+---------+----------------------------------+
    |  1 | HealthScore              | String  | vpn_health_score      (Integer)  |
    |  2 | HealthReason             | String  | vpn_health_reason     (String)   |
    |  3 | Connected                | DWORD   | vpn_connected         (Boolean)  |
    |  4 | TunnelMode               | String  | vpn_tunnel_mode       (String)   |
    |  5 | AdapterName              | String  | vpn_adapter_name      (String)   |
    |  6 | TunnelMtu                | String  | vpn_tunnel_mtu        (Integer)  |
    |  7 | LastConnectTime          | String  | vpn_last_connect_time (DateTime) |
    |  8 | SessionDurationMinutes   | String  | vpn_session_duration_minutes     |
    |  9 | FlapCount24h             | String  | vpn_flap_count_24h    (Integer)  |
    | 10 | ConnectFailureCount24h   | String  | vpn_connect_failure_count_24h    |
    | 11 | DnsConfigured            | DWORD   | vpn_dns_configured    (Boolean)  |
    | 12 | DiscardRatePpm           | String  | vpn_discard_rate_ppm  (Integer)  |
    | 13 | ClientCount              | String  | vpn_client_count      (Integer)  |
    +----+--------------------------+---------+----------------------------------+

    A HealthScore of -1 means no VPN client is present on the device. This is
    deliberately distinct from a low score, which means a VPN client is present and
    unhealthy. Collapsing the two would make fleet reporting meaningless.

.NOTES
    Script Name  : Invoke-VpnStateCollection.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-03
    Timeout      : 30 seconds
    Schedule     : Every 15-30 minutes

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding()]
param()

$SCRIPT_VERSION = "1.0.0"
$RegPath        = "HKLM:\Software\AirWatch\Extensions\VPN"
$LogPath        = "$env:SystemRoot\Temp\UEM_VpnStateCollection.log"

$RunEventId = ([Random]::new()).Next(1000, 9999)
$HEAD       = "`r`n[$RunEventId]"

Write-Host "[$RunEventId] Executing Invoke-VpnStateCollection, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] [$RunEventId] [$Level] $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8 -ErrorAction SilentlyContinue
}

# Virtual adapters that are structurally VPN-like but are never VPN tunnels.
$ExcludedAdapterPattern = '(?i)(vEthernet|Hyper-V|WSL|Docker|VMware|VirtualBox|Bluetooth|Loopback|Npcap|Wi-Fi Direct|Kernel Debug|Teredo|ISATAP|6to4|VirtualPCNet|TeamViewer|Parsec)'

function Test-IsExcludedAdapter {
    param($Adapter)
    if ($Adapter.Name -match $ExcludedAdapterPattern) { return $true }
    if ($Adapter.InterfaceDescription -match $ExcludedAdapterPattern) { return $true }
    return $false
}

# Structural tunnel test: non-hardware adapters that are not known virtual infrastructure.
function Get-CandidateTunnelAdapter {
    $all = Get-NetAdapter -ErrorAction SilentlyContinue
    if (-not $all) { return @() }

    $candidates = foreach ($a in $all) {
        # Older builds may not expose HardwareInterface; ConnectorPresent is the fallback.
        $isHardware = $true
        if ($a.PSObject.Properties['HardwareInterface']) {
            $isHardware = [bool]$a.HardwareInterface
        }
        elseif ($a.PSObject.Properties['ConnectorPresent']) {
            $isHardware = [bool]$a.ConnectorPresent
        }

        if ($isHardware) { continue }
        if (Test-IsExcludedAdapter -Adapter $a) { continue }
        $a
    }

    return @($candidates)
}

function Get-ActiveTunnelAdapter {
    param($Candidates)
    foreach ($a in $Candidates) {
        if ($a.Status -ne 'Up') { continue }
        $ip = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' }
        if ($ip) { return $a }
    }
    return $null
}

function Test-EventMatchesTunnel {
    param($WinEvent, [string[]]$Descriptions)
    foreach ($p in $WinEvent.Properties) {
        $v = $p.Value
        if ($v -is [string] -and $v) {
            foreach ($d in $Descriptions) {
                if ($v -eq $d) { return $true }
            }
        }
    }
    return $false
}

# -- Defaults ------------------------------------------------------------------
$connected       = $false
$tunnelMode      = 'None'
$adapterName     = ''
$tunnelMtu       = -1
$lastConnectTime = ''
$sessionMinutes  = -1
$flapCount       = -1
$failCount       = -1
$dnsConfigured   = $false
$discardPpm      = -1
$clientCount     = 0
$healthScore     = -1
$healthReason    = 'NoVpnClient'

try {
    # -- 1. Identify tunnel adapters -------------------------------------------
    $candidates  = Get-CandidateTunnelAdapter
    $clientCount = @($candidates).Count
    Write-Log "Found $clientCount candidate tunnel adapter(s)."

    if ($clientCount -eq 0) {
        Write-Host "$HEAD No VPN client detected on this device."
        Write-Log "No VPN client detected. HealthScore = -1."
    }
    else {
        $tunnel = Get-ActiveTunnelAdapter -Candidates $candidates

        if ($tunnel) {
            $connected   = $true
            $adapterName = $tunnel.InterfaceDescription
            Write-Host "$HEAD Active tunnel: $adapterName (ifIndex $($tunnel.ifIndex))"
            Write-Log "Active tunnel: $adapterName (ifIndex $($tunnel.ifIndex))"

            # -- 2. Tunnel mode from default route ownership --------------------
            $defRoutes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
            $viaTunnel = @($defRoutes | Where-Object { $_.ifIndex -eq $tunnel.ifIndex })
            $viaOther  = @($defRoutes | Where-Object { $_.ifIndex -ne $tunnel.ifIndex })

            if ($viaTunnel.Count -gt 0 -and $viaOther.Count -eq 0) { $tunnelMode = 'Full' }
            else { $tunnelMode = 'Split' }
            Write-Log "Tunnel mode: $tunnelMode (tunnel default routes: $($viaTunnel.Count), other: $($viaOther.Count))"

            # -- 3. MTU ---------------------------------------------------------
            $ipIf = Get-NetIPInterface -InterfaceIndex $tunnel.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            if ($ipIf -and $ipIf.NlMtu) { $tunnelMtu = [int]$ipIf.NlMtu }
            Write-Log "Tunnel MTU: $tunnelMtu"

            # -- 4. DNS on the tunnel -------------------------------------------
            $dns = Get-DnsClientServerAddress -InterfaceIndex $tunnel.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($dns -and @($dns.ServerAddresses).Count -gt 0) { $dnsConfigured = $true }
            Write-Log "DNS configured on tunnel: $dnsConfigured"

            # -- 5. Discard rate ------------------------------------------------
            $stats = Get-NetAdapterStatistics -InterfaceIndex $tunnel.ifIndex -ErrorAction SilentlyContinue
            if ($stats) {
                $rxProp = if ($stats.PSObject.Properties['ReceivedUnicastPackets']) { [double]$stats.ReceivedUnicastPackets } else { 0 }
                $txProp = if ($stats.PSObject.Properties['SentUnicastPackets'])     { [double]$stats.SentUnicastPackets }     else { 0 }
                $rxDrop = if ($stats.PSObject.Properties['ReceivedDiscardedPackets']) { [double]$stats.ReceivedDiscardedPackets } else { 0 }
                $txDrop = if ($stats.PSObject.Properties['OutboundDiscardedPackets']) { [double]$stats.OutboundDiscardedPackets } else { 0 }

                $totalPackets = $rxProp + $txProp
                if ($totalPackets -gt 0) {
                    $discardPpm = [int][math]::Round((($rxDrop + $txDrop) / $totalPackets) * 1000000)
                }
                else {
                    $discardPpm = 0
                }
            }
            Write-Log "Discard rate: $discardPpm ppm"
        }
        else {
            Write-Host "$HEAD VPN client present but no active tunnel."
            Write-Log "VPN client present but no active tunnel."
        }

        # -- 6. Flap count and last connect from NetworkProfile ------------------
        # Vendor-agnostic: NetworkProfile logs connect/disconnect for ANY adapter,
        # unlike RasClient which only covers the Windows built-in VPN stack.
        $tunnelDescs = @($candidates | ForEach-Object { $_.InterfaceDescription })
        $since       = (Get-Date).AddHours(-24)

        try {
            $profileEvents = Get-WinEvent -FilterHashtable @{
                LogName   = 'Microsoft-Windows-NetworkProfile/Operational'
                Id        = 10000, 10001
                StartTime = $since
            } -MaxEvents 500 -ErrorAction SilentlyContinue

            if ($profileEvents) {
                $tunnelEvents = @($profileEvents | Where-Object { Test-EventMatchesTunnel -WinEvent $_ -Descriptions $tunnelDescs })

                $flapCount = @($tunnelEvents | Where-Object { $_.Id -eq 10001 }).Count

                $lastUp = $tunnelEvents | Where-Object { $_.Id -eq 10000 } |
                          Sort-Object TimeCreated -Descending | Select-Object -First 1
                if ($lastUp) {
                    $lastConnectTime = $lastUp.TimeCreated.ToString('s')
                    if ($connected) {
                        $sessionMinutes = [int]((Get-Date) - $lastUp.TimeCreated).TotalMinutes
                    }
                }
            }
            else {
                $flapCount = 0
            }
        }
        catch {
            Write-Log "NetworkProfile log unavailable: $($_.Exception.Message)" -Level "WARN"
        }
        Write-Log "Flaps (24h): $flapCount | Last connect: $lastConnectTime | Session minutes: $sessionMinutes"

        # -- 7. Connect failures -------------------------------------------------
        # Only the built-in RAS stack reports failures in a standard location.
        # Third-party clients require a vendor module; 0 here is a floor, not a truth.
        try {
            $rasFailures = Get-WinEvent -FilterHashtable @{
                LogName      = 'Application'
                ProviderName = 'RasClient'
                Id           = 20227
                StartTime    = $since
            } -MaxEvents 200 -ErrorAction SilentlyContinue

            $failCount = @($rasFailures).Count
        }
        catch {
            $failCount = 0
        }
        Write-Log "Connect failures (24h): $failCount"

        # -- 8. Health score -----------------------------------------------------
        $healthScore = 100
        $deductions  = @()

        if (-not $connected) {
            $healthScore -= 40
            $deductions += @{ Points = 40; Reason = 'TunnelDown' }
        }
        else {
            if ($tunnelMtu -ge 1500) {
                $healthScore -= 20
                $deductions += @{ Points = 20; Reason = 'MtuNotReducedForTunnel' }
            }
            elseif ($tunnelMtu -gt 0 -and $tunnelMtu -lt 1280) {
                $healthScore -= 25
                $deductions += @{ Points = 25; Reason = 'MtuBelowMinimum' }
            }

            if (-not $dnsConfigured) {
                $healthScore -= 15
                $deductions += @{ Points = 15; Reason = 'NoDnsOnTunnel' }
            }

            if ($discardPpm -gt 1000) {
                $healthScore -= 15
                $deductions += @{ Points = 15; Reason = 'HighPacketDiscardRate' }
            }
        }

        if ($flapCount -ge 10) {
            $healthScore -= 25
            $deductions += @{ Points = 25; Reason = 'FrequentReconnects' }
        }
        elseif ($flapCount -ge 4) {
            $healthScore -= 15
            $deductions += @{ Points = 15; Reason = 'IntermittentReconnects' }
        }

        if ($failCount -ge 5) {
            $healthScore -= 20
            $deductions += @{ Points = 20; Reason = 'RepeatedConnectFailures' }
        }

        if ($clientCount -gt 1) {
            $healthScore -= 10
            $deductions += @{ Points = 10; Reason = 'MultipleVpnClients' }
        }

        if ($healthScore -lt 0) { $healthScore = 0 }

        if ($deductions.Count -eq 0) {
            $healthReason = 'Healthy'
        }
        else {
            $healthReason = ($deductions | Sort-Object { $_.Points } -Descending | Select-Object -First 1).Reason
        }

        Write-Host "$HEAD Health score: $healthScore ($healthReason)"
        Write-Log "Health score: $healthScore | Reason: $healthReason"
    }

    # -- 9. Cache for sensors ---------------------------------------------------
    if (-not (Test-Path $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }

    Set-ItemProperty -Path $RegPath -Name "HealthScore"            -Value ([string]$healthScore)    -Type String
    Set-ItemProperty -Path $RegPath -Name "HealthReason"           -Value $healthReason             -Type String
    Set-ItemProperty -Path $RegPath -Name "Connected"              -Value ([int]$connected)         -Type DWord
    Set-ItemProperty -Path $RegPath -Name "TunnelMode"             -Value $tunnelMode               -Type String
    Set-ItemProperty -Path $RegPath -Name "AdapterName"            -Value $adapterName              -Type String
    Set-ItemProperty -Path $RegPath -Name "TunnelMtu"              -Value ([string]$tunnelMtu)      -Type String
    Set-ItemProperty -Path $RegPath -Name "LastConnectTime"        -Value $lastConnectTime          -Type String
    Set-ItemProperty -Path $RegPath -Name "SessionDurationMinutes" -Value ([string]$sessionMinutes) -Type String
    Set-ItemProperty -Path $RegPath -Name "FlapCount24h"           -Value ([string]$flapCount)      -Type String
    Set-ItemProperty -Path $RegPath -Name "ConnectFailureCount24h" -Value ([string]$failCount)      -Type String
    Set-ItemProperty -Path $RegPath -Name "DnsConfigured"          -Value ([int]$dnsConfigured)     -Type DWord
    Set-ItemProperty -Path $RegPath -Name "DiscardRatePpm"         -Value ([string]$discardPpm)     -Type String
    Set-ItemProperty -Path $RegPath -Name "ClientCount"            -Value ([string]$clientCount)    -Type String
    Set-ItemProperty -Path $RegPath -Name "LastRun"                -Value (Get-Date -Format "o")    -Type String

    Write-Host "$HEAD VPN state cached to $RegPath"
    Write-Log "Collection complete."
    exit 0
}
catch {
    Write-Error "$HEAD ERROR: $($_.Exception.Message)"
    Write-Log "ERROR: $($_.Exception.Message)" -Level "ERROR"

    try {
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
        Set-ItemProperty -Path $RegPath -Name "HealthReason" -Value "CollectionError" -Type String
        Set-ItemProperty -Path $RegPath -Name "LastRun"      -Value (Get-Date -Format "o") -Type String
    }
    catch { }

    exit 1
}
