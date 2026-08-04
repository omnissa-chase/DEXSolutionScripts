#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_connected
    Data Type    : Boolean
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-03
    Timeout      : < 5 seconds

    Reads live rather than from cache -- a 30-minute-stale connection state is
    misleading, and adapter enumeration is fast enough to stay well inside budget.

    Vendor-agnostic: a tunnel is an Up adapter with HardwareInterface = $false that
    holds a routable IPv4 address and is not known virtual infrastructure. No vendor
    product names are matched.
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
            Write-Output $true
            return
        }
    }

    Write-Output $false
    return
}
catch {
    return
}
