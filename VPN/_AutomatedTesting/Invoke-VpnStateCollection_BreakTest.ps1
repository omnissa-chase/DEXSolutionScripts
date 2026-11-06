<#
.SYNOPSIS
    Invoke-VpnStateCollection_BreakTest -- deliberately corrupts, poisons or removes the
    registry cache that Invoke-VpnStateCollection.ps1 writes for the VPN sensors, and
    brings the lab WireGuard tunnel down or up, then verifies the collector rewrites
    every documented value correctly for the machine's actual tunnel state.

.DESCRIPTION
    Break -> verify-the-break -> collect -> validate -> restore. Writes a uniform JSON
    result to C:\Temp\FixReport\Invoke-VpnStateCollection\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It deletes and rewrites
    HKLM:\Software\AirWatch\Extensions\VPN, the cache the vpn_* sensors read, and it
    stops and starts every WireGuardTunnel$* service on the host. Run it only on a
    disposable VM or a marked test host. See Assert-DexTestHost in DEXTestFramework.psm1.

    THE SCRIPT UNDER TEST IS A COLLECTOR, NOT A REMEDIATOR
    Invoke-VpnStateCollection.ps1 detects a tunnel structurally (a visible adapter with
    HardwareInterface = $false that is not known virtual infrastructure), mines the
    NetworkProfile and RasClient event logs, computes one health score and caches
    thirteen documented values plus LastRun to the registry. Its promise is therefore
    "every run writes the full, correct row for the device's current state", so a break
    here is anything that leaves the cache wrong or missing before the run, or a change
    of tunnel state the row must follow. Validation compares the row the collector
    wrote, value by value and kind by kind, against the row this harness derives from
    the live adapter, route, MTU, DNS, statistics and event-log state using the
    collector's own documented rules (Get-ExpectedCollectorRow), so the planting breaks
    are valid whether or not a tunnel is up.

    THE LAB TUNNEL
    WireGuard for Windows with a tunnel from VPN\_AutomatedTesting\New-WireGuardLabPair.ps1:
    service WireGuardTunnel$<name>, adapter Name <name>, InterfaceDescription
    'WireGuard Tunnel', address 10.99.0.1/24, DNS 10.99.0.2, MTU 1420, AllowedIPs
    10.99.0.0/24 (split tunnel). Stopping the service removes the Wintun adapter;
    starting it brings the adapter back Up within a few seconds. That is the lever
    the two reported breaks use. Any host without a WireGuardTunnel$* service still
    runs NoVpnClientReported exactly as a no-client host; TunnelConnectedReported
    aborts there as BreakFailed.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken.
    A break that silently no-ops would let the collector "pass" against a healthy
    machine -- a false green, and the failure mode that makes a harness like this
    worthless. A break that cannot be verified aborts the run as BreakFailed.

    EXPECTED OUTCOMES
      ExpectFixed        -- the collector must overwrite the planted state
      ExpectReportedOnly -- the collector must DETECT and report the condition

    NoVpnClientReported     ExpectReportedOnly. Stops every running WireGuardTunnel$*
                            service (Capture recorded each one's state) and removes the
                            cache key. Verify waits up to 30 s for the collector's own
                            structural adapter test to find zero candidates and checks
                            no fresh row exists. Validate requires the exact documented
                            no-client row: HealthScore '-1' (never 0 -- the header
                            insists the two are distinct), HealthReason 'NoVpnClient',
                            Connected 0, ClientCount '0', every other value at its
                            -1/''/None default, a LastRun newer than this run started,
                            and the collector's own "No VPN client detected" line in its
                            output. Restore starts the services again and waits for the
                            adapter to be Up.
    TunnelConnectedReported ExpectReportedOnly. Starts any stopped WireGuardTunnel$*
                            service and removes the cache key. Verify waits up to 45 s
                            for exactly one candidate adapter that is Up with a routable
                            IPv4 address. Validate requires the live-derived connected
                            row plus these lab invariants asserted outright: Connected
                            DWORD 1, ClientCount '1', AdapterName 'WireGuard Tunnel',
                            TunnelMode 'Split', TunnelMtu '1420', DnsConfigured DWORD 1,
                            DiscardRatePpm '0', LastRun refreshed, and
                            "Active tunnel: WireGuard Tunnel" in the collector output.

                            Expected HealthScore for the lab tunnel, derived from the
                            collector's section 8 scoring with the probed inputs:
                              start 100
                              connected               -> no TunnelDown        (-40)
                              NlMtu 1420: not >= 1500 -> no MtuNotReduced     (-20)
                                          not < 1280  -> no MtuBelowMinimum   (-25)
                              DNS 10.99.0.2 on tunnel -> no NoDnsOnTunnel     (-15)
                              0 discards / N packets  -> 0 ppm, not > 1000    (-15)
                              FlapCount24h 0 (< 4)    -> no reconnect penalty (-15/-25)
                              ConnectFailureCount 0   -> no RepeatedFailures  (-20)
                              ClientCount 1           -> no MultipleVpnClients(-10)
                              = 100, no deductions    -> HealthReason 'Healthy'
                            FlapCount24h is 0 because the collector matches
                            NetworkProfile 10000/10001 event strings against the
                            adapter InterfaceDescription ('WireGuard Tunnel') while the
                            events carry the profile name (the adapter Name), so no
                            event ever matches; LastConnectTime stays '' and
                            SessionDurationMinutes '-1' for the same reason. DiscardRatePpm
                            is '0' whether or not any packets have crossed the tunnel:
                            zero discards over N > 0 packets rounds to 0, and the
                            collector's N = 0 branch also writes 0.
    StaleCacheFromPriorClient
                            ExpectFixed. Plants a believable row left behind by another
                            VPN client: a healthy connected tunnel on a fictional
                            adapter, an unhealthy TunnelDown score of 0, or the two-value
                            residue the collector's own catch path leaves
                            (HealthReason 'CollectionError'). Every plant carries a
                            two-day-old LastRun. Validate: every documented value and
                            kind matches the live-derived row and LastRun was refreshed.
    CacheValueKindsWrong    ExpectFixed. Keeps plausible VALUES but stores them under the
                            wrong registry KIND (HealthScore as DWORD, Connected as
                            REG_SZ, HealthReason as REG_MULTI_SZ ...). The sensors cast
                            on read, so a wrong kind is a silent sensor failure. Validate
                            requires Set-ItemProperty -Type to have replaced every kind.

    NoVpnClientReported and TunnelConnectedReported pull the tunnel in opposite
    directions and cannot share a run; when the seeded draw selects both, the one
    drawn first is kept. Either may pair with the planting breaks: the plants write a
    stale LastRun, so the reported breaks' "no fresh row" check still holds, and
    Validate derives the expected row from whatever tunnel state the run left.
    Capture nests and Restore undoes newest-first, so a planted cache or a stopped
    tunnel is always returned to its captured state.

    NOT COVERED
    TunnelDownReported (client present, tunnel not Up: HealthReason 'TunnelDown',
    score 60) has no natural WireGuard state. The Wintun adapter exists only while the
    tunnel service runs, and while it runs it reports ifOperStatus Up and
    MediaConnectionState Connected regardless of handshake (probed with the peer silent:
    still Up). Forcing it with Disable-NetAdapter or Remove-NetIPAddress on the WireGuard
    adapter is untested against the tunnel service's interface watcher and is not done
    here. OpenVPN's TAP-Windows adapter, which persists media-disconnected when no
    session is up, is the clean lever for that branch. Also uncovered: TunnelMode 'Full'
    (New-WireGuardLabPair -FullTunnel cuts the VM off from UEM), the MTU and DNS
    deductions, flap and connect-failure counting (RasClient 20227 is plantable with
    Write-EventLog on this host but events cannot be removed), and MultipleVpnClients.

    RESTORE
    Capture snapshots the whole cache key (every value with its kind, or the fact that
    the key was absent) and, for the reported breaks, the Status of every
    WireGuardTunnel$* service. Restore puts the key back exactly and returns each
    service to its captured state, waiting for the adapter to follow. The collector's
    own log at %SystemRoot%\Temp\UEM_VpnStateCollection.log gains a few lines per run
    and is left alone as evidence.

    REBOOTS
    Registry and service changes take effect immediately; nothing here is flagged
    RequiresReboot. Breaks flagged RequiresReboot would suspend the run, register an
    AtStartup resume task, and reboot. Opt in with -IncludeRebootBreaks; they are
    excluded by default.

.PARAMETER RemediationTest
    After breaking, run Invoke-VpnStateCollection.ps1 and validate the cache it wrote.
    Without this the script breaks and reports only.

.PARAMETER Environment
    Physical (default) restores the machine when the run ends.
    Snapshot skips restore on the assumption the host reverts a checkpoint.

.PARAMETER Seed
    Replays an earlier run's random break selection exactly. Omit for a new random
    seed, which is always recorded in the result.

.PARAMETER BreakName
    Force specific breaks instead of a random selection.

.PARAMETER BreakCount
    How many components to break when selecting randomly. Default 2.

.PARAMETER IncludeRebootBreaks
    Allow breaks that require a reboot to take effect. Default off.

.PARAMETER Restore
    Undo an in-flight run's breaks and exit. No collection, no validation.

.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot.

.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Invoke-VpnStateCollection_BreakTest.ps1
    Version      : 1.1.1
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
    Reporting    : C:\Temp\FixReport\Invoke-VpnStateCollection\

    1.1.0  -BreakName with a single name no longer collapses the selection to a bare
           hashtable (the one-element array was unrolled, the exclusivity branch fired
           on the hashtable's key count and removed the only break). The collector's
           stderr is captured as text instead of becoming a terminating
           NativeCommandError under $ErrorActionPreference = 'Stop', so a failing
           collector is a Validate failure with its output in the JSON, never a
           HarnessError. Tunnel-aware: NoVpnClientReported stops the lab WireGuard
           tunnel, TunnelConnectedReported added, expected rows derived live.
    1.0.0  Initial: no-client host only.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [switch]$RemediationTest,
    [ValidateSet('Snapshot', 'Physical')][string]$Environment = 'Physical',
    [int]$Seed = 0,
    [string[]]$BreakName,
    [int]$BreakCount = 2,
    [switch]$IncludeRebootBreaks,
    [switch]$Restore,
    [switch]$Resume,
    [switch]$Force,
    [string[]]$ProductionDomainDenyList = @()
)

$ErrorActionPreference = 'Stop'

$ScriptUnderTest   = 'Invoke-VpnStateCollection'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-VpnStateCollection.ps1'
$VpnRegPath        = 'HKLM:\Software\AirWatch\Extensions\VPN'
$SelfPath          = $MyInvocation.MyCommand.Path
$HarnessStartedAt  = Get-Date

$modulePath = Join-Path $PSScriptRoot '..\..\AutomatedTesting\DEXTestFramework.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "DEXTestFramework.psm1 not found at $modulePath"
}
Import-Module $modulePath -Force

