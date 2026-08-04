#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : vpn_client_count
    Data Type    : Integer
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-04
    Timeout      : < 5 seconds

    Number of VPN client tunnel adapters installed on the device, connected or not.
    0 means no VPN client is present. -1 means the adapter list could not be read.

    Counts adapters structurally -- non-hardware interfaces that are not known
    virtual infrastructure -- so it finds clients this script has never heard of.

    More than one is the signal worth acting on. Stacked clients left behind by a
    migration fight over routes, DNS, and the default gateway, producing
    intermittent failures that reproduce for nobody.
#>

try {
    $excluded = '(?i)(vEthernet|Hyper-V|WSL|Docker|VMware|VirtualBox|Bluetooth|Loopback|Npcap|Wi-Fi Direct|Kernel Debug|Teredo|ISATAP|6to4|VirtualPCNet|TeamViewer|Parsec)'

    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue

    if ($null -eq $adapters) {
        Write-Output -1
        return
    }

    $count = 0

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

        $count++
    }

    Write-Output $count
    return
}
catch {
    Write-Output -1
    return
}
