<#
.SYNOPSIS
    Vendor-agnostic VPN remediation -- fixes what Windows owns, reports the rest.

.DESCRIPTION
    Runs an ordered sequence of VPN health checks and remediates the ones that can
    be fixed without a vendor client. Pairs with Invoke-VpnStateCollection.ps1: that
    script measures and scores, this one corrects.

    SCOPE -- READ THIS BEFORE DEPLOYING

    A VPN tunnel is two things at once: a Windows network interface, and a session
    owned by a vendor client. Windows owns the interface, so MTU, DNS registration,
    routing, and the supporting services are all fixable generically. Windows does
    not own the session. There is no OS-level "reconnect the VPN" -- initiating a
    connection is a vendor CLI call, every vendor spells it differently, and no
    amount of generic code changes that.

    So this script deliberately does NOT attempt to fix TunnelDown,
    RepeatedConnectFailures, or FrequentReconnects. Those belong to a vendor layer.
    A generic script that pretended to fix them would report success while the user
    stayed disconnected, which is worse than reporting nothing.

    +------+--------------------------+---------------------------------------------+
    | Step | Name                     | Remediation                                 |
    +------+--------------------------+---------------------------------------------+
    |  1   | Multiple VPN Clients     | None -- report only (see note below)        |
    |  2   | VPN Support Services     | Start stopped, un-disable disabled          |
    |  3   | Tunnel MTU               | Set tunnel interface MTU to 1400            |
    |  4   | Tunnel DNS               | Flush resolver cache, re-register           |
    |  5   | Orphaned Tunnel Routes   | Remove active-store routes on dead tunnels  |
    |  6   | Tunnel Adapter Bounce    | DISABLED BY DEFAULT -- see note below       |
    +------+--------------------------+---------------------------------------------+

    Step 1 is report-only by design. Uninstalling a VPN client from a remote device
    is how you strand a user off-network with no way back in. Stacked clients are
    worth knowing about and worth a human decision.

    Step 6 is Enabled = $false by design. Bouncing a tunnel adapter drops the
    session, and this script cannot reconnect it -- see SCOPE above. Enable it only
    for a fleet whose client reconnects reliably on its own.

    Tunnel detection is structural, not name-based: a non-hardware adapter that is
    not known virtual infrastructure. Same logic as Invoke-VpnStateCollection.ps1,
    so both scripts agree on what a tunnel is, including for clients neither has
    heard of.

    Results are written to HKLM:\Software\AirWatch\Extensions\VPN\Remediation.
    The collector's own values under ...\VPN are left untouched.

.NOTES
    Script Name  : Invoke-AutoRemediateGenericVPN.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-04
    Timeout      : 30 seconds (60 if step 6 is enabled)

    Environment variables:
      WhatIf = true    Dry run. Absent/unparseable => live run.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param()

$SCRIPT_VERSION = "1.0.0"
$RegPath        = "HKLM:\Software\AirWatch\Extensions\VPN\Remediation"
$LogPath        = "$env:SystemRoot\Temp\UEM_AutoRemediateGenericVPN.log"

# -- Tunables ------------------------------------------------------------------
# Hard-coded deliberately: UEM variables are per-script-object, not per-assignment,
# so exposing these would give no real deployment flexibility. Fork the script
# object if a ring needs different values.
$TargetTunnelMtu = 1400   # Safe for IPsec, WireGuard, and most SSL VPNs
$MtuCeiling      = 1500   # At or above this, encapsulation overhead is unaccounted for
$MtuFloor        = 1280   # IPv6 minimum; below this is pathological

# Windows services the built-in VPN stack depends on. Third-party clients vary in
# which they use, but none are harmed by these running.
#   RasMan  - Remote Access Connection Manager, required by the in-box VPN stack
#   IKEEXT  - IKE / AuthIP keying, required for IKEv2
#   BFE     - Base Filtering Engine, required for any IPsec policy
$RequiredServices = @(
    @{ Name = 'RasMan'; FixStartType = $true  },
    @{ Name = 'IKEEXT'; FixStartType = $true  },
    @{ Name = 'BFE';    FixStartType = $false }   # Never touch BFE start type
)