if (-not (Test-Path -LiteralPath $RemediationScript)) {
    throw "Script under test not found at $RemediationScript"
}

# -- Fixture ------------------------------------------------------------------
# The component under test is the collector's registry cache plus the lab tunnel;
# nothing is built. Both are snapshotted per break by Capture, so the fixture has
# nothing to prepare and nothing to tear down. The row the collector writes is kept
# as evidence.
function Initialize-Fixture {
}

function Remove-Fixture {
    # Intentionally empty: Restore puts the captured cache row and tunnel state back;
    # the collector's log in %SystemRoot%\Temp is left in place for the operator.
}

# -- Expected state -------------------------------------------------------------
# The row the collector header documents for a device with no VPN client, with the
# registry kind each value is written as. HealthScore -1 is deliberately distinct from
# 0: -1 means no client, 0 means a client that is completely unhealthy. The kinds are
# the same for every state; Get-ExpectedCollectorRow starts from this row and fills in
# the client-present values from live state.
$ExpectedNoClientState = [ordered]@{
    HealthScore            = @{ Kind = 'String'; Value = '-1' }
    HealthReason           = @{ Kind = 'String'; Value = 'NoVpnClient' }
    Connected              = @{ Kind = 'DWord';  Value = 0 }
    TunnelMode             = @{ Kind = 'String'; Value = 'None' }
    AdapterName            = @{ Kind = 'String'; Value = '' }
    TunnelMtu              = @{ Kind = 'String'; Value = '-1' }
    LastConnectTime        = @{ Kind = 'String'; Value = '' }
    SessionDurationMinutes = @{ Kind = 'String'; Value = '-1' }
    FlapCount24h           = @{ Kind = 'String'; Value = '-1' }
    ConnectFailureCount24h = @{ Kind = 'String'; Value = '-1' }
    DnsConfigured          = @{ Kind = 'DWord';  Value = 0 }
    DiscardRatePpm         = @{ Kind = 'String'; Value = '-1' }
    ClientCount            = @{ Kind = 'String'; Value = '0' }
}

# Lab invariants for the WireGuard tunnel from New-WireGuardLabPair.ps1, asserted
# outright by TunnelConnectedReported on top of the live-derived row so a derivation
# bug that mirrors a collector bug cannot pass both. See the header for the score.
$LabConnectedAssertions = [ordered]@{
    Connected      = 1
    ClientCount    = '1'
    AdapterName    = 'WireGuard Tunnel'
    TunnelMode     = 'Split'
    TunnelMtu      = '1420'
    DnsConfigured  = 1
    DiscardRatePpm = '0'
}

# Same exclusion list as the collector. Kept verbatim so the structural test here
# replicates the collector's rather than approximating it.
$ExcludedAdapterPattern = '(?i)(vEthernet|Hyper-V|WSL|Docker|VMware|VirtualBox|Bluetooth|Loopback|Npcap|Wi-Fi Direct|Kernel Debug|Teredo|ISATAP|6to4|VirtualPCNet|TeamViewer|Parsec)'

