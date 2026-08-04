#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_adapter_name
    Data Type    : String
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-03
    Timeout      : < 5 seconds

    Interface description of the active tunnel adapter -- effectively "which VPN
    client is actually carrying traffic right now". Detection is vendor-agnostic;
    only the reported name is vendor-specific, which is the point of this sensor.

    Empty string means no active tunnel.
#>

try {
    $excluded = '(?i)(vEthernet|Hyper-V|WSL|Docker|VMware|VirtualBox|Bluetooth|Loopback|Npcap|Wi-Fi Direct|Kernel Debug|Teredo|ISATAP|6to4|VirtualPCNet|TeamViewer|Parsec)'

    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }

    if ($null -eq $adapters) {
        Write-Output ""
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
            Write-Output $a.InterfaceDescription
            return
        }
    }

    Write-Output ""
    return
}
catch {
    Write-Output ""
    return
}
