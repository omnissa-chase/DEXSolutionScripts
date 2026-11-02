<#
.SYNOPSIS
    New-WireGuardLabPair -- writes a matched pair of WireGuard tunnel configs so two lab
    VMs on the same subnet can bring up a real VPN tunnel between themselves, with no
    external server, for the VPN break tests.

.DESCRIPTION
    Generates two key pairs with wg.exe (installed by WireGuard for Windows), then writes
    one .conf per side under -OutputPath:

        <LocalName>.conf   -- import on THIS VM      (tunnel address 10.99.0.1/24)
        <RemoteName>.conf  -- copy to the other VM   (tunnel address 10.99.0.2/24)

    Each side lists the other as its single peer with PersistentKeepalive so the
    handshake happens as soon as both tunnels are active. AllowedIPs is the tunnel
    subnet only (split tunnel) by default. -FullTunnel writes AllowedIPs 0.0.0.0/0 on
    the local side instead, which is how Invoke-VpnStateCollection.ps1 classifies
    TunnelMode Full -- but the peer VM does not forward traffic, so a full tunnel cuts
    this VM off from the internet and from UEM while it is active. Use it only for a
    short, deliberate check and never during a UEM run.

    DNS is set to the peer's tunnel address so the collector's DnsConfigured check has
    something to find. MTU is left at WireGuard's default 1420, which is above the
    1400 that Invoke-AutoRemediateGenericVPN.ps1 enforces, so that script's MTU step
    has a genuine condition to remediate.

    With both tunnels active:
        wg show                       handshake and transfer counters on each side
        ping 10.99.0.2                from this VM (10.99.0.1 from the other)

    Activate/deactivate from the WireGuard window, or as a service:
        & "$env:ProgramFiles\WireGuard\wireguard.exe" /installtunnelservice "<path>\<name>.conf"
        & "$env:ProgramFiles\WireGuard\wireguard.exe" /uninstalltunnelservice <name>
    The service is WireGuardTunnel$<name>; the adapter is named after the tunnel.

    Requires WireGuard for Windows on this VM (winget install WireGuard.WireGuard) for
    wg.exe. Run elevated if you want the inbound UDP firewall rule created; otherwise
    the rule command is printed for you to run.

.PARAMETER LocalName
    Tunnel name on this VM. Also the local .conf file name and adapter name.
    Default: the computer name.

.PARAMETER RemoteName
    Tunnel name on the other VM. Default: CHASEWIN11_2.

.PARAMETER LocalEndpoint
    This VM's LAN IPv4 address. Default: the first non-loopback IPv4 on an Up adapter.

.PARAMETER RemoteEndpoint
    The other VM's LAN IPv4 address. Default: resolved from -RemoteName.

.PARAMETER ListenPort
    UDP port both sides listen on. Default 51820.

.PARAMETER OutputPath
    Folder for the two .conf files. Default C:\Temp\WireGuardLab. Private keys are in
    these files; keep the folder out of the repo.

.PARAMETER FullTunnel
    Write AllowedIPs 0.0.0.0/0 on the local side. See DESCRIPTION for the warning.

.NOTES
    Script Name  : New-WireGuardLabPair.ps1
    Version      : 1.0.0
    Context      : Lab only. Not a deployable script.
    Author       : Omnissa DEX team
    Last Modified: 2026-11-02
#>
[CmdletBinding()]
param(
    [string]$LocalName = $env:COMPUTERNAME,
    [string]$RemoteName = 'CHASEWIN11_2',
    [string]$LocalEndpoint,
    [string]$RemoteEndpoint,
    [int]$ListenPort = 51820,
    [string]$OutputPath = 'C:\Temp\WireGuardLab',
    [switch]$FullTunnel
)

$ErrorActionPreference = 'Stop'

$wg = Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
if (-not (Test-Path -LiteralPath $wg)) {
    throw "wg.exe not found at '$wg'. Install WireGuard first: winget install WireGuard.WireGuard"
}