$WireGuardServicePattern = 'WireGuardTunnel$*'

# -- Helpers: adapters and tunnel services --------------------------------------

function Get-VpnCandidateAdapterObject {
    <#
        Mirrors Get-CandidateTunnelAdapter in the collector: visible adapters that are
        not hardware and do not match the exclusion pattern. Always returns an array.
    #>
    $list = New-Object System.Collections.Generic.List[object]
    $all = Get-NetAdapter -ErrorAction SilentlyContinue
    foreach ($a in @($all)) {
        if ($null -eq $a) { continue }
        $isHardware = $true
        if ($a.PSObject.Properties['HardwareInterface']) {
            $isHardware = [bool]$a.HardwareInterface
        }
        elseif ($a.PSObject.Properties['ConnectorPresent']) {
            $isHardware = [bool]$a.ConnectorPresent
        }
        if ($isHardware) { continue }
        if ($a.Name -match $ExcludedAdapterPattern) { continue }
        if ($a.InterfaceDescription -match $ExcludedAdapterPattern) { continue }
        $list.Add($a)
    }
    # Plain array on purpose: every caller wraps this in @(...). The ,[object[]] form
    # nested the array, so @(...).Count was 1 whether there were 0 or 1 candidates and
    # the NoVpnClientReported break could never verify (runs f15c2e55a2b6, 35ce4a7f6182).
    return $list.ToArray()
}

function Get-VpnCandidateTunnelAdapter {
    # Printable form of the candidates for Verify diagnostics and the result JSON.
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($a in @(Get-VpnCandidateAdapterObject)) {
        $names.Add("$($a.Name) [$($a.InterfaceDescription)] $($a.Status)")
    }
    return ,[string[]]$names.ToArray()
}

function Get-VpnActiveTunnelAdapter {
    # Mirrors Get-ActiveTunnelAdapter in the collector.
    param($Candidates)
    foreach ($a in @($Candidates)) {
        if ($null -eq $a) { continue }
        if ($a.Status -ne 'Up') { continue }
        $ip = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' }
        if ($ip) { return $a }
    }
    return $null
}

function Wait-VpnCandidateState {
    <#
        Polls the collector's structural test until the candidate count matches and,
        with -RequireUp, one candidate is Up with a routable IPv4 address. Wintun
        adapters appear and disappear a few seconds after their service starts or
        stops. Diagnostics go to the host stream only; callers are [bool]-cast.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$ExpectedCount,
        [switch]$RequireUp,
        [int]$TimeoutSec = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $candidates = @(Get-VpnCandidateAdapterObject)
        $ok = ($candidates.Count -eq $ExpectedCount)
        if ($ok -and $RequireUp) {
            $ok = ($null -ne (Get-VpnActiveTunnelAdapter -Candidates $candidates))
        }
        if ($ok) { return $true }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    $names = Get-VpnCandidateTunnelAdapter
    Write-Host "           after ${TimeoutSec}s: $($names.Count) candidate adapter(s) [$($names -join ', ')], wanted $ExpectedCount$(if ($RequireUp) { ' Up with IPv4' })"
    return $false
}

function Get-WireGuardTunnelService {
    return ,[object[]]@(Get-Service -Name $WireGuardServicePattern -ErrorAction SilentlyContinue | Where-Object { $_ })
}

function Get-WireGuardTunnelState {
    # Capture shape: one @{ Name; Status } per WireGuardTunnel$* service.
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($svc in @(Get-WireGuardTunnelService)) {
        $list.Add(@{ Name = $svc.Name; Status = [string]$svc.Status })
    }
    return ,[object[]]$list.ToArray()
}

function Stop-WireGuardTunnel {
    foreach ($svc in @(Get-WireGuardTunnelService)) {
        if ($svc.Status -ne 'Stopped') {
            Stop-Service -Name $svc.Name -Force -ErrorAction Stop
        }
    }
}

function Start-WireGuardTunnel {
    foreach ($svc in @(Get-WireGuardTunnelService)) {
        if ($svc.Status -ne 'Running') {
            Start-Service -Name $svc.Name -ErrorAction Stop
        }
    }
}

function Restore-WireGuardTunnelState {
    <#
        Returns every captured WireGuardTunnel$* service to its captured Status and
        waits for the adapter to follow. $Tunnels is an array of hashtables in-process
        or of PSCustomObjects after a JSON round-trip; a single tunnel comes back from
        JSON as a bare object and an empty list as $null, hence the normalisation.
    #>
    param($Tunnels)

    $entries = @($Tunnels | Where-Object { $null -ne $_ })
    if ($entries.Count -eq 0) { return }

    $wantRunning = $false
    foreach ($t in $entries) {
        $svc = Get-Service -Name ([string]$t.Name) -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        if ([string]$t.Status -eq 'Running') {
            $wantRunning = $true
            if ($svc.Status -ne 'Running') { Start-Service -Name $svc.Name -ErrorAction Stop }
        } else {
            if ($svc.Status -ne 'Stopped') { Stop-Service -Name $svc.Name -Force -ErrorAction Stop }
        }
    }

    if ($wantRunning) {
        if (-not (Wait-VpnCandidateState -ExpectedCount 1 -RequireUp -TimeoutSec 45)) {
            throw 'WireGuard tunnel service restarted but its adapter did not come Up within 45 s'
        }
    } else {
        if (-not (Wait-VpnCandidateState -ExpectedCount 0 -TimeoutSec 30)) {
            throw 'WireGuard tunnel service stopped but its adapter is still present after 30 s'
        }
    }
}

# -- Helpers: registry cache ------------------------------------------------------

function Get-VpnCacheKey {
    if (-not (Test-Path -LiteralPath $VpnRegPath)) { return $null }
    Get-Item -LiteralPath $VpnRegPath -ErrorAction SilentlyContinue
}

function Set-VpnCacheValue {
    <#
        Writes one value with an explicit registry kind. New-ItemProperty -Force
        replaces an existing value of any kind, which is what both planting a wrong
        kind and restoring the original kind need.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Kind,
        $Value
    )

    if (-not (Test-Path -LiteralPath $VpnRegPath)) {
        New-Item -Path $VpnRegPath -Force | Out-Null
    }

    $typed = switch ($Kind) {
        'Binary'      { [byte[]]@(@($Value) | ForEach-Object { [byte]$_ }) }
        'MultiString' { [string[]]@(@($Value) | ForEach-Object { [string]$_ }) }
        'QWord'       { [long]$Value }
        'DWord'       { [int]$Value }
        default       { [string]$Value }
    }

    New-ItemProperty -LiteralPath $VpnRegPath -Name $Name -PropertyType $Kind -Value $typed -Force | Out-Null
}