# -- WhatIf bridge -------------------------------------------------------------
# UEM cannot set $WhatIfPreference directly. Bridge it from an environment
# variable. Absent, empty, or unparseable => $false (live run).
$WhatIfPreference = $false
if ($env:WhatIf) {
    try   { $WhatIfPreference = [System.Convert]::ToBoolean($env:WhatIf) }
    catch { $WhatIfPreference = $false }
}

# -- Run header ----------------------------------------------------------------
$RunEventId = ([Random]::new()).Next(1000, 9999)
Write-Host "[$RunEventId] Executing Invoke-AutoRemediateGenericVPN, $SCRIPT_VERSION. Started @ '$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'  WhatIf=$WhatIfPreference"
$HEAD = "`r`n[$RunEventId]"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    # -WhatIf:$false so a dry run is still recorded; the log is evidence, not state.
    "[$timestamp] [$RunEventId] [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding UTF8 -WhatIf:$false -ErrorAction SilentlyContinue
}

# -- Tunnel identification -----------------------------------------------------
# Kept identical to Invoke-VpnStateCollection.ps1 so both scripts agree on what
# counts as a tunnel.
$ExcludedAdapterPattern = '(?i)(vEthernet|Hyper-V|WSL|Docker|VMware|VirtualBox|Bluetooth|Loopback|Npcap|Wi-Fi Direct|Kernel Debug|Teredo|ISATAP|6to4|VirtualPCNet|TeamViewer|Parsec)'

function Get-CandidateTunnelAdapter {
    $all = Get-NetAdapter -ErrorAction SilentlyContinue
    if (-not $all) { return @() }

    $candidates = foreach ($a in $all) {
        # Older builds may not expose HardwareInterface; ConnectorPresent is the fallback.
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
        $a
    }

    return @($candidates)
}

function Get-ActiveTunnelAdapter {
    param($Candidates)
    foreach ($a in $Candidates) {
        if ($a.Status -ne 'Up') { continue }
        $ip = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' }
        if ($ip) { return $a }
    }
    return $null
}

# -- Guard clause --------------------------------------------------------------
# Nothing here is meaningful on a device with no VPN client. Exit before the
# engine rather than reporting six inapplicable steps.
$candidates = Get-CandidateTunnelAdapter
if ($candidates.Count -eq 0) {
    Write-Output "$HEAD No VPN client present on this device. Nothing to process."
    Write-Log "No VPN client present. Exiting."
    exit 0
}

$activeTunnel = Get-ActiveTunnelAdapter -Candidates $candidates
Write-Log "Candidates: $($candidates.Count) | Active tunnel: $(if ($activeTunnel) { $activeTunnel.InterfaceDescription } else { 'none' })"

