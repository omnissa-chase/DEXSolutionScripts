<#
.SYNOPSIS
    Invoke-AutoRemediateGenericVPN_BreakTest -- deliberately mis-sets the lab WireGuard
    tunnel's MTU and DNS, disables the Windows VPN support service, or removes the
    tunnel outright, then verifies Invoke-AutoRemediateGenericVPN.ps1 fixes what it
    owns and reports what it does not.

.DESCRIPTION
    Break -> verify-the-break -> remediate -> validate -> restore. Writes a uniform JSON
    result to C:\Temp\FixReport\Invoke-AutoRemediateGenericVPN\ for
    Invoke-FixReportAnalysis.ps1 to aggregate.

    THIS SCRIPT IS DELIBERATELY DESTRUCTIVE. It changes the IPv4 MTU and DNS servers of
    the live tunnel adapter, stops and disables RasMan (Remote Access Connection
    Manager), and stops and starts every WireGuardTunnel$* service on the host. Run it
    only on a disposable VM or a marked test host. See Assert-DexTestHost in
    DEXTestFramework.psm1.

    THE SCRIPT UNDER TEST
    Invoke-AutoRemediateGenericVPN.ps1 finds a tunnel structurally (a non-hardware
    adapter not matching its virtual-infrastructure exclusion list; the first one that
    is Up with a routable IPv4 address is the active tunnel), exits early with "No VPN
    client present on this device. Nothing to process." when there is no candidate, and
    otherwise runs five enabled steps:
      1 Multiple VPN Clients   report only (Warning when > 1 candidate)
      2 VPN Support Services   RasMan/IKEEXT/BFE: Failed when Disabled or not Running;
                               resolution sets Disabled -> Manual (never for BFE) and
                               issues sc.exe start
      3 Tunnel MTU             Failed when IPv4 NlMtu >= 1500 or < 1280; resolution
                               Set-NetIPInterface -NlMtuBytes 1400
      4 Tunnel DNS             Failed when the active tunnel has no IPv4 DNS server;
                               resolution ipconfig /flushdns + /registerdns ONLY --
                               it never assigns a server
      5 Orphaned Tunnel Routes Failed when a candidate adapter that is NOT Up still
                               owns ActiveStore routes; resolution removes them
    Step 6 (adapter bounce) is Enabled = $false and is not exercised. A detected and
    remediated step prints "[Failed ] <step>: <detail>  -> Remediation ran" and the
    script still exits 0; only a remediation that threw gives exit 1. Every live run
    that gets past the guard writes LastRun, ScriptVersion, Passed, Warnings, Failed,
    RemediationsRun and RemediationErrors (all REG_SZ) to
    HKLM:\Software\AirWatch\Extensions\VPN\Remediation; the guard path writes nothing.

    THE LAB TUNNEL
    WireGuard for Windows with a tunnel from VPN\_AutomatedTesting\New-WireGuardLabPair.ps1:
    service WireGuardTunnel$<name>, adapter Name <name>, InterfaceDescription
    'WireGuard Tunnel', 10.99.0.1/24, DNS 10.99.0.2 set on the adapter, IPv4 NlMtu
    1420 (Wintun's link MTU is huge, so any NlMtu up to 65535 can be set), split tunnel
    (default route stays on the physical adapter), peer 10.99.0.2. The tunnel's .conf
    has no MTU line, so a service restart puts MTU back to 1420 and DNS back to
    10.99.0.2; stopping the service removes the adapter entirely. The harness never
    hard-codes the adapter name: every break resolves the active tunnel with the
    remediator's own structural test and records its InterfaceAlias in Capture.

    MTU AND THE STOCK TUNNEL
    The remediator passes a stock tunnel at 1420 untouched (1280 <= 1420 < 1500), but
    whenever it DOES remediate MTU it writes its own target, 1400, not the value the
    tunnel had before. A remediated run therefore always leaves a stock WireGuard tunnel
    lower than it started, so Capture records the pre-break NlMtu and Restore puts that
    exact value back; the 1400 is never left behind.

    SUPPORT SERVICES ON EVERY RUN
    Step 2 fires on any run where RasMan or IKEEXT is stopped, not only when this
    harness disables one. RasMan is Manual start on Windows and is often stopped when
    no RAS connection exists, so a run of this harness can leave RasMan (and IKEEXT)
    Running where they were stopped before. That is the remediator doing what its header
    says. Only VpnSupportServiceDisabled captures and restores RasMan; the other breaks
    document the side effect and leave it.

    VERIFY-THE-BREAK
    Every break is followed by a probe proving the component is genuinely broken, read
    after a short settle so a WireGuard watcher reverting the change is caught rather
    than hidden. A break that silently no-ops would let the remediator "pass" against a
    healthy machine -- a false green. A break that cannot be verified aborts the run as
    BreakFailed before the remediator is invoked.

    EXPECTED OUTCOMES
      ExpectFixed        -- the remediator must correct the planted fault
      ExpectReportedOnly -- the remediator must DETECT and report the fault; the fault
                            is outside what it owns and must still be present afterwards

    TunnelMtuTooHigh        ExpectFixed. Set-NetIPInterface IPv4 NlMtuBytes 1500 on the
                            active tunnel. Verify: NlMtu reads 1500 two seconds later.
                            Validate: live NlMtu is exactly the script's TargetTunnelMtu
                            (1400); output carries "[Failed ] Tunnel MTU: Tunnel MTU is
                            1500, no allowance for encapsulation overhead  -> Remediation
                            ran"; exit code 0; the Remediation cache has a LastRun newer
                            than this run started, RemediationErrors '0' and
                            RemediationsRun >= 1. Restore: captured NlMtu (1420).
    TunnelMtuTooLow         ExpectFixed. Same lever at 1200, below the script's 1280
                            floor. Validate as above with "Tunnel MTU is 1200, below the
                            1280 minimum".
    TunnelDnsMissing        ExpectReportedOnly. Set-DnsClientServerAddress
                            -ResetServerAddresses empties the tunnel's IPv4 server list.
                            Derivation: step 4's resolution is ipconfig /flushdns and
                            /registerdns; the script's own comment says the servers come
                            from the vendor profile and "guessing them would be worse than
                            leaving them unset". So the condition must be detected and
                            reported, the step must still show Failed with "Remediation
                            ran" (the flush did run), exit code 0, and the tunnel must
                            STILL have no IPv4 DNS server afterwards -- a server appearing
                            would mean the script invented one. Cache refreshed as above.
                            Restore: Set-DnsClientServerAddress with the captured list.
    VpnSupportServiceDisabled
                            ExpectFixed. Stop-Service RasMan -Force, then StartupType
                            Disabled (Capture records StartMode, State and which
                            dependents were running). Verify: Win32_Service StartMode
                            'Disabled' and State 'Stopped'. Validate: StartMode is no
                            longer 'Disabled' (the script sets Manual, never Automatic),
                            State reaches Running within 20 s (sc.exe start returns at
                            START_PENDING), output carries "[Failed ] VPN Support
                            Services: Service(s) not available: ... RasMan (disabled)
                            -> Remediation ran", exit 0, cache refreshed. BFE is never
                            touched: the Windows Firewall depends on it and the script
                            refuses to change its start type anyway. Restore: captured
                            start type, then captured State (dependents restarted if they
                            were running).
    NoVpnClientReported     ExpectReportedOnly. Stops every running WireGuardTunnel$*
                            service, which removes the Wintun adapter. Verify waits up to
                            30 s for the structural test to find zero candidates.
                            Validate: output carries "No VPN client present on this
                            device. Nothing to process.", no step line at all, exit 0,
                            and the Remediation cache was NOT written by this run (the
                            guard exits before the cache block). Restore starts the
                            services again and waits for the adapter to be Up.

    NoVpnClientReported removes the adapter every other break needs, so it never shares
    a run: when the seeded draw puts it first it runs alone, otherwise it is dropped.
    TunnelMtuTooHigh and TunnelMtuTooLow write the same value and cannot both be
    verified; the one drawn first is kept. Everything else may pair. Capture nests and
    Restore undoes newest-first.

    WHATIF
    The remediator reads $env:WhatIf and treats a true value as a dry run that touches
    nothing and caches nothing, which would make every ExpectFixed break a FalsePass.
    The harness removes WhatIf from its own environment before launching the child
    process and puts it back afterwards.

    NOT COVERED
    OrphanedTunnelRoute: step 5 only looks at candidate adapters whose Status is not Up.
    The Wintun adapter exists only while the tunnel service runs, and while it runs it
    is Up regardless of handshake, so no route can be stranded on a WireGuard adapter
    the way step 5 detects. OpenVPN's TAP-Windows adapter, which persists
    media-disconnected between sessions, is the lever for that branch. Also uncovered:
    Multiple VPN Clients (needs a second client installed; report-only anyway), the
    disabled step 6, a disabled BFE (would take the firewall down with it), and the
    WhatIf dry-run path itself.

    RESTORE
    Capture records exactly what each break changes: the tunnel's InterfaceAlias with
    its IPv4 NlMtu or its IPv4 DNS server list, RasMan's StartMode/State/running
    dependents, or the Status of every WireGuardTunnel$* service. Restore writes the
    captured values back with Set-NetIPInterface / Set-DnsClientServerAddress and
    re-reads them; only if they still differ does it fall back to restarting the tunnel
    service (which the .conf resets to 1420 / 10.99.0.2) and re-check. The remediator's
    registry cache under ...\VPN\Remediation and its log at
    %SystemRoot%\Temp\UEM_AutoRemediateGenericVPN.log are its own output and are left in
    place as evidence.

    REBOOTS
    Nothing here is flagged RequiresReboot. Breaks flagged RequiresReboot would suspend
    the run, register an AtStartup resume task, and reboot. Opt in with
    -IncludeRebootBreaks; they are excluded by default.

.PARAMETER RemediationTest
    After breaking, run Invoke-AutoRemediateGenericVPN.ps1 and validate the outcome.
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
    Undo an in-flight run's breaks and exit. No remediation, no validation.

.PARAMETER Resume
    Internal. Used by the AtStartup task to re-enter after a reboot.

.PARAMETER Force
    Required acknowledgement that this machine will be broken.

.NOTES
    Script Name  : Invoke-AutoRemediateGenericVPN_BreakTest.ps1
    Version      : 1.0.1
    Architecture : Any (x86/x64)
    Context      : Administrator (elevated)
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-11-02
    Reporting    : C:\Temp\FixReport\Invoke-AutoRemediateGenericVPN\

    1.0.0  Initial: MTU high/low, DNS missing, RasMan disabled, no-client guard, all
           against the WireGuard lab tunnel. Shape follows
           Invoke-VpnStateCollection_BreakTest.ps1 1.1.1.

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

$ScriptUnderTest   = 'Invoke-AutoRemediateGenericVPN'
$RemediationScript = Join-Path $PSScriptRoot '..\Invoke-AutoRemediateGenericVPN.ps1'
$RemediationRegPath = 'HKLM:\Software\AirWatch\Extensions\VPN\Remediation'
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
# The component under test is the live lab tunnel plus the Windows VPN support
# services; nothing is built. Every break snapshots exactly what it changes in Capture,
# so the fixture has nothing to prepare and nothing to tear down. The remediator's
# registry cache and log are kept as evidence.
function Initialize-Fixture {
}

function Remove-Fixture {
    # Intentionally empty: Restore puts the captured MTU, DNS, service and tunnel state
    # back; the remediator's cache and log are left in place for the operator.
}

# -- Constants mirrored from the script under test ------------------------------
# Kept verbatim so the harness asserts the remediator's documented numbers rather than
# approximating them. If the script's tunables change, these must change with them.
$TargetTunnelMtu = 1400
$MtuCeiling      = 1500
$MtuFloor        = 1280

# Same exclusion list as the remediator and the collector.
$ExcludedAdapterPattern = '(?i)(vEthernet|Hyper-V|WSL|Docker|VMware|VirtualBox|Bluetooth|Loopback|Npcap|Wi-Fi Direct|Kernel Debug|Teredo|ISATAP|6to4|VirtualPCNet|TeamViewer|Parsec)'

$WireGuardServicePattern = 'WireGuardTunnel$*'

# Planted MTU values, derived from the script's own thresholds so they cannot drift.
# 1500 is exactly the ceiling (the Ethernet default the script calls "no allowance for
# encapsulation overhead", detected with -ge); 1200 is 80 below its 1280 floor.
$PlantedMtuHigh = $MtuCeiling
$PlantedMtuLow  = $MtuFloor - 80

$SupportServiceName = 'RasMan'

# -- Helpers: adapters and tunnel services --------------------------------------

function Get-VpnCandidateAdapterObject {
    <#
        Mirrors Get-CandidateTunnelAdapter in the remediator: visible adapters that are
        not hardware and do not match the exclusion pattern. Plain array on purpose:
        every caller wraps this in @(...). The ,[object[]] form nests under @(), so
        @(...).Count is 1 whether there are 0 or 1 candidates.
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
    return $list.ToArray()
}

function Get-VpnCandidateTunnelAdapter {
    # Printable form of the candidates for Verify diagnostics. Plain array; callers wrap.
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($a in @(Get-VpnCandidateAdapterObject)) {
        $names.Add("$($a.Name) [$($a.InterfaceDescription)] $($a.Status)")
    }
    return $names.ToArray()
}

function Get-VpnActiveTunnelAdapter {
    # Mirrors Get-ActiveTunnelAdapter in the remediator.
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

function Get-LabTunnelAdapter {
    <#
        The adapter the remediator will treat as the active tunnel right now, resolved
        with its own structural test so the harness breaks exactly what it will inspect.
        Throws when there is none: every tunnel break needs a live tunnel, and a Capture
        that cannot find one is a harness error, not a verified break.
    #>
    $tunnel = Get-VpnActiveTunnelAdapter -Candidates @(Get-VpnCandidateAdapterObject)
    if (-not $tunnel) {
        $names = @(Get-VpnCandidateTunnelAdapter)
        throw "no active tunnel adapter (Up with a routable IPv4 address); candidates: [$($names -join ', ')]"
    }
    return $tunnel
}

function Wait-VpnCandidateState {
    <#
        Polls the remediator's structural test until the candidate count matches and,
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

    $names = @(Get-VpnCandidateTunnelAdapter)
    Write-Host "           after ${TimeoutSec}s: $($names.Count) candidate adapter(s) [$($names -join ', ')], wanted $ExpectedCount$(if ($RequireUp) { ' Up with IPv4' })"
    return $false
}

function Get-WireGuardTunnelService {
    # Plain array; callers wrap in @(...).
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($svc in @(Get-Service -Name $WireGuardServicePattern -ErrorAction SilentlyContinue)) {
        if ($null -ne $svc) { $list.Add($svc) }
    }
    return $list.ToArray()
}

function Get-WireGuardTunnelState {
    # Capture shape: one @{ Name; Status } per WireGuardTunnel$* service. Plain array.
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($svc in @(Get-WireGuardTunnelService)) {
        $list.Add(@{ Name = $svc.Name; Status = [string]$svc.Status })
    }
    return $list.ToArray()
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

function Restart-WireGuardTunnelAndWait {
    <#
        The fallback lever for MTU and DNS restore: the lab .conf has no MTU or
        overriding DNS line, so a restart of the tunnel service rebuilds the adapter at
        1420 / 10.99.0.2. Waits for the adapter to be Up again.
    #>
    $running = @(Get-WireGuardTunnelService | Where-Object { $_.Status -eq 'Running' })
    if ($running.Count -eq 0) { throw 'no running WireGuardTunnel$* service to restart' }
    foreach ($svc in $running) {
        Restart-Service -Name $svc.Name -Force -ErrorAction Stop
    }
    if (-not (Wait-VpnCandidateState -ExpectedCount 1 -RequireUp -TimeoutSec 45)) {
        throw 'WireGuard tunnel service restarted but its adapter did not come Up within 45 s'
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

# -- Helpers: tunnel MTU --------------------------------------------------------------

function Get-TunnelNlMtu {
    <#
        The IPv4 NlMtu of the named interface, exactly as the remediator reads it
        (Get-NetIPInterface, not Get-NetAdapter MtuSize, which on Wintun is the link
        maximum and meaningless here). -1 when unreadable.
    #>
    param([Parameter(Mandatory = $true)][string]$InterfaceAlias)
    $ipIf = Get-NetIPInterface -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if ($ipIf -and $ipIf.NlMtu) { return [int]$ipIf.NlMtu }
    return -1
}

function Set-TunnelNlMtu {
    param(
        [Parameter(Mandatory = $true)][string]$InterfaceAlias,
        [Parameter(Mandatory = $true)][int]$NlMtu
    )
    Set-NetIPInterface -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -NlMtuBytes $NlMtu -ErrorAction Stop
}

function Get-TunnelMtuCapture {
    # Capture shape for the MTU breaks: which interface, and what it had.
    $tunnel = Get-LabTunnelAdapter
    return @{ InterfaceAlias = [string]$tunnel.Name; NlMtu = (Get-TunnelNlMtu -InterfaceAlias $tunnel.Name) }
}

function Test-TunnelMtuPlanted {
    <#
        Verify for the MTU breaks. Re-reads after a two-second settle so a WireGuard
        watcher putting the value back would show up as a failed break rather than a
        false green. Host-stream diagnostics only.
    #>
    param([Parameter(Mandatory = $true)][int]$Expected)
    Start-Sleep -Seconds 2
    $tunnel = Get-VpnActiveTunnelAdapter -Candidates @(Get-VpnCandidateAdapterObject)
    if (-not $tunnel) { Write-Host '           no active tunnel adapter to read MTU from'; return $false }
    $mtu = Get-TunnelNlMtu -InterfaceAlias $tunnel.Name
    Write-Host "           $($tunnel.Name) IPv4 NlMtu is $mtu (planted $Expected)"
    return ($mtu -eq $Expected)
}

function Test-TunnelMtuRemediated {
    <#
        Validate for the MTU breaks: the live NlMtu equals the script's TargetTunnelMtu,
        the step line shows the planted detection with "Remediation ran", exit 0, and
        the cache reflects a run with at least one remediation and no errors.
    #>
    param([Parameter(Mandatory = $true)][string]$DetectionPattern)

    $tunnel = Get-VpnActiveTunnelAdapter -Candidates @(Get-VpnCandidateAdapterObject)
    if (-not $tunnel) { Write-Host '           no active tunnel adapter to read MTU from'; return $false }
    $mtu   = Get-TunnelNlMtu -InterfaceAlias $tunnel.Name
    $mtuOk = ($mtu -eq $TargetTunnelMtu)
    Write-Host "           $($tunnel.Name) IPv4 NlMtu is $mtu (expected $TargetTunnelMtu)"

    $lineOk  = Test-RemediatorOutputContains -Pattern "\[Failed \] Tunnel MTU: $DetectionPattern\s+-> Remediation ran"
    $exitOk  = Test-RemediatorExitCode -Expected 0
    $cacheOk = Test-RemediationCacheReflectsRun
    return ($mtuOk -and $lineOk -and $exitOk -and $cacheOk)
}

function Restore-TunnelMtu {
    <#
        Puts the captured NlMtu back on the captured interface and re-reads it; falls
        back to a tunnel service restart (the .conf default) only if it still differs.
        $Original is a hashtable in-process or a PSCustomObject after a JSON round-trip.
    #>
    param($Original)

    $alias = [string]$Original.InterfaceAlias
    $want  = [int]$Original.NlMtu
    if ([string]::IsNullOrWhiteSpace($alias) -or $want -le 0) { return }

    $tunnel = Get-VpnActiveTunnelAdapter -Candidates @(Get-VpnCandidateAdapterObject)
    if ($tunnel -and $tunnel.Name -eq $alias) {
        Set-TunnelNlMtu -InterfaceAlias $alias -NlMtu $want
        Start-Sleep -Seconds 1
        if ((Get-TunnelNlMtu -InterfaceAlias $alias) -eq $want) { return }
    }

    Write-Host "           NlMtu on $alias did not return to $want directly; restarting the tunnel service"
    Restart-WireGuardTunnelAndWait
    $now = Get-TunnelNlMtu -InterfaceAlias $alias
    if ($now -ne $want) {
        throw "NlMtu on $alias is $now after a tunnel restart, expected $want"
    }
}

# -- Helpers: tunnel DNS --------------------------------------------------------------

function Get-TunnelDnsServer {
    # IPv4 DNS servers on the named interface, as the remediator reads them. Plain array.
    param([Parameter(Mandatory = $true)][string]$InterfaceAlias)
    $list = New-Object System.Collections.Generic.List[string]
    $dns = Get-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($dns) {
        foreach ($s in @($dns.ServerAddresses)) {
            if (-not [string]::IsNullOrWhiteSpace("$s")) { $list.Add([string]$s) }
        }
    }
    return $list.ToArray()
}

function Get-TunnelDnsCapture {
    $tunnel = Get-LabTunnelAdapter
    return @{ InterfaceAlias = [string]$tunnel.Name; ServerAddresses = @(Get-TunnelDnsServer -InterfaceAlias $tunnel.Name) }
}

function Test-TunnelDnsPlanted {
    # Verify for TunnelDnsMissing: no IPv4 server on the tunnel after a settle.
    Start-Sleep -Seconds 2
    $tunnel = Get-VpnActiveTunnelAdapter -Candidates @(Get-VpnCandidateAdapterObject)
    if (-not $tunnel) { Write-Host '           no active tunnel adapter to read DNS from'; return $false }
    $servers = @(Get-TunnelDnsServer -InterfaceAlias $tunnel.Name)
    Write-Host "           $($tunnel.Name) IPv4 DNS servers: [$($servers -join ', ')] (planted none)"
    return ($servers.Count -eq 0)
}

function Test-TunnelDnsReported {
    <#
        Validate for TunnelDnsMissing. The remediator can only flush and re-register; it
        must report the empty list as Failed with "Remediation ran", exit 0, write the
        cache, and leave the list empty -- a server appearing would mean it invented one.
    #>
    $tunnel = Get-VpnActiveTunnelAdapter -Candidates @(Get-VpnCandidateAdapterObject)
    if (-not $tunnel) { Write-Host '           no active tunnel adapter to read DNS from'; return $false }
    $servers = @(Get-TunnelDnsServer -InterfaceAlias $tunnel.Name)
    $stillEmpty = ($servers.Count -eq 0)
    if (-not $stillEmpty) { Write-Host "           tunnel now has IPv4 DNS [$($servers -join ', ')]; the script must not assign servers" }

    $lineOk  = Test-RemediatorOutputContains -Pattern '\[Failed \] Tunnel DNS: Active tunnel has no IPv4 DNS servers assigned\s+-> Remediation ran'
    $exitOk  = Test-RemediatorExitCode -Expected 0
    $cacheOk = Test-RemediationCacheReflectsRun
    return ($stillEmpty -and $lineOk -and $exitOk -and $cacheOk)
}

function Restore-TunnelDns {
    <#
        Writes the captured server list back and re-reads it; falls back to a tunnel
        service restart only if it still differs. A one-server list comes back from JSON
        as a bare string, hence the normalisation.
    #>
    param($Original)

    $alias = [string]$Original.InterfaceAlias
    if ([string]::IsNullOrWhiteSpace($alias)) { return }
    $want = @($Original.ServerAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | ForEach-Object { [string]$_ })

    $tunnel = Get-VpnActiveTunnelAdapter -Candidates @(Get-VpnCandidateAdapterObject)
    if ($tunnel -and $tunnel.Name -eq $alias) {
        if ($want.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $want -ErrorAction Stop
        } else {
            Set-DnsClientServerAddress -InterfaceAlias $alias -ResetServerAddresses -ErrorAction Stop
        }
        Start-Sleep -Seconds 1
        $now = @(Get-TunnelDnsServer -InterfaceAlias $alias)
        if (($now -join ',') -eq ($want -join ',')) { return }
    }

    Write-Host "           DNS on $alias did not return to [$($want -join ', ')] directly; restarting the tunnel service"
    Restart-WireGuardTunnelAndWait
    $now = @(Get-TunnelDnsServer -InterfaceAlias $alias)
    if (($now -join ',') -ne ($want -join ',')) {
        throw "DNS on $alias is [$($now -join ', ')] after a tunnel restart, expected [$($want -join ', ')]"
    }
}

# -- Helpers: VPN support service -----------------------------------------------------

function Get-SupportServiceState {
    <#
        Capture shape for VpnSupportServiceDisabled, read through Win32_Service exactly
        as the remediator does (StartMode Auto/Manual/Disabled, State). Running
        dependents are recorded because Stop-Service -Force takes them down too.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $cim) { throw "service $Name is not present on this host" }
    $svc = Get-Service -Name $Name -ErrorAction Stop
    $running = New-Object System.Collections.Generic.List[string]
    foreach ($d in @($svc.DependentServices)) {
        if ($d -and $d.Status -eq 'Running') { $running.Add($d.Name) }
    }
    return @{
        Name              = $Name
        StartMode         = [string]$cim.StartMode
        State             = [string]$cim.State
        RunningDependents = $running.ToArray()
    }
}

function Wait-ServiceState {
    # Polls Win32_Service.State. Host-stream diagnostics only; callers are [bool]-cast.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$State,
        [int]$TimeoutSec = 20
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
        if ($cim -and $cim.State -eq $State) { return $true }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    Write-Host "           $Name is '$(if ($cim) { $cim.State } else { 'absent' })' after ${TimeoutSec}s, wanted '$State'"
    return $false
}

function Test-SupportServicePlanted {
    # Verify for VpnSupportServiceDisabled: StartMode Disabled and the service stopped.
    $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$SupportServiceName'" -ErrorAction SilentlyContinue
    if (-not $cim) { Write-Host "           $SupportServiceName is not present"; return $false }
    $stopped = Wait-ServiceState -Name $SupportServiceName -State 'Stopped' -TimeoutSec 15
    Write-Host "           $SupportServiceName StartMode '$($cim.StartMode)', stopped: $stopped"
    return (($cim.StartMode -eq 'Disabled') -and $stopped)
}

function Test-SupportServiceRemediated {
    <#
        Validate for VpnSupportServiceDisabled. The script sets Disabled -> Manual and
        issues sc.exe start, which returns at START_PENDING, so Running is polled.
    #>
    $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$SupportServiceName'" -ErrorAction SilentlyContinue
    if (-not $cim) { Write-Host "           $SupportServiceName is not present"; return $false }
    $modeOk = ($cim.StartMode -ne 'Disabled')
    Write-Host "           $SupportServiceName StartMode '$($cim.StartMode)' (expected not Disabled)"
    $runOk = Wait-ServiceState -Name $SupportServiceName -State 'Running' -TimeoutSec 20

    $lineOk  = Test-RemediatorOutputContains -Pattern "\[Failed \] VPN Support Services: Service\(s\) not available: [^\r\n]*$SupportServiceName \(disabled\)[^\r\n]*-> Remediation ran"
    $exitOk  = Test-RemediatorExitCode -Expected 0
    $cacheOk = Test-RemediationCacheReflectsRun
    return ($modeOk -and $runOk -and $lineOk -and $exitOk -and $cacheOk)
}

function Restore-SupportServiceState {
    <#
        Captured start type first, then captured State, then any dependents that were
        running. $Original is a hashtable in-process or a PSCustomObject after a JSON
        round-trip; a single dependent comes back from JSON as a bare string.
    #>
    param($Original)

    $name = [string]$Original.Name
    if ([string]::IsNullOrWhiteSpace($name)) { return }

    $startType = switch ([string]$Original.StartMode) {
        'Auto'     { 'Automatic' }
        'Disabled' { 'Disabled' }
        default    { 'Manual' }
    }
    Set-Service -Name $name -StartupType $startType -ErrorAction Stop

    $svc = Get-Service -Name $name -ErrorAction Stop
    if ([string]$Original.State -eq 'Running') {
        if ($svc.Status -ne 'Running' -and $startType -ne 'Disabled') {
            Start-Service -Name $name -ErrorAction Stop
        }
        foreach ($dep in @($Original.RunningDependents | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })) {
            $d = Get-Service -Name ([string]$dep) -ErrorAction SilentlyContinue
            if ($d -and $d.Status -ne 'Running') { Start-Service -Name $d.Name -ErrorAction SilentlyContinue }
        }
    } else {
        if ($svc.Status -ne 'Stopped') {
            Stop-Service -Name $name -Force -ErrorAction Stop
        }
    }
}

# -- Helpers: the remediator's own cache and output ----------------------------------

function Get-RemediationCacheValue {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Test-Path -LiteralPath $RemediationRegPath)) { return $null }
    $item = Get-ItemProperty -LiteralPath $RemediationRegPath -Name $Name -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    return $item.$Name
}

function Get-RemediationCacheLastRun {
    $raw = Get-RemediationCacheValue -Name 'LastRun'
    if ([string]::IsNullOrWhiteSpace("$raw")) { return $null }
    try {
        return [datetime]::Parse("$raw", [System.Globalization.CultureInfo]::InvariantCulture,
                                 [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        return $null
    }
}

function Test-RemediationCacheRefreshed {
    <#
        The remediator stamps LastRun with Get-Date -Format 'o' at the end of every live
        run that got past the no-client guard. A LastRun older than this harness started
        (or no key at all) means this run did not write the cache.
    #>
    $stamp = Get-RemediationCacheLastRun
    if (-not $stamp) { return $false }
    # A stamp left by an earlier run can fall inside the -5 s tolerance when runs are
    # launched back to back (run 3bd4c0e35566: previous run's LastRun 19:55:32, this
    # harness started 19:55:37, reported "written by this run"). So the stamp must also
    # differ from the one captured just before the remediator was invoked.
    if ($null -ne $script:CacheLastRunBeforeRun -and $stamp -eq $script:CacheLastRunBeforeRun) { return $false }
    return ($stamp -ge $HarnessStartedAt.AddSeconds(-5))
}

function Test-RemediationCacheReflectsRun {
    <#
        Validate half shared by every break that reaches the engine: LastRun refreshed,
        RemediationErrors '0', RemediationsRun at least 1 and Failed at least 1 (the
        planted step is reported Failed even when its remediation ran). Host-stream
        diagnostics only.
    #>
    $refreshed = Test-RemediationCacheRefreshed
    if (-not $refreshed) { Write-Host "           $RemediationRegPath LastRun was not refreshed by this run" }

    $errText = "$(Get-RemediationCacheValue -Name 'RemediationErrors')"
    $runText = "$(Get-RemediationCacheValue -Name 'RemediationsRun')"
    $failText = "$(Get-RemediationCacheValue -Name 'Failed')"
    $runs = 0; $fails = 0
    $runOk  = [int]::TryParse($runText, [ref]$runs) -and ($runs -ge 1)
    $failOk = [int]::TryParse($failText, [ref]$fails) -and ($fails -ge 1)
    $errOk  = ($errText -eq '0')
    Write-Host "           cache: RemediationsRun '$runText', Failed '$failText', RemediationErrors '$errText'"
    return ($refreshed -and $runOk -and $failOk -and $errOk)
}

function Test-RemediatorOutputContains {
    # The remediator's own words, captured from the child process by the harness.
    param([Parameter(Mandatory = $true)][string]$Pattern)
    $output = if ($state.Remediation) { "$($state.Remediation.Output)" } else { '' }
    $hit = $output -match $Pattern
    if (-not $hit) { Write-Host "           remediator output did not match '$Pattern'" }
    return $hit
}

function Test-RemediatorOutputLacks {
    param([Parameter(Mandatory = $true)][string]$Pattern)
    $output = if ($state.Remediation) { "$($state.Remediation.Output)" } else { '' }
    $hit = $output -match $Pattern
    if ($hit) { Write-Host "           remediator output unexpectedly matched '$Pattern'" }
    return (-not $hit)
}

function Test-RemediatorExitCode {
    param([int]$Expected = 0)
    if (-not $state.Remediation) { Write-Host '           no remediation record'; return $false }
    $rc = [int]$state.Remediation.ExitCode
    if ($rc -ne $Expected) { Write-Host "           remediator exit code $rc (expected $Expected)" }
    return ($rc -eq $Expected)
}

# -- Break definitions ---------------------------------------------------------
# Capture runs before any mutation; Restore consumes what it returned.
# Verify proves the break landed. Validate decides whether the remediator did its job.
$BreakCatalog = @(

    @{
        Name            = 'TunnelMtuTooHigh'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                # Step 3 branch: "Tunnel MTU is 1500, no allowance for encapsulation
                # overhead". Wintun's link MTU is far above 1500, so the IPv4 NlMtu takes
                # the Ethernet default without complaint.
                Name  = 'SetMtuToEthernetDefault'
                Apply = {
                    $tunnel = Get-LabTunnelAdapter
                    Set-TunnelNlMtu -InterfaceAlias $tunnel.Name -NlMtu $PlantedMtuHigh
                }
            }
        )
        Capture  = { Get-TunnelMtuCapture }
        Verify   = { Test-TunnelMtuPlanted -Expected $PlantedMtuHigh }
        Validate = { Test-TunnelMtuRemediated -DetectionPattern "Tunnel MTU is $PlantedMtuHigh, no allowance for encapsulation overhead" }
        Restore  = {
            param($Original)
            Restore-TunnelMtu -Original $Original
        }
    },

    @{
        Name            = 'TunnelMtuTooLow'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                # Step 3 branch: "Tunnel MTU is 1200, below the 1280 minimum". IPv4
                # accepts any NlMtu down to 576, so 1200 lands.
                Name  = 'SetMtuBelowFloor'
                Apply = {
                    $tunnel = Get-LabTunnelAdapter
                    Set-TunnelNlMtu -InterfaceAlias $tunnel.Name -NlMtu $PlantedMtuLow
                }
            }
        )
        Capture  = { Get-TunnelMtuCapture }
        Verify   = { Test-TunnelMtuPlanted -Expected $PlantedMtuLow }
        Validate = { Test-TunnelMtuRemediated -DetectionPattern "Tunnel MTU is $PlantedMtuLow, below the $MtuFloor minimum" }
        Restore  = {
            param($Original)
            Restore-TunnelMtu -Original $Original
        }
    },

    @{
        Name            = 'TunnelDnsMissing'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                # Step 4 branch: "Active tunnel has no IPv4 DNS servers assigned". The
                # resolution only flushes and re-registers, so the list stays empty and
                # the step is reported, not fixed.
                Name  = 'ResetTunnelDnsServers'
                Apply = {
                    $tunnel = Get-LabTunnelAdapter
                    Set-DnsClientServerAddress -InterfaceAlias $tunnel.Name -ResetServerAddresses -ErrorAction Stop
                }
            }
        )
        Capture  = { Get-TunnelDnsCapture }
        Verify   = { Test-TunnelDnsPlanted }
        Validate = { Test-TunnelDnsReported }
        Restore  = {
            param($Original)
            Restore-TunnelDns -Original $Original
        }
    },

    @{
        Name            = 'VpnSupportServiceDisabled'
        ExpectedOutcome = 'ExpectFixed'
        RequiresReboot  = $false
        Methods         = @(
            @{
                # Step 2 branch: "Service(s) not available: RasMan (disabled)". Stop first
                # so the SCM accepts the Disabled start type cleanly; -Force takes the
                # dependents (RemoteAccess) down too, which Capture recorded.
                Name  = 'DisableAndStopRasMan'
                Apply = {
                    $svc = Get-Service -Name $SupportServiceName -ErrorAction Stop
                    if ($svc.Status -ne 'Stopped') { Stop-Service -Name $SupportServiceName -Force -ErrorAction Stop }
                    Set-Service -Name $SupportServiceName -StartupType Disabled -ErrorAction Stop
                }
            }
        )
        Capture  = { Get-SupportServiceState -Name $SupportServiceName }
        Verify   = { Test-SupportServicePlanted }
        Validate = { Test-SupportServiceRemediated }
        Restore  = {
            param($Original)
            Restore-SupportServiceState -Original $Original
        }
    },

    @{
        Name            = 'NoVpnClientReported'
        ExpectedOutcome = 'ExpectReportedOnly'
        RequiresReboot  = $false
        Methods         = @(
            @{
                # Guard branch: "No VPN client present on this device. Nothing to
                # process." Stopping the WireGuard tunnel service removes its Wintun
                # adapter; on a host with no tunnel service there is nothing to stop and
                # the host is already a no-client host.
                Name  = 'StopTunnelService'
                Apply = {
                    Stop-WireGuardTunnel
                }
            }
        )
        Capture  = { @{ Tunnels = @(Get-WireGuardTunnelState) } }
        Verify   = {
            # Wait for the adapter to go away (Wintun removal lags the service stop by a
            # few seconds).
            Wait-VpnCandidateState -ExpectedCount 0 -TimeoutSec 30
        }
        Validate = {
            $lineOk  = Test-RemediatorOutputContains -Pattern 'No VPN client present on this device\. Nothing to process\.'
            $noSteps = Test-RemediatorOutputLacks -Pattern '\[(Passed |Failed |Warning)\] '
            $exitOk  = Test-RemediatorExitCode -Expected 0
            # The guard exits before the cache block: a refreshed LastRun would mean the
            # engine ran against a device the script should have called client-free.
            $cacheUntouched = -not (Test-RemediationCacheRefreshed)
            if (-not $cacheUntouched) { Write-Host "           $RemediationRegPath was written by this run; the guard should have exited first" }
            $lineOk -and $noSteps -and $exitOk -and $cacheUntouched
        }
        Restore  = {
            param($Original)
            Restore-WireGuardTunnelState -Tunnels $Original.Tunnels
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

Write-DexBanner -Title "Invoke-AutoRemediateGenericVPN_BreakTest" -Detail "Environment: $Environment"

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
            @($BreakCatalog | Where-Object { $BreakName -contains $_.Name })
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

        # NoVpnClientReported removes the tunnel adapter that every other break needs, so
        # it never shares a run: kept alone when the seeded shuffle drew it first, dropped
        # otherwise, so both outcomes get coverage across seeds. Force it with -BreakName.
        $solo = 'NoVpnClientReported'
        if ($selected.Count -gt 1 -and @($selected | Where-Object { $_.Name -eq $solo }).Count -gt 0) {
            if ($selected[0].Name -eq $solo) {
                $selected = @($selected[0])
                Write-DexStep -Status 'Info' -Name 'Selection' -Message "'$solo' runs alone; other breaks dropped"
            } else {
                $selected = @($selected | Where-Object { $_.Name -ne $solo })
                Write-DexStep -Status 'Info' -Name 'Selection' -Message "'$solo' cannot share a run; dropped"
            }
        }

        # The two MTU breaks write the same value and the second would undo the first's
        # Verify. Keep whichever was drawn first.
        $mtuBreaks = @('TunnelMtuTooHigh', 'TunnelMtuTooLow')
        if (@($selected | Where-Object { $mtuBreaks -contains $_.Name }).Count -gt 1) {
            $keep     = @($selected | Where-Object { $mtuBreaks -contains $_.Name })[0].Name
            $selected = @($selected | Where-Object { ($mtuBreaks -notcontains $_.Name) -or ($_.Name -eq $keep) })
            Write-DexStep -Status 'Info' -Name 'Selection' -Message "MTU breaks are mutually exclusive; kept '$keep'"
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
                Write-DexStep -Status 'Failed' -Name "Verify $($b.Name)" -Message 'break did not land; remediation would be a false green'
            }
        }

        if (-not $allVerified) {
            $state.Phase   = 'BreakFailed'
            $state.Overall = 'BreakFailed'
            Save-DexTestState -State $state
            throw 'One or more breaks could not be verified; refusing to run the remediator.'
        }

        $state.Phase = 'BreakVerified'
        Save-DexTestState -State $state
    }

    # -- Phase: remediate ------------------------------------------------------
    if ($state.Phase -eq 'BreakVerified') {

        if (-not $RemediationTest) {
            $state.Overall = 'BreakOnly'
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message 'skipped (-RemediationTest not supplied)'
        } else {
            Write-DexStep -Status 'Info' -Name 'Remediation' -Message "invoking $([System.IO.Path]::GetFileName($RemediationScript))"

            # Snapshot the cache stamp so Test-RemediationCacheRefreshed can tell this
            # run's write from one left by a run launched seconds earlier.
            $script:CacheLastRunBeforeRun = Get-RemediationCacheLastRun

            # The remediator bridges $env:WhatIf into $WhatIfPreference; a true value
            # makes it a dry run that fixes nothing and caches nothing. The child inherits
            # this process's environment, so the variable is removed for the launch and
            # put back afterwards.
            $prevWhatIf = $env:WhatIf
            if ($null -ne $prevWhatIf) {
                Remove-Item -LiteralPath 'Env:\WhatIf' -ErrorAction SilentlyContinue
                Write-DexStep -Status 'Info' -Name 'Remediation' -Message "cleared env:WhatIf='$prevWhatIf' for the live run"
            }

            # The remediator uses Write-Error on its failure path. Under the harness's
            # $ErrorActionPreference = 'Stop' the first stderr line of a native command
            # redirected with 2>&1 becomes a terminating NativeCommandError, which would
            # turn every failing run into HarnessError with no detail. Capture stderr as
            # text so a failing remediator is a Validate failure with its full output in
            # the JSON.
            $sw      = [System.Diagnostics.Stopwatch]::StartNew()
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemediationScript 2>&1 |
                          ForEach-Object { "$_" }
                $rc = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prevEap
                if ($null -ne $prevWhatIf) { $env:WhatIf = $prevWhatIf }
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
                'planted fault corrected by the remediator'
            } else {
                'condition detected and reported by the remediator'
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
            # The remediator exited 0 while the machine is still wrong.
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