function Get-VpnCacheSnapshot {
    <#
        Captures the whole cache key: every value with its kind, or the fact that the
        key does not exist. The default (unnamed) value is skipped; the collector
        never writes it.
    #>
    $snapshot = @{ Exists = $false; Values = @{} }
    $key = Get-VpnCacheKey
    if (-not $key) { return $snapshot }

    $snapshot.Exists = $true
    foreach ($name in $key.GetValueNames()) {
        if ([string]::IsNullOrEmpty($name)) { continue }
        $snapshot.Values[$name] = @{
            Kind  = $key.GetValueKind($name).ToString()
            Value = $key.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
        }
    }
    $key.Close()
    return $snapshot
}

function Restore-VpnCacheSnapshot {
    <#
        Puts the key back exactly as Capture found it. $Original is a hashtable
        in-process or a PSCustomObject after a JSON round-trip (Resume or -Restore);
        property-style access works on both, and Values is normalised through
        ConvertTo-DexHashtable.
    #>
    param($Original)

    if (Test-Path -LiteralPath $VpnRegPath) {
        Remove-Item -LiteralPath $VpnRegPath -Recurse -Force -ErrorAction Stop
    }
    if (-not [bool]$Original.Exists) { return }

    New-Item -Path $VpnRegPath -Force | Out-Null
    $values = ConvertTo-DexHashtable -InputObject $Original.Values
    if (-not $values) { return }

    foreach ($name in @($values.Keys)) {
        $entry = $values[$name]
        Set-VpnCacheValue -Name $name -Kind ([string]$entry.Kind) -Value $entry.Value
    }
}

function Remove-VpnCacheKey {
    if (Test-Path -LiteralPath $VpnRegPath) {
        Remove-Item -LiteralPath $VpnRegPath -Recurse -Force -ErrorAction Stop
    }
}

function Set-VpnCacheRow {
    <#
        Plants a whole row. Entries are Name = @{ Kind; Value } so a method can plant
        wrong kinds as easily as wrong values.
    #>
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Row)
    foreach ($name in $Row.Keys) {
        Set-VpnCacheValue -Name $name -Kind $Row[$name].Kind -Value $Row[$name].Value
    }
}

# -- Helpers: expected row and comparison ------------------------------------------

function Get-ExpectedCollectorRow {
    <#
        Derives, from live state, the row the collector should write right now, using
        the collector's own documented rules: structural candidate test, Up + routable
        IPv4 for Connected, default-route ownership for Full/Split, NlMtu, DNS server
        presence, discard ppm from adapter statistics (looked up by Name, as collector
        1.0.1 does), NetworkProfile 10000/10001 matched on InterfaceDescription,
        RasClient 20227 in the Application log, and the section 8 score table.
        Returns Name = @{ Kind; Value } like $ExpectedNoClientState.
    #>
    $row = [ordered]@{}
    foreach ($name in $ExpectedNoClientState.Keys) {
        $row[$name] = @{ Kind = $ExpectedNoClientState[$name].Kind; Value = $ExpectedNoClientState[$name].Value }
    }

    $candidates  = @(Get-VpnCandidateAdapterObject)
    $clientCount = $candidates.Count
    if ($clientCount -eq 0) { return $row }

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

    $tunnel = Get-VpnActiveTunnelAdapter -Candidates $candidates
    if ($tunnel) {
        $connected   = $true
        $adapterName = $tunnel.InterfaceDescription

        $defRoutes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
        $viaTunnel = @($defRoutes | Where-Object { $_.ifIndex -eq $tunnel.ifIndex }).Count
        $viaOther  = @($defRoutes | Where-Object { $_.ifIndex -ne $tunnel.ifIndex }).Count
        $tunnelMode = if ($viaTunnel -gt 0 -and $viaOther -eq 0) { 'Full' } else { 'Split' }

        $ipIf = Get-NetIPInterface -InterfaceIndex $tunnel.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if ($ipIf -and $ipIf.NlMtu) { $tunnelMtu = [int]$ipIf.NlMtu }

        $dns = Get-DnsClientServerAddress -InterfaceIndex $tunnel.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($dns -and @($dns.ServerAddresses).Count -gt 0) { $dnsConfigured = $true }

        $stats = Get-NetAdapterStatistics -Name $tunnel.Name -ErrorAction SilentlyContinue
        if ($stats) {
            $rx     = if ($stats.PSObject.Properties['ReceivedUnicastPackets'])   { [double]$stats.ReceivedUnicastPackets }   else { 0 }
            $tx     = if ($stats.PSObject.Properties['SentUnicastPackets'])       { [double]$stats.SentUnicastPackets }       else { 0 }
            $rxDrop = if ($stats.PSObject.Properties['ReceivedDiscardedPackets']) { [double]$stats.ReceivedDiscardedPackets } else { 0 }
            $txDrop = if ($stats.PSObject.Properties['OutboundDiscardedPackets']) { [double]$stats.OutboundDiscardedPackets } else { 0 }
            $total  = $rx + $tx
            $discardPpm = if ($total -gt 0) { [int][math]::Round((($rxDrop + $txDrop) / $total) * 1000000) } else { 0 }
        }
    }

    $tunnelDescs = @($candidates | ForEach-Object { $_.InterfaceDescription })
    $since       = (Get-Date).AddHours(-24)

    $profileEvents = $null
    try {
        $profileEvents = Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-NetworkProfile/Operational'
            Id        = 10000, 10001
            StartTime = $since
        } -MaxEvents 500 -ErrorAction SilentlyContinue
    } catch { $profileEvents = $null }

    if ($profileEvents) {
        $tunnelEvents = @($profileEvents | Where-Object {
            $hit = $false
            foreach ($p in $_.Properties) {
                $v = $p.Value
                if ($v -is [string] -and $v -and ($tunnelDescs -contains $v)) { $hit = $true }
            }
            $hit
        })
        $flapCount = @($tunnelEvents | Where-Object { $_.Id -eq 10001 }).Count
        $lastUp = $tunnelEvents | Where-Object { $_.Id -eq 10000 } |
                  Sort-Object TimeCreated -Descending | Select-Object -First 1
        if ($lastUp) {
            $lastConnectTime = $lastUp.TimeCreated.ToString('s')
            if ($connected) { $sessionMinutes = [int]((Get-Date) - $lastUp.TimeCreated).TotalMinutes }
        }
    } else {
        $flapCount = 0
    }

    try {
        $rasFailures = Get-WinEvent -FilterHashtable @{
            LogName      = 'Application'
            ProviderName = 'RasClient'
            Id           = 20227
            StartTime    = $since
        } -MaxEvents 200 -ErrorAction SilentlyContinue
        $failCount = @($rasFailures).Count
    } catch { $failCount = 0 }

    $healthScore = 100
    $deductions  = @()
    if (-not $connected) {
        $healthScore -= 40; $deductions += @{ Points = 40; Reason = 'TunnelDown' }
    } else {
        if ($tunnelMtu -ge 1500) {
            $healthScore -= 20; $deductions += @{ Points = 20; Reason = 'MtuNotReducedForTunnel' }
        } elseif ($tunnelMtu -gt 0 -and $tunnelMtu -lt 1280) {
            $healthScore -= 25; $deductions += @{ Points = 25; Reason = 'MtuBelowMinimum' }
        }
        if (-not $dnsConfigured) {
            $healthScore -= 15; $deductions += @{ Points = 15; Reason = 'NoDnsOnTunnel' }
        }
        if ($discardPpm -gt 1000) {
            $healthScore -= 15; $deductions += @{ Points = 15; Reason = 'HighPacketDiscardRate' }
        }
    }
    if ($flapCount -ge 10) {
        $healthScore -= 25; $deductions += @{ Points = 25; Reason = 'FrequentReconnects' }
    } elseif ($flapCount -ge 4) {
        $healthScore -= 15; $deductions += @{ Points = 15; Reason = 'IntermittentReconnects' }
    }
    if ($failCount -ge 5) {
        $healthScore -= 20; $deductions += @{ Points = 20; Reason = 'RepeatedConnectFailures' }
    }
    if ($clientCount -gt 1) {
        $healthScore -= 10; $deductions += @{ Points = 10; Reason = 'MultipleVpnClients' }
    }
    if ($healthScore -lt 0) { $healthScore = 0 }
    $healthReason = if ($deductions.Count -eq 0) { 'Healthy' } else {
        ($deductions | Sort-Object { $_.Points } -Descending | Select-Object -First 1).Reason
    }

    $row['HealthScore'].Value            = [string]$healthScore
    $row['HealthReason'].Value           = $healthReason
    $row['Connected'].Value              = [int]$connected
    $row['TunnelMode'].Value             = $tunnelMode
    $row['AdapterName'].Value            = $adapterName
    $row['TunnelMtu'].Value              = [string]$tunnelMtu
    $row['LastConnectTime'].Value        = $lastConnectTime
    $row['SessionDurationMinutes'].Value = [string]$sessionMinutes
    $row['FlapCount24h'].Value           = [string]$flapCount
    $row['ConnectFailureCount24h'].Value = [string]$failCount
    $row['DnsConfigured'].Value          = [int]$dnsConfigured
    $row['DiscardRatePpm'].Value         = [string]$discardPpm
    $row['ClientCount'].Value            = [string]$clientCount
    return $row
}