# -- Step Definitions ----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'Multiple VPN Clients'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if ($candidates.Count -le 1) {
                return @{ Status = 'Passed'; Message = "Single VPN client: $($candidates[0].InterfaceDescription)" }
            }
            $names = ($candidates | ForEach-Object { $_.InterfaceDescription }) -join '; '
            # Warning, not Failed: stacked clients are a real problem but not one
            # this script is willing to solve unattended.
            return @{ Status = 'Warning'; Message = "$($candidates.Count) VPN clients installed, they will contend for routes and DNS: $names" }
        }
        # Report only. Removing a VPN client remotely can strand the device.
        ResolutionScript = $null
    },

    @{
        Name             = 'VPN Support Services'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $broken = @()
            foreach ($svc in $RequiredServices) {
                $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue
                if (-not $cim) { continue }   # Not present on this SKU; not a fault
                if ($cim.StartMode -eq 'Disabled') { $broken += "$($svc.Name) (disabled)" }
                elseif ($cim.State -ne 'Running') { $broken += "$($svc.Name) ($($cim.State))" }
            }
            if ($broken.Count -eq 0) {
                return @{ Status = 'Passed'; Message = 'All VPN support services running' }
            }
            return @{ Status = 'Failed'; Message = "Service(s) not available: $($broken -join ', ')" }
        }
        ResolutionScript = {
            foreach ($svc in $RequiredServices) {
                $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue
                if (-not $cim) { continue }

                if ($cim.StartMode -eq 'Disabled') {
                    if (-not $svc.FixStartType) {
                        # BFE start type is left alone deliberately; a disabled BFE
                        # is a security-baseline decision, not a VPN fault to fix.
                        Write-Log "$($svc.Name) is disabled; start type not modified by policy." -Level "WARN"
                        continue
                    }
                    # Manual is the Windows default for these; do not force Automatic.
                    Set-Service -Name $svc.Name -StartupType Manual -ErrorAction SilentlyContinue
                    Write-Log "Set $($svc.Name) start type to Manual."
                }

                $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue
                if ($cim -and $cim.State -ne 'Running') {
                    # sc.exe returns at START_PENDING; Start-Service would block up
                    # to the ~30s SCM timeout and eat the whole script budget.
                    if ($PSCmdlet.ShouldProcess($svc.Name, "Start service")) {
                        & sc.exe start $svc.Name | Out-Null
                        Write-Log "Issued start for $($svc.Name)."
                    }
                }
            }
        }
    },

    @{
        Name             = 'Tunnel MTU'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $activeTunnel) {
                return @{ Status = 'Passed'; Message = 'No active tunnel; MTU not applicable' }
            }
            $ipIf = Get-NetIPInterface -InterfaceIndex $activeTunnel.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            if (-not $ipIf -or -not $ipIf.NlMtu) {
                return @{ Status = 'Warning'; Message = 'Tunnel MTU could not be read' }
            }

            $mtu = [int]$ipIf.NlMtu
            if ($mtu -ge $MtuCeiling) {
                # A tunnel still at the Ethernet default has not accounted for
                # encapsulation overhead. Oversized packets are dropped in transit,
                # and where ICMP "Fragmentation Needed" is filtered the sender is
                # never told -- pings succeed while large transfers stall.
                return @{ Status = 'Failed'; Message = "Tunnel MTU is $mtu, no allowance for encapsulation overhead" }
            }
            if ($mtu -lt $MtuFloor) {
                return @{ Status = 'Failed'; Message = "Tunnel MTU is $mtu, below the $MtuFloor minimum" }
            }
            return @{ Status = 'Passed'; Message = "Tunnel MTU is $mtu" }
        }
        ResolutionScript = {
            if (-not $activeTunnel) { return }
            if ($PSCmdlet.ShouldProcess($activeTunnel.InterfaceDescription, "Set IPv4 MTU to $TargetTunnelMtu")) {
                Set-NetIPInterface -InterfaceIndex $activeTunnel.ifIndex -AddressFamily IPv4 `
                    -NlMtuBytes $TargetTunnelMtu -ErrorAction Stop
                Write-Log "Set MTU $TargetTunnelMtu on ifIndex $($activeTunnel.ifIndex)."
            }
            # Session-scoped: most clients reassert their own MTU on reconnect.
            # A permanent fix belongs in the vendor's connection profile.
        }
    },

    @{
        Name             = 'Tunnel DNS'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            if (-not $activeTunnel) {
                return @{ Status = 'Passed'; Message = 'No active tunnel; DNS not applicable' }
            }
            $dns = Get-DnsClientServerAddress -InterfaceIndex $activeTunnel.ifIndex `
                       -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $servers = @()
            if ($dns) { $servers = @($dns.ServerAddresses) }

            if ($servers.Count -eq 0) {
                # The classic "VPN connected but nothing internal resolves" failure.
                # Resolution falls back to the physical adapter's public resolvers,
                # so internal names fail while the tunnel looks perfectly healthy.
                return @{ Status = 'Failed'; Message = 'Active tunnel has no IPv4 DNS servers assigned' }
            }
            return @{ Status = 'Passed'; Message = "Tunnel DNS: $($servers -join ', ')" }
        }
        ResolutionScript = {
            # This can only nudge resolution back into a working state. The servers
            # themselves come from the vendor's connection profile and cannot be
            # set generically -- guessing them would be worse than leaving them unset.
            if ($PSCmdlet.ShouldProcess("DNS client", "Flush cache and re-register")) {
                & ipconfig /flushdns    | Out-Null
                & ipconfig /registerdns | Out-Null
                Write-Log "Flushed resolver cache and re-registered DNS."
            }
        }
    },

    @{
        Name             = 'Orphaned Tunnel Routes'
        Order            = 5
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            $script:OrphanedRoutes = @()

            # Multicast, broadcast, and loopback routes persist harmlessly on any
            # interface. Only routes that would carry real traffic matter here.
            $ignorePrefixes = @('224.0.0.0/4', '255.255.255.255/32', '127.0.0.0/8', '::1/128', 'ff00::/8')

            foreach ($a in ($candidates | Where-Object { $_.Status -ne 'Up' })) {
                $routes = Get-NetRoute -InterfaceIndex $a.ifIndex -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
                          Where-Object { $ignorePrefixes -notcontains $_.DestinationPrefix -and
                                         $_.DestinationPrefix -notlike 'fe80::*' }
                foreach ($r in $routes) {
                    $script:OrphanedRoutes += [PSCustomObject]@{
                        IfIndex = $a.ifIndex
                        Prefix  = $r.DestinationPrefix
                        Adapter = $a.InterfaceDescription
                    }
                }
            }

            if ($script:OrphanedRoutes.Count -eq 0) {
                return @{ Status = 'Passed'; Message = 'No routes left behind on inactive tunnel adapters' }
            }
            # A client that crashed rather than disconnecting cleanly leaves routes
            # pointed at an interface that is no longer up. Traffic matching them
            # is blackholed with no error surfaced to the user.
            $summary = ($script:OrphanedRoutes | ForEach-Object { $_.Prefix }) -join ', '
            return @{ Status = 'Failed'; Message = "$($script:OrphanedRoutes.Count) route(s) stranded on inactive tunnel(s): $summary" }
        }
        ResolutionScript = {
            foreach ($r in $script:OrphanedRoutes) {
                if ($PSCmdlet.ShouldProcess("$($r.Prefix) on $($r.Adapter)", "Remove stranded route")) {
                    # ActiveStore only: a route in the PersistentStore is admin
                    # configuration and is not this script's to remove.
                    Remove-NetRoute -InterfaceIndex $r.IfIndex -DestinationPrefix $r.Prefix `
                        -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue
                    Write-Log "Removed stranded route $($r.Prefix) on ifIndex $($r.IfIndex)."
                }
            }
        }
    },

    @{
        Name             = 'Tunnel Adapter Bounce'
        Order            = 6
        # DISABLED BY DEFAULT AND THAT IS DELIBERATE.
        # Bouncing the adapter drops the tunnel, and nothing in this script can
        # bring it back -- reconnecting is a vendor operation. On a fleet whose
        # client does not auto-reconnect, enabling this disconnects users to fix a
        # problem they may not have had. Enable only with that understood.
        Enabled          = $false
        ResolveOnWarning = $true
        DetectionScript  = {
            $wedged = @($candidates | Where-Object { $_.Status -eq 'Disabled' })
            if ($wedged.Count -gt 0) {
                return @{ Status = 'Failed'; Message = "Tunnel adapter(s) administratively disabled: $(($wedged | ForEach-Object { $_.Name }) -join ', ')" }
            }
            if (-not $activeTunnel) {
                return @{ Status = 'Warning'; Message = 'VPN client present but no active tunnel; bounce queued' }
            }
            return @{ Status = 'Passed'; Message = 'Tunnel adapter is up and carrying traffic' }
        }
        ResolutionScript = {
            foreach ($a in $candidates) {
                if ($PSCmdlet.ShouldProcess($a.Name, "Bounce tunnel adapter")) {
                    Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 3
                    Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
                    Write-Log "Bounced adapter $($a.Name)."
                }
            }
            Start-Sleep -Seconds 5   # Allow the client to notice and re-establish
        }
    }
)

# -- Execution Engine ----------------------------------------------------------
$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($step in $activeSteps) {

    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''

    # -- Detection ------------------------------------------------------------
    # A thrown detection is a step failure, not a script failure.
    try {
        $result  = & $step.DetectionScript
        $status  = $result.Status
        $message = $result.Message
    }
    catch {
        $status  = 'Failed'
        $message = "Detection exception: $($_.Exception.Message)"
    }

    # -- Remediation ----------------------------------------------------------
    $shouldRemediate = ($status -eq 'Failed') -or
                       ($status -eq 'Warning' -and $step.ResolveOnWarning)

    if ($shouldRemediate -and $step.ResolutionScript) {
        try {
            & $step.ResolutionScript | Out-Null
            $remediated = $true
        }
        catch {
            $remError = $_.Exception.Message
        }
    }

    $remNote = if ($remError)          { "  -> Remediation ERROR: $remError" }
               elseif ($remediated)    { '  -> Remediation ran' }
               elseif ($shouldRemediate) { '  -> No resolution defined (report only)' }
               else                    { '' }

    Write-Output "$HEAD [$($status.PadRight(7))] $($step.Name): $message$remNote"
    Write-Log "[$status] $($step.Name): $message$remNote"

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary -------------------------------------------------------------------
$passed   = @($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = @($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = @($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = @($results | Where-Object { $_.Remediated }).Count
$remErrs  = @($results | Where-Object { $_.RemError }).Count

Write-Output "$HEAD Passed: $passed | Warnings: $warnings | Failed: $failed | Remediations run: $remCount | Remediation errors: $remErrs"
Write-Log "Summary -- Passed: $passed, Warnings: $warnings, Failed: $failed, Remediated: $remCount, Errors: $remErrs"

# -- Cache results -------------------------------------------------------------
# Skipped on a dry run: a WhatIf pass must touch nothing. Set-ItemProperty also
# resolves its path before it evaluates ShouldProcess, so attempting this against
# a key New-Item was not allowed to create emits a wall of path-not-found errors.
# The log file records the dry run instead.
if ($WhatIfPreference) {
    Write-Output "$HEAD Dry run: results not cached to the registry."
}
else {
    try {
        if (-not (Test-Path $RegPath)) {
            New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null
        }

        $cache = [ordered]@{
            LastRun           = (Get-Date -Format "o")
            ScriptVersion     = $SCRIPT_VERSION
            Passed            = [string]$passed
            Warnings          = [string]$warnings
            Failed            = [string]$failed
            RemediationsRun   = [string]$remCount
            RemediationErrors = [string]$remErrs
        }

        foreach ($name in $cache.Keys) {
            Set-ItemProperty -Path $RegPath -Name $name -Value $cache[$name] -Type String -ErrorAction Stop
        }
    }
    catch {
        Write-Warning "$HEAD Could not cache results: $($_.Exception.Message)"
        Write-Log "Could not cache results: $($_.Exception.Message)" -Level "WARN"
    }
}

# A detected-and-remediated issue is the script working, not failing. Only a
# remediation that errored is a genuine failure.
if ($remErrs -gt 0) {
    Write-Error "$HEAD One or more remediations failed."
    exit 1
}
exit 0
