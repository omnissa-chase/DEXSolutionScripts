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
    Plus, for the sensors' self-refreshing gate (1.1.0): LastRun and LastChecked
    (both 'o' format), StateFingerprint, CollectorPath and CollectorHash (SHA-256).

    A HealthScore of -1 means no VPN client is present on the device. This is
    deliberately distinct from a low score, which means a VPN client is present and
    unhealthy. Collapsing the two would make fleet reporting meaningless.

    SELF-REFRESHING CACHE (1.1.0)
    Every sensor carries a verbatim copy of Get-VpnStateFingerprint. When LastChecked
    is older than 15 minutes a sensor recomputes the fingerprint; if it still matches
    StateFingerprint it only stamps LastChecked, otherwise it reruns this script from
    the copy persisted at CollectorPath, after checking the file's SHA-256 against
    CollectorHash. The persisted folder is locked to SYSTEM/Administrators Full and
    Users ReadAndExecute, owner Administrators, inheritance disabled.

    VPN_COLLECTOR_QUIET
    Set to 1 by the sensors when they launch this script. The log file is written as
    usual but nothing goes to the output or error streams, so the sensor's single
    line of output stays clean. Unset (Hub, console) behaviour is unchanged.

.NOTES
    Script Name  : Invoke-VpnStateCollection.ps1
    Version      : 1.1.1
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-03 (1.1.1: hashes the persisted copy with .NET SHA256 and logs the host's PowerShell version and PSModulePath; under Hub the sensor-spawned child could not resolve Get-FileHash, so the quiet rerun left CollectorHash empty.)
                   2026-11-02 (1.1.0: self-refreshing cache. Writes StateFingerprint, LastChecked, CollectorPath and CollectorHash; persists its own text to C:\ProgramData\AirWatch\Extensions\VPN with a locked ACL so sensors can rerun it when the adapter state changes; honours VPN_COLLECTOR_QUIET=1. Detection and scoring unchanged. 1.0.1: step 5 called Get-NetAdapterStatistics with -InterfaceIndex, a parameter it does not have, so the whole collection failed with CollectionError on any device with an active tunnel; now -Name. Found by the lab break test the first time a real tunnel (WireGuard) was present.)
    Timeout      : 30 seconds
    Schedule     : Every 15-30 minutes

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>
# Captured at script scope on purpose: inside the function below, ScriptBlock is only
# the function body. Hub feeds scripts through stdin, so $PSCommandPath is empty and
# this string is the only copy of the full text we can persist for the sensors.
$script:SelfText = $MyInvocation.MyCommand.ScriptBlock.ToString()

function Invoke-VpnStateCollection {
[CmdletBinding()]
param()

$SCRIPT_VERSION = "1.1.0"
$RegPath        = "HKLM:\Software\AirWatch\Extensions\VPN"
$LogPath        = "$env:SystemRoot\Temp\UEM_VpnStateCollection.log"
$PersistDir     = "C:\ProgramData\AirWatch\Extensions\VPN"
$PersistPath    = Join-Path $PersistDir "Invoke-VpnStateCollection.ps1"
$Quiet          = ($env:VPN_COLLECTOR_QUIET -eq '1')

$RunEventId = ([Random]::new()).Next(1000, 9999)
$HEAD       = "`r`n[$RunEventId]"

function Write-Out {
    # Output stream unless a sensor launched us with VPN_COLLECTOR_QUIET=1.
    param([string]$Message)
    if (-not $Quiet) { Write-Output $Message }
}

Write-Out "[$RunEventId] Executing Invoke-VpnStateCollection, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'"

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

# -- State fingerprint ----------------------------------------------------------
# Copied VERBATIM into every vpn_* sensor; change both or neither. Same candidate
# rules as Get-CandidateTunnelAdapter (non-hardware, not excluded, Up or not).
# One entry per candidate: ifIndex|Status|IPv4 NlMtu|IPv4 DNS servers joined by ','.
# Entries sorted and joined by ';'. Empty string when there are no candidates.
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

# -- Persist a copy of this script for the sensors' gate -------------------------
# Own try/catch; never changes the exit code. On any failure CollectorHash is written
# empty so the sensors fall back to the cache instead of running an unverified file.
function Save-CollectorCopy {
    $hash = ''
    Write-Log "Host: PowerShell $($PSVersionTable.PSVersion), $(if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }), quiet=$Quiet, Get-FileHash=$([bool](Get-Command Get-FileHash -ErrorAction SilentlyContinue)), PSModulePath='$env:PSModulePath'"
    try {
        if ([string]::IsNullOrWhiteSpace($script:SelfText)) { throw "Script text unavailable; nothing to persist." }
        if (-not (Test-Path -LiteralPath $PersistDir)) { New-Item -ItemType Directory -Path $PersistDir -Force -ErrorAction Stop | Out-Null }

        # SYSTEM Full, Administrators Full, Users ReadAndExecute; inheritance disabled; owner
        # Administrators so a standard user who pre-created the folder cannot re-grant
        # themselves access (an owner may always rewrite the DACL). FA = FullControl,
        # 0x1200a9 = ReadAndExecute + Synchronize.
        $dirSddl  = 'O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)'
        $fileSddl = 'O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;BU)'
        $sec = New-Object System.Security.AccessControl.DirectorySecurity
        try {
            $sec.SetSecurityDescriptorSddlForm($dirSddl)
            Set-Acl -LiteralPath $PersistDir -AclObject $sec -ErrorAction Stop
        }
        catch {
            Write-Log "Folder ACL with owner failed ($($_.Exception.Message)); applying DACL only." -Level "WARN"
            $sec = New-Object System.Security.AccessControl.DirectorySecurity
            $sec.SetSecurityDescriptorSddlForm(($dirSddl -replace '^O:BA', ''))
            Set-Acl -LiteralPath $PersistDir -AclObject $sec -ErrorAction Stop
        }

        # Byte-exact: UTF-8 without BOM, no trailing newline added.
        [System.IO.File]::WriteAllText($PersistPath, $script:SelfText, (New-Object System.Text.UTF8Encoding $false))
        $fsec = New-Object System.Security.AccessControl.FileSecurity
        try   { $fsec.SetSecurityDescriptorSddlForm($fileSddl); Set-Acl -LiteralPath $PersistPath -AclObject $fsec -ErrorAction Stop }
        catch { $fsec = New-Object System.Security.AccessControl.FileSecurity; $fsec.SetSecurityDescriptorSddlForm(($fileSddl -replace '^O:BA', '')); Set-Acl -LiteralPath $PersistPath -AclObject $fsec -ErrorAction Stop }

        # .NET, not Get-FileHash: that cmdlet did not resolve in the child powershell.exe Hub's sensor host spawned (2026-11-03).
        $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($PersistPath))) -replace '-', ''
        Write-Log "Persisted collector copy to $PersistPath (SHA-256 $hash)."
    }
    catch {
        $hash = ''
        Write-Log "Could not persist the collector copy: $($_.Exception.Message). PSModulePath='$env:PSModulePath'. Sensors will fall back to the cache." -Level "WARN"
    }
    try {
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
        Set-ItemProperty -Path $RegPath -Name "CollectorPath" -Value $PersistPath -Type String
        Set-ItemProperty -Path $RegPath -Name "CollectorHash" -Value $hash        -Type String
    }
    catch { Write-Log "Could not write CollectorPath/CollectorHash: $($_.Exception.Message)" -Level "WARN" }
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
$fingerprint     = ''

Save-CollectorCopy

try {
    # -- 1. Identify tunnel adapters -------------------------------------------
    $candidates  = Get-CandidateTunnelAdapter
    $clientCount = @($candidates).Count
    $fingerprint = Get-VpnStateFingerprint
    Write-Log "Found $clientCount candidate tunnel adapter(s). Fingerprint: '$fingerprint'"

    if ($clientCount -eq 0) {
        Write-Out "$HEAD No VPN client detected on this device."
        Write-Log "No VPN client detected. HealthScore = -1."
    }
    else {
        $tunnel = Get-ActiveTunnelAdapter -Candidates $candidates

        if ($tunnel) {
            $connected   = $true
            $adapterName = $tunnel.InterfaceDescription
            Write-Out "$HEAD Active tunnel: $adapterName (ifIndex $($tunnel.ifIndex))"
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
            # Get-NetAdapterStatistics has no -InterfaceIndex parameter (only -Name and
            # -InterfaceDescription); binding errors are terminating regardless of
            # -ErrorAction, so 1.0.0 crashed here on every device with an active tunnel.
            $stats = Get-NetAdapterStatistics -Name $tunnel.Name -ErrorAction SilentlyContinue
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
            Write-Out "$HEAD VPN client present but no active tunnel."
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

        Write-Out "$HEAD Health score: $healthScore ($healthReason)"
        Write-Log "Health score: $healthScore | Reason: $healthReason"
    }

    # -- 9. Cache for sensors ---------------------------------------------------
    if (-not (Test-Path $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }

    $now = Get-Date -Format "o"
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
    Set-ItemProperty -Path $RegPath -Name "StateFingerprint"       -Value $fingerprint              -Type String
    Set-ItemProperty -Path $RegPath -Name "LastRun"                -Value $now                      -Type String
    Set-ItemProperty -Path $RegPath -Name "LastChecked"            -Value $now                      -Type String

    Write-Out "$HEAD VPN state cached to $RegPath"
    Write-Log "Collection complete."
    exit 0
}
catch {
    if (-not $Quiet) { Write-Error "$HEAD ERROR: $($_.Exception.Message)" }
    Write-Log "ERROR: $($_.Exception.Message)" -Level "ERROR"

    try {
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
        $now = Get-Date -Format "o"
        Set-ItemProperty -Path $RegPath -Name "HealthReason" -Value "CollectionError" -Type String
        Set-ItemProperty -Path $RegPath -Name "LastRun"      -Value $now -Type String
        Set-ItemProperty -Path $RegPath -Name "LastChecked"  -Value $now -Type String
    }
    catch { }

    exit 1
}
}

# -- entry point ---------------------------------------------------------------
# The param block sits inside the function deliberately. The Workspace ONE script
# engine does not recognise a param block at script scope, and $PSCmdlet is $null
# there, which makes every ShouldProcess call throw. Inputs arrive as environment
# variables and are bound to the function's parameters below.

Invoke-VpnStateCollection
Exit 0