function Get-VpnCacheMismatch {
    <#
        Compares the live cache against an expected row (default: derived live), value
        by value and kind by kind. SessionDurationMinutes is allowed to drift by two
        minutes between the collector run and this check. Returns one line per
        discrepancy; always a string[] so .Count is safe.
    #>
    param($Expected)

    if (-not $Expected) { $Expected = Get-ExpectedCollectorRow }

    $mismatches = New-Object System.Collections.Generic.List[string]
    $key = Get-VpnCacheKey
    if (-not $key) {
        $mismatches.Add("key $VpnRegPath missing")
        return ,[string[]]$mismatches.ToArray()
    }

    $present = @($key.GetValueNames())
    foreach ($name in $Expected.Keys) {
        $exp = $Expected[$name]
        if ($present -notcontains $name) {
            $mismatches.Add("$name missing")
            continue
        }
        $kind = $key.GetValueKind($name).ToString()
        if ($kind -ne $exp.Kind) {
            $mismatches.Add("$name kind $kind (expected $($exp.Kind))")
        }
        $actual = $key.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
        $actualText = "$actual"; $expectedText = "$($exp.Value)"
        if ($name -eq 'SessionDurationMinutes' -and $expectedText -ne '-1') {
            $a = 0; $e = 0
            if ([int]::TryParse($actualText, [ref]$a) -and [int]::TryParse($expectedText, [ref]$e) -and [math]::Abs($a - $e) -le 2) { continue }
        }
        if ($actualText -ne $expectedText) {
            $mismatches.Add("$name = '$actualText' (expected '$expectedText')")
        }
    }
    $key.Close()
    return ,[string[]]$mismatches.ToArray()
}

function Get-VpnCacheKindMismatch {
    <#
        The kind-only subset of Get-VpnCacheMismatch, used to prove the
        CacheValueKindsWrong break landed on kind rather than on value.
    #>
    $mismatches = New-Object System.Collections.Generic.List[string]
    $key = Get-VpnCacheKey
    if (-not $key) { return ,[string[]]$mismatches.ToArray() }

    $present = @($key.GetValueNames())
    foreach ($name in $ExpectedNoClientState.Keys) {
        if ($present -notcontains $name) { continue }
        $kind = $key.GetValueKind($name).ToString()
        if ($kind -ne $ExpectedNoClientState[$name].Kind) {
            $mismatches.Add("$name kind $kind (expected $($ExpectedNoClientState[$name].Kind))")
        }
    }
    $key.Close()
    return ,[string[]]$mismatches.ToArray()
}

