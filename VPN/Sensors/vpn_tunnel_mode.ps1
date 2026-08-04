#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_tunnel_mode
    Data Type    : String
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-03
    Timeout      : < 5 seconds

    Returns Full, Split, or None.

    Determined by default route ownership, which is vendor-agnostic: if the only
    0.0.0.0/0 route belongs to the tunnel interface, all traffic is tunnelled (Full).
    If any other interface also holds a default route, traffic can bypass the tunnel
    (Split).
#>

try {
    $excluded = '(?i)(vEthernet|Hyper-V|WSL|Docker|VMware|VirtualBox|Bluetooth|Loopback|Npcap|Wi-Fi Direct|Kernel Debug|Teredo|ISATAP|6to4|VirtualPCNet|TeamViewer|Parsec)'

    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }

    if ($null -eq $adapters) {
        Write-Output ""
        return
    }

    $tunnelIndex = $null

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
            $tunnelIndex = $a.ifIndex
            break
        }
    }

    if ($null -eq $tunnelIndex) {
        Write-Output "None"
        return
    }

    $defRoutes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
    $viaTunnel = @($defRoutes | Where-Object { $_.ifIndex -eq $tunnelIndex })
    $viaOther  = @($defRoutes | Where-Object { $_.ifIndex -ne $tunnelIndex })

    if ($viaTunnel.Count -gt 0 -and $viaOther.Count -eq 0) {
        Write-Output "Full"
        return
    }

    Write-Output "Split"
    return
}
catch {
    Write-Output ""
    return
}