if (-not $LocalEndpoint) {
    $LocalEndpoint = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.PrefixOrigin -ne 'WellKnown' } |
        Sort-Object InterfaceIndex | Select-Object -First 1 -ExpandProperty IPAddress
    if (-not $LocalEndpoint) { throw 'Could not determine this VM''s IPv4 address; pass -LocalEndpoint.' }
}
if (-not $RemoteEndpoint) {
    $RemoteEndpoint = Resolve-DnsName -Name $RemoteName -Type A -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress } | Select-Object -First 1 -ExpandProperty IPAddress
    if (-not $RemoteEndpoint) { throw "Could not resolve '$RemoteName'; pass -RemoteEndpoint." }
}

function New-WgKeyPair {
    $private = (& $wg genkey).Trim()
    # Windows PowerShell's pipeline to a native exe appends CR LF, which wg.exe rejects
    # ("Trailing characters found after key"), so feed the key through a file instead.
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, $private + "`n")
        $public = (& cmd.exe /c "`"$wg`" pubkey < `"$tmp`"").Trim()
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    if (-not $public) { throw 'wg pubkey returned nothing.' }
    [pscustomobject]@{ Private = $private; Public = $public }
}

$localKeys  = New-WgKeyPair
$remoteKeys = New-WgKeyPair
$psk        = (& $wg genpsk).Trim()

$localAllowed = if ($FullTunnel) { '0.0.0.0/0' } else { '10.99.0.0/24' }

$localConf = @"
[Interface]
PrivateKey = $($localKeys.Private)
Address = 10.99.0.1/24
ListenPort = $ListenPort
DNS = 10.99.0.2

[Peer]
# $RemoteName
PublicKey = $($remoteKeys.Public)
PresharedKey = $psk
AllowedIPs = $localAllowed
Endpoint = ${RemoteEndpoint}:$ListenPort
PersistentKeepalive = 25
"@

$remoteConf = @"
[Interface]
PrivateKey = $($remoteKeys.Private)
Address = 10.99.0.2/24
ListenPort = $ListenPort
DNS = 10.99.0.1

[Peer]
# $LocalName
PublicKey = $($localKeys.Public)
PresharedKey = $psk
AllowedIPs = 10.99.0.0/24
Endpoint = ${LocalEndpoint}:$ListenPort
PersistentKeepalive = 25
"@

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$localFile  = Join-Path $OutputPath "$LocalName.conf"
$remoteFile = Join-Path $OutputPath "$RemoteName.conf"
$utf8NoBom  = New-Object System.Text.UTF8Encoding $false
[IO.File]::WriteAllText($localFile,  $localConf,  $utf8NoBom)
[IO.File]::WriteAllText($remoteFile, $remoteConf, $utf8NoBom)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
$ruleName = "WireGuard lab $LocalName UDP $ListenPort"
if ($isAdmin) {
    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol UDP -LocalPort $ListenPort -Action Allow -Profile Any | Out-Null
    }
    Write-Host "Firewall rule '$ruleName' present."
} else {
    Write-Host 'Not elevated; create the inbound rule from an elevated prompt:'
    Write-Host "  New-NetFirewallRule -DisplayName '$ruleName' -Direction Inbound -Protocol UDP -LocalPort $ListenPort -Action Allow -Profile Any"
}

Write-Host ''
Write-Host "Local  ($LocalName, $LocalEndpoint): $localFile"
Write-Host "Remote ($RemoteName, $RemoteEndpoint): $remoteFile  <- copy this file to $RemoteName"
Write-Host ''
Write-Host 'On each VM: WireGuard window > Import tunnel(s) from file > Activate. Or as a service:'
Write-Host "  & `"`$env:ProgramFiles\WireGuard\wireguard.exe`" /installtunnelservice `"<path>\<name>.conf`""
Write-Host "The other VM also needs an inbound UDP $ListenPort rule. Then: wg show ; ping 10.99.0.2"
if ($FullTunnel) {
    Write-Warning 'Local side is a FULL tunnel: this VM loses internet and UEM reachability while it is active.'
}