function Get-VpnCacheLastRun {
    $raw = (Get-ItemProperty -LiteralPath $VpnRegPath -Name 'LastRun' -ErrorAction SilentlyContinue).LastRun
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try {
        return [datetime]::Parse($raw, [System.Globalization.CultureInfo]::InvariantCulture,
                                 [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        return $null
    }
}

function Test-VpnLastRunRefreshed {
    <#
        The collector stamps LastRun with Get-Date -Format 'o' on every run, including
        the error path. A LastRun older than this harness started means the row being
        validated was not written by the run under test.
    #>
    if (-not (Test-Path -LiteralPath $VpnRegPath)) { return $false }
    $stamp = Get-VpnCacheLastRun
    if (-not $stamp) { return $false }
    return ($stamp -ge $HarnessStartedAt.AddSeconds(-5))
}

function Test-VpnCacheHasNoFreshRun {
    <#
        Verify half for the reported breaks: no row from THIS run exists yet. True when
        the key is absent, LastRun is missing or unparseable, or LastRun predates the
        harness. Every planting method writes a two-day-old LastRun, so a planting break
        applied after a reported break leaves this true.
    #>
    if (-not (Test-Path -LiteralPath $VpnRegPath)) { return $true }
    $stamp = Get-VpnCacheLastRun
    if (-not $stamp) { return $true }
    return ($stamp -lt $HarnessStartedAt.AddSeconds(-5))
}

function Test-VpnCacheMatchesExpectedRow {
    <#
        Validate for every break: the full row derived from live state with the right
        kinds, and a LastRun proving the collector ran. Diagnostics go to the host
        stream only; the harness casts the calling scriptblock's output with [bool].
    #>
    $expected = Get-ExpectedCollectorRow
    Write-Host "           expected from live state: ClientCount $($expected['ClientCount'].Value), Connected $($expected['Connected'].Value), $($expected['TunnelMode'].Value), MTU $($expected['TunnelMtu'].Value), score $($expected['HealthScore'].Value) ($($expected['HealthReason'].Value))"

    $mismatches = Get-VpnCacheMismatch -Expected $expected
    if ($mismatches.Count -gt 0) {
        Write-Host "           cache mismatches: $($mismatches -join '; ')"
    }
    $refreshed = Test-VpnLastRunRefreshed
    if (-not $refreshed) {
        Write-Host '           LastRun was not refreshed by this run'
    }
    return (($mismatches.Count -eq 0) -and $refreshed)
}

function Test-VpnCacheLabAssertions {
    # The hard-coded lab invariants from $LabConnectedAssertions. Host-stream diagnostics only.
    $key = Get-VpnCacheKey
    if (-not $key) { Write-Host "           $VpnRegPath missing"; return $false }
    $ok = $true
    foreach ($name in $LabConnectedAssertions.Keys) {
        $actual = "$($key.GetValue($name, $null, 'DoNotExpandEnvironmentNames'))"
        $want   = "$($LabConnectedAssertions[$name])"
        if ($actual -ne $want) {
            Write-Host "           lab assertion failed: $name = '$actual' (expected '$want')"
            $ok = $false
        }
    }
    $key.Close()
    return $ok
}

function Test-CollectorOutputContains {
    # The collector's own words, captured from the child process by the harness.
    param([Parameter(Mandatory = $true)][string]$Pattern)
    $output = if ($state.Remediation) { "$($state.Remediation.Output)" } else { '' }
    $hit = $output -match $Pattern
    if (-not $hit) { Write-Host "           collector output did not contain '$Pattern'" }
    return $hit
}

$StaleLastRun = (Get-Date).AddDays(-2).ToString('o')

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether the collector did its job.
$BreakCatalog = @(

    @{
        Name            = 'NoVpnClientReported'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                # Collector branch: "No VPN client detected on this device." Stopping the
                # WireGuard tunnel service removes its Wintun adapter; on a host with no
                # tunnel service only the cache removal happens.
                Name  = 'StopTunnelAndClearCache'
                Apply = {
                    Stop-WireGuardTunnel
                    Remove-VpnCacheKey
                }
            }
        )
        Capture  = { @{ Cache = Get-VpnCacheSnapshot; Tunnels = Get-WireGuardTunnelState } }
        Verify   = {
            # Wait for the adapter to go away (Wintun removal lags the service stop by a
            # few seconds), then confirm no row from this run exists yet.
            $gone  = Wait-VpnCandidateState -ExpectedCount 0 -TimeoutSec 30
            $fresh = -not (Test-VpnCacheHasNoFreshRun)
            if ($fresh) { Write-Host "           $VpnRegPath already carries a LastRun from this run" }
            $gone -and -not $fresh
        }
        Validate = {
            $rowOk    = Test-VpnCacheMatchesExpectedRow
            $outputOk = Test-CollectorOutputContains -Pattern 'No VPN client detected'
            $rowOk -and $outputOk
        }
        Restore  = {
            param($Original)
            Restore-VpnCacheSnapshot -Original $Original.Cache
            Restore-WireGuardTunnelState -Tunnels $Original.Tunnels
        }
    },

    @{
        Name            = 'TunnelConnectedReported'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                # Collector branch: "Active tunnel: WireGuard Tunnel (ifIndex N)". A host
                # without a WireGuardTunnel$* service has nothing to start and fails
                # Verify as BreakFailed, which is the correct verdict there.
                Name  = 'StartTunnelAndClearCache'
                Apply = {
                    if (@(Get-WireGuardTunnelService).Count -eq 0) {
                        Write-Host "           no $WireGuardServicePattern service installed; Verify will fail"
                    }
                    Start-WireGuardTunnel
                    Remove-VpnCacheKey
                }
            }
        )
        Capture  = { @{ Cache = Get-VpnCacheSnapshot; Tunnels = Get-WireGuardTunnelState } }
        Verify   = {
            $up    = Wait-VpnCandidateState -ExpectedCount 1 -RequireUp -TimeoutSec 45
            $fresh = -not (Test-VpnCacheHasNoFreshRun)
            if ($fresh) { Write-Host "           $VpnRegPath already carries a LastRun from this run" }
            $up -and -not $fresh
        }
        Validate = {
            $rowOk    = Test-VpnCacheMatchesExpectedRow
            $labOk    = Test-VpnCacheLabAssertions
            $outputOk = Test-CollectorOutputContains -Pattern 'Active tunnel: WireGuard Tunnel'
            $rowOk -and $labOk -and $outputOk
        }
        Restore  = {
            param($Original)
            Restore-VpnCacheSnapshot -Original $Original.Cache
            Restore-WireGuardTunnelState -Tunnels $Original.Tunnels
        }
    },

    @{
        Name            = 'StaleCacheFromPriorClient'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                # A client that was connected and healthy on a fictional adapter, then
                # uninstalled. Every value is wrong for either real tunnel state.
                Name  = 'PlantConnectedHealthy'
                Apply = {
                    Set-VpnCacheRow -Row ([ordered]@{
                        HealthScore            = @{ Kind = 'String'; Value = '95' }
                        HealthReason           = @{ Kind = 'String'; Value = 'Healthy' }
                        Connected              = @{ Kind = 'DWord';  Value = 1 }
                        TunnelMode             = @{ Kind = 'String'; Value = 'Full' }
                        AdapterName            = @{ Kind = 'String'; Value = 'Contoso VPN Virtual Adapter' }
                        TunnelMtu              = @{ Kind = 'String'; Value = '1400' }
                        LastConnectTime        = @{ Kind = 'String'; Value = (Get-Date).AddHours(-3).ToString('s') }
                        SessionDurationMinutes = @{ Kind = 'String'; Value = '180' }
                        FlapCount24h           = @{ Kind = 'String'; Value = '2' }
                        ConnectFailureCount24h = @{ Kind = 'String'; Value = '1' }
                        DnsConfigured          = @{ Kind = 'DWord';  Value = 1 }
                        DiscardRatePpm         = @{ Kind = 'String'; Value = '12' }
                        ClientCount            = @{ Kind = 'String'; Value = '2' }
                        LastRun                = @{ Kind = 'String'; Value = $StaleLastRun }
                    })
                }
            },
            @{
                # A client that was present but down. HealthScore 0 is the value the
                # header says must never be confused with -1.
                Name  = 'PlantUnhealthyResidue'
                Apply = {
                    Set-VpnCacheRow -Row ([ordered]@{
                        HealthScore            = @{ Kind = 'String'; Value = '0' }
                        HealthReason           = @{ Kind = 'String'; Value = 'TunnelDown' }
                        Connected              = @{ Kind = 'DWord';  Value = 0 }
                        TunnelMode             = @{ Kind = 'String'; Value = 'None' }
                        AdapterName            = @{ Kind = 'String'; Value = 'Contoso VPN Virtual Adapter' }
                        TunnelMtu              = @{ Kind = 'String'; Value = '-1' }
                        LastConnectTime        = @{ Kind = 'String'; Value = (Get-Date).AddDays(-1).ToString('s') }
                        SessionDurationMinutes = @{ Kind = 'String'; Value = '-1' }
                        FlapCount24h           = @{ Kind = 'String'; Value = '12' }
                        ConnectFailureCount24h = @{ Kind = 'String'; Value = '7' }
                        DnsConfigured          = @{ Kind = 'DWord';  Value = 0 }
                        DiscardRatePpm         = @{ Kind = 'String'; Value = '-1' }
                        ClientCount            = @{ Kind = 'String'; Value = '3' }
                        LastRun                = @{ Kind = 'String'; Value = $StaleLastRun }
                    })
                }
            },
            @{
                # What the collector's own catch path leaves on a fresh key: only
                # HealthReason and LastRun. The next good run must repopulate all 13.
                Name  = 'PlantCollectionErrorResidue'
                Apply = {
                    Remove-VpnCacheKey
                    Set-VpnCacheRow -Row ([ordered]@{
                        HealthReason = @{ Kind = 'String'; Value = 'CollectionError' }
                        LastRun      = @{ Kind = 'String'; Value = $StaleLastRun }
                    })
                }
            }
        )
        Capture  = { Get-VpnCacheSnapshot }
        Verify   = {
            $mismatches = Get-VpnCacheMismatch
            if ($mismatches.Count -eq 0) {
                Write-Host '           cache already matches the live-derived row; nothing was planted'
            } else {
                Write-Host "           planted $($mismatches.Count) discrepancy(ies): $($mismatches -join '; ')"
            }
            $mismatches.Count -gt 0
        }
        Validate = { Test-VpnCacheMatchesExpectedRow }
        Restore  = {
            param($Original)
            Restore-VpnCacheSnapshot -Original $Original
        }
    },

    @{
        Name            = 'CacheValueKindsWrong'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                # Plausible values, swapped kinds: the integer-ish strings become DWORDs
                # and the DWORD booleans become strings. Only the kind check can catch it.
                Name  = 'SwapStringAndDwordKinds'
                Apply = {
                    Set-VpnCacheRow -Row ([ordered]@{
                        HealthScore   = @{ Kind = 'DWord';  Value = -1 }
                        Connected     = @{ Kind = 'String'; Value = '0' }
                        ClientCount   = @{ Kind = 'DWord';  Value = 0 }
                        DnsConfigured = @{ Kind = 'String'; Value = '0' }
                        LastRun       = @{ Kind = 'String'; Value = $StaleLastRun }
                    })
                }
            },
            @{
                # Plausible values under REG_MULTI_SZ and REG_EXPAND_SZ, which a sensor
                # doing Get-ItemProperty ... -as [int] / [string] handles differently.
                Name  = 'PlantMultiAndExpandStringKinds'
                Apply = {
                    Set-VpnCacheRow -Row ([ordered]@{
                        HealthReason = @{ Kind = 'MultiString';  Value = @('NoVpnClient') }
                        HealthScore  = @{ Kind = 'ExpandString'; Value = '-1' }
                        TunnelMode   = @{ Kind = 'ExpandString'; Value = 'None' }
                        LastRun      = @{ Kind = 'String';       Value = $StaleLastRun }
                    })
                }
            }
        )
        Capture  = { Get-VpnCacheSnapshot }
        Verify   = {
            $kinds = Get-VpnCacheKindMismatch
            if ($kinds.Count -eq 0) {
                Write-Host '           every documented value still has its documented kind; nothing was planted'
            } else {
                Write-Host "           planted wrong kind(s): $($kinds -join '; ')"
            }
            $kinds.Count -gt 0
        }
        Validate = { Test-VpnCacheMatchesExpectedRow }
        Restore  = {
            param($Original)
            Restore-VpnCacheSnapshot -Original $Original
        }
    }
)

