$env:WhatIf = "true"
function Get-NetAdapter {
    param([switch]$Physical)
    @(
        [PSCustomObject]@{ Name='TestVPN'; InterfaceDescription='Contoso Secure Tunnel Adapter'; Status='Up'; ifIndex=9999; HardwareInterface=$false }
        [PSCustomObject]@{ Name='OldVPN'; InterfaceDescription='Fabrikam Legacy VPN Adapter'; Status='Disconnected'; ifIndex=9998; HardwareInterface=$false }
    )
}
function Get-NetIPAddress { param($InterfaceIndex,$AddressFamily) if ($InterfaceIndex -eq 9999) { [PSCustomObject]@{ IPAddress='10.20.30.40' } } }
function Get-NetIPInterface { param($InterfaceIndex,$AddressFamily) [PSCustomObject]@{ NlMtu=1400 } }
function Get-DnsClientServerAddress { param($InterfaceIndex,$AddressFamily) [PSCustomObject]@{ ServerAddresses=@('10.0.0.1') } }
function Get-NetRoute {
    param($InterfaceIndex,$PolicyStore)
    if ($InterfaceIndex -eq 9998) {
        @(
            [PSCustomObject]@{ DestinationPrefix='0.0.0.0/0' }
            [PSCustomObject]@{ DestinationPrefix='10.50.0.0/16' }
            [PSCustomObject]@{ DestinationPrefix='224.0.0.0/4' }
            [PSCustomObject]@{ DestinationPrefix='fe80::/64' }
        )
    }
}
function Remove-NetRoute { param($InterfaceIndex,$DestinationPrefix,$PolicyStore,$Confirm) }
& '.\VPN\Invoke-AutoRemediateGenericVPN.ps1'
Write-Output "EXITCODE=$LASTEXITCODE"
