#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_tunnel_mtu
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-03
    Timeout      : < 5 seconds

    IPv4 MTU of the active tunnel adapter. -1 means no active tunnel.

    A VPN adds encapsulation overhead, so a healthy tunnel MTU is below the 1500-byte
    Ethernet default -- typically 1400 (IPsec), 1420 (WireGuard), or 1350-1400 (SSL).
    A tunnel still reporting 1500 risks an MTU black hole: oversized packets are
    dropped in transit and, where firewalls block the ICMP "Fragmentation Needed"
    response, the sender is never told. The symptom is a connection that pings fine
    but stalls on large transfers. Below 1280 (the IPv6 minimum) is pathological.
#>

try {
    $excluded = '(?i)(vEthernet|Hyper-V|WSL|Docker|VMware|VirtualBox|Bluetooth|Loopback|Npcap|Wi-Fi Direct|Kernel Debug|Teredo|ISATAP|6to4|VirtualPCNet|TeamViewer|Parsec)'

    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }

    if ($null -eq $adapters) {
        Write-Output -1
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
            $ipIf = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Select-Object -First 1

            if ($null -eq $ipIf -or -not $ipIf.NlMtu) {
                Write-Output -1
                return
            }

            Write-Output ([int]$ipIf.NlMtu)
            return
        }
    }

    Write-Output -1
    return
}
catch {
    Write-Output -1
    return
}