function Get-BreakDefinition {
    param([Parameter(Mandatory = $true)][string]$Name)
    $BreakCatalog | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Request-TestReboot {
    param([Parameter(Mandatory = $true)][hashtable]$State)

    Save-DexTestState -State $State
    Register-DexTestResume -State $State -BreakTestPath $SelfPath
    Write-DexStep -Status 'Info' -Name 'Reboot' -Message 'Rebooting to apply pending state; run resumes automatically.'
    & shutdown.exe /r /t 15 /f | Out-Null
}

# ==============================================================================
# Main
# ==============================================================================

Assert-DexTestHost -Force:$Force -ProductionDomainDenyList $ProductionDomainDenyList

Write-DexBanner -Title "Invoke-VpnStateCollection_BreakTest" -Detail "Environment: $Environment"

# -- Restore-only mode ---------------------------------------------------------
if ($Restore) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    foreach ($b in $state.Breaks) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
            Write-DexStep -Status 'Passed' -Name "Restore $($b.Name)"
        } catch {
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }
    Remove-Fixture
    Unregister-DexTestResume -State $state
    $state.Phase   = 'Restored'
    $state.Overall = 'Restored'
    Write-DexTestResult -State $state | Out-Null
    Clear-DexTestState -State $state
    exit 0
}

# -- Acquire context -----------------------------------------------------------
if ($Resume) {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Resume
    if (Test-DexRebootOccurred -State $state) {
        $state.RebootCount = [int]$state.RebootCount + 1
        Write-DexStep -Status 'Info' -Name 'Resume' -Message "Reboot #$($state.RebootCount) confirmed; resuming at phase '$($state.Phase)'."
    } else {
        Write-DexStep -Status 'Warning' -Name 'Resume' -Message 'No reboot detected since the run started.'
    }
    # RemediationTest cannot survive as a switch across the reboot, so it is
    # recovered from the state that was persisted before the machine went down.
    $RemediationTest = [bool]$state.RemediationTest
} else {
    $state = New-DexTestContext -ScriptUnderTest $ScriptUnderTest -Seed $Seed -Environment $Environment
    $state.RemediationTest = [bool]$RemediationTest
    Write-DexStep -Status 'Info' -Name 'Context' -Message "TestId $($state.TestId)  Seed $($state.Seed)"
}

$exitCode = 0

