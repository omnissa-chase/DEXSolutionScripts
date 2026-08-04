#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_dns_configured
    Data Type    : Boolean
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-04
    Timeout      : < 5 seconds

    True when the active tunnel adapter has at least one IPv4 DNS server assigned.

    Read live rather than from cache, matching the other tunnel-attribute sensors --
    a stale DNS state on a tunnel that has since changed is worse than no sample.

    A tunnel with no DNS is the classic "VPN says connected but nothing internal
    resolves" failure. Name resolution falls back to the physical adapter's public
    resolvers, so internal hostnames fail while the tunnel itself looks perfectly
    healthy.

    No value is emitted when there is no active tunnel: false would read as a real
    misconfiguration on a device that simply is not connected.
#>

try {
    $excluded = '(?i)(vEthernet|Hyper-V|WSL|Docker|VMware|VirtualBox|Bluetooth|Loopback|Npcap|Wi-Fi Direct|Kernel Debug|Teredo|ISATAP|6to4|VirtualPCNet|TeamViewer|Parsec)'

    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }

    if ($null -eq $adapters) {
        # No safe boolean fallback - return without a value.
        return
    }

    foreach ($a in $adapters) {
        $isHardware = $true
        if ($a.PSObject.Properties['HardwareInterface']) {
            $isHardware = [bool]$a.HardwareInterface
        }
        elseif ($a.PSObject.Properties['ConnectorPresent']) {
            $isHardware = [bool]$a.ConnectorPresent
        }

        if ($isHardware) { continue }
        if ($a.Name -match $excluded -or $a.InterfaceDescription -match $excluded) { continue }

        $ip = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' }

        if ($ip) {
            $dns = Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue

            if ($null -eq $dns) {
                return
            }

            Write-Output (@($dns.ServerAddresses).Count -gt 0)
            return
        }
    }

    # No active tunnel - no meaningful boolean to report.
    return
}
catch {
    return
}