try {
    # -- Phase: apply breaks ---------------------------------------------------
    if ($state.Phase -eq 'Init') {

        Initialize-Fixture

        $candidates = if ($BreakName) {
            @($BreakCatalog | Where-Object { @($BreakName -split ',' | ForEach-Object { $_.Trim() }) -contains $_.Name })
        } else {
            @($BreakCatalog | Where-Object { $IncludeRebootBreaks -or -not $_.RequiresReboot })
        }

        if ($candidates.Count -eq 0) { throw 'No break definitions matched the requested selection.' }

        $selected = if ($BreakName) {
            $candidates
        } else {
            Get-DexRandomSubset -InputObject $candidates -Random $state.Random -Count $BreakCount
        }
        # Re-wrap in a second statement, not as `@(if ...)`. The if-expression unrolls a
        # one-element $candidates to the bare hashtable (so -BreakName X made .Count the
        # hashtable's key count and $selected[0] $null), while wrapping the whole if in @()
        # nests the array Get-DexRandomSubset already hands back as a single object.
        $selected = @($selected)

        # The two reported breaks pull the tunnel in opposite directions (stopped versus
        # running) and cannot share a run. Keep whichever the seeded shuffle drew first so
        # both get coverage across seeds; force one with -BreakName. Either may pair with
        # the planting breaks.
        $exclusive = @('NoVpnClientReported', 'TunnelConnectedReported')
        if (@($selected | Where-Object { $exclusive -contains $_.Name }).Count -gt 1) {
            $keep     = @($selected | Where-Object { $exclusive -contains $_.Name })[0].Name
            $selected = @($selected | Where-Object { ($exclusive -notcontains $_.Name) -or ($_.Name -eq $keep) })
            Write-DexStep -Status 'Info' -Name 'Selection' -Message "tunnel-state breaks are mutually exclusive; kept '$keep'"
        }

        $applied = @()
        foreach ($def in $selected) {
            $method = (Get-DexRandomSubset -InputObject $def.Methods -Random $state.Random -Count 1)[0]

            $original = & $def.Capture
            & $method.Apply

            if ($def.RequiresReboot) { $state.RequiresReboot = $true }

            $applied += @{
                Name            = $def.Name
                Method          = $method.Name
                ExpectedOutcome = $def.ExpectedOutcome
                RequiresReboot  = [bool]$def.RequiresReboot
                Applied         = $true
                BreakVerified   = $false
                OriginalState   = $original
            }
            Write-DexStep -Status 'Info' -Name "Break $($def.Name)" -Message "method '$($method.Name)' applied"
            # Commit at once so Restore can undo this break even if a later Capture/Apply throws.
            # On 2026-10-28 a disabled Spooler was left behind because the next break's Capture
            # threw and the applied list had not been committed yet.
            $state.Breaks = $applied
            Save-DexTestState -State $state
        }

        $state.Breaks = $applied
        $state.Phase  = 'Broken'
        Save-DexTestState -State $state

        if ($state.RequiresReboot) {
            Request-TestReboot -State $state
            exit 0
        }
    }

    # -- Phase: verify the break -----------------------------------------------
    if ($state.Phase -eq 'Broken') {

        $allVerified = $true
        foreach ($b in $state.Breaks) {
            $def = Get-BreakDefinition -Name $b.Name
            $ok  = [bool](& $def.Verify)
            $b.BreakVerified = $ok
            if ($ok) {
                Write-DexStep -Status 'Passed' -Name "Verify $($b.Name)" -Message 'component is genuinely broken'
            } else {
                $allVerified = $false
                Write-DexStep -Status 'Failed' -Name "Verify $($b.Name)" -Message 'break did not land; collection would be a false green'
            }
        }

        if (-not $allVerified) {
            $state.Phase   = 'BreakFailed'
            $state.Overall = 'BreakFailed'
            Save-DexTestState -State $state
            throw 'One or more breaks could not be verified; refusing to run the collector.'
        }

        $state.Phase = 'BreakVerified'
        Save-DexTestState -State $state
    }

    # -- Phase: remediate (run the collector) ----------------------------------
    if ($state.Phase -eq 'BreakVerified') {

        if (-not $RemediationTest) {
            $state.Overall = 'BreakOnly'
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message 'skipped (-RemediationTest not supplied)'
        } else {
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "invoking $([System.IO.Path]::GetFileName($RemediationScript))"

            # The collector uses Write-Error in its catch path. Under the harness's
            # $ErrorActionPreference = 'Stop' the first stderr line of a native command
            # redirected with 2>&1 becomes a terminating NativeCommandError, which turned
            # every failing collector run into HarnessError "Invoke-VpnStateCollection : "
            # with no detail. Capture stderr as text so a failing collector is a Validate
            # failure with its full output in the JSON.
            $sw      = [System.Diagnostics.Stopwatch]::StartNew()
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1 |
                          ForEach-Object { "$_" }
                $rc = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prevEap
            }
            $sw.Stop()

            $state.Remediation = @{
                ExitCode    = $rc
                DurationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                Output      = ($output | Out-String).Trim()
            }
            $state.Phase = 'Remediated'
            Save-DexTestState -State $state

            if ($state.RequiresReboot) {
                Request-TestReboot -State $state
                exit 0
            }
        }
    }

    # -- Phase: validate -------------------------------------------------------
    if ($state.Phase -eq 'Remediated') {

        $validation = @()
        foreach ($b in $state.Breaks) {
            $def    = Get-BreakDefinition -Name $b.Name
            $passed = [bool](& $def.Validate)

            $expected = if ($b.ExpectedOutcome -eq 'ExpectFixed') {
                'planted cache state overwritten by the collector'
            } else {
                'condition detected and reported in the cache'
            }

            $validation += @{
                Name     = $b.Name
                Expected = $expected
                Actual   = if ($passed) { 'as expected' } else { 'NOT as expected' }
                Result   = if ($passed) { 'Pass' } else { 'Fail' }
            }
            Write-DexStep -Status $(if ($passed) { 'Passed' } else { 'Failed' }) `
                          -Name "Validate $($b.Name)" -Message $expected
        }

        $state.Validation = $validation
        $state.Phase      = 'Validated'

        $failedCount = @($validation | Where-Object { $_.Result -eq 'Fail' }).Count
        $state.Overall = if ($failedCount -eq 0) {
            'Passed'
        } elseif ($state.Remediation -and [int]$state.Remediation.ExitCode -eq 0) {
            # The collector exited 0 while the cache is still wrong.
            'FalsePass'
        } else {
            'Failed'
        }

        Save-DexTestState -State $state
    }

} catch {
    Write-DexStep -Status 'Failed' -Name 'Harness' -Message $_.Exception.Message
    $state.HarnessError = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    if ($state.Overall -eq 'Incomplete') { $state.Overall = 'Failed' }
    $exitCode = 1
}

# -- Restore -------------------------------------------------------------------
# Snapshot environments revert on the host, so restoring here would only add risk.
if ($Environment -eq 'Physical') {
    $restoreFailed = $false
    # Restore newest-first. A later break's Capture can record state an earlier break had
    # already changed; undoing in reverse order lets the oldest capture, the true baseline, win.
    $toRestore = @($state.Breaks); [array]::Reverse($toRestore)
    foreach ($b in $toRestore) {
        $def = Get-BreakDefinition -Name $b.Name
        if (-not $def) { continue }
        try {
            & $def.Restore ([PSCustomObject]$b.OriginalState)
        } catch {
            $restoreFailed = $true
            Write-DexStep -Status 'Failed' -Name "Restore $($b.Name)" -Message $_.Exception.Message
        }
    }
    try { Remove-Fixture } catch { $restoreFailed = $true }

    if ($restoreFailed) {
        $state.Overall = 'Dirty'
        Write-DexStep -Status 'Failed' -Name 'Restore' -Message 'machine left modified -- manual cleanup required'
    } else {
        $state.Phase = 'Restored'
        Write-DexStep -Status 'Passed' -Name 'Restore' -Message 'machine returned to baseline'
    }
}

Unregister-DexTestResume -State $state

Write-Output ''
Write-DexStep -Status $(switch ($state.Overall) { 'Passed' { 'Passed' } 'BreakOnly' { 'Info' } default { 'Failed' } }) `
              -Name 'Overall' -Message $state.Overall

Write-DexTestResult -State $state | Out-Null
Clear-DexTestState -State $state

exit $exitCode
